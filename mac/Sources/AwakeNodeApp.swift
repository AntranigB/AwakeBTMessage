import SwiftUI
import CoreBluetooth
import AppKit
import AwakeCore

@main
struct AwakeNodeApp: App {
    @StateObject private var anchor = Anchor()
    var body: some Scene {
        WindowGroup {
            AnchorView().environmentObject(anchor)
        }
        .defaultSize(width: 520, height: 640)
    }
}

// MARK: - Anchor

final class Anchor: NSObject, ObservableObject, CBPeripheralManagerDelegate {

    @Published var lines: [String] = []
    @Published var subscribers = 0
    @Published var advertising = false
    @Published var powered = false
    @Published var lastSendAt: [String: Double] = [:]
    @Published var lastLatency: Double?
    @Published var queued = 0
    @Published var linkLive = false
    @Published var phoneBattery: Int?
    @Published var phoneRSSI: Int?

    let nodeId = "ANCH"
    private var knownNode: String? = UserDefaults.standard.string(forKey: "knownNode") {
        didSet { UserDefaults.standard.set(knownNode, forKey: "knownNode") }
    }
    private let store = MessageStore()
    private var watchdog = LinkWatchdog(staleAfter: 90)
    private let key = Envelope.key(from: kDemoPSK)

    private var pm: CBPeripheralManager!
    private var rx: CBMutableCharacteristic!
    private var tx: CBMutableCharacteristic!
    private var rxBuf: [UInt8] = []
    private var pending: [Data] = []
    private var seen = Set<String>()
    private var probeTimer: Timer?
    private var probeCount = 0
    private var sentBytes: [String: Int] = [:]
    private var heartbeats = 0
    private var radioRetries = 0
    private var pingTrigger: Timer?

    override init() {
        super.init()
        pm = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "com.awake.anchor"])

        // Refresh the on-screen link state so a stale subscriber cannot make
        // the window claim a phone is present when it has gone quiet.
        let ui = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let live = self.watchdog.isLive(now: Date().timeIntervalSince1970,
                                            subscribers: self.subscribers)
            if self.linkLive != live { self.linkLive = live }
        }
        RunLoop.main.add(ui, forMode: .common)

        logLocal("launch pid \(ProcessInfo.processInfo.processIdentifier) · waiting for radio")
        startRadioWatchdog()
        startPingTrigger()
    }

    /// Sometimes the Bluetooth stack never calls back at launch — the app sits
    /// at "waiting for radio" forever and nothing advertises. Recreating the
    /// manager kicks the XPC connection. Observed repeatedly after a quick
    /// kill/relaunch, which is exactly what a demo restart looks like.
    private func startRadioWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.checkRadio()
        }
    }

    private func checkRadio() {
        guard pm.state == .unknown, radioRetries < 3 else { return }
        radioRetries += 1
        logLocal("radio silent after 6s — recreating manager (try \(radioRetries))")
        pm = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: "com.awake.anchor"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.checkRadio()
        }
    }

    /// Persisted, so a silent failure is diagnosable without a window:
    /// ~/Library/Application Support/AwakeAnchor/anchor.log
    private let logURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AwakeAnchor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("anchor.log")
    }()

    private func appendFile(_ s: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(s)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Anchor window only — no dashboard row. Used for chatty telemetry like
    /// GPS, which would otherwise bury real messages in the event feed.
    private func logLocal(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        lines.append("\(f.string(from: Date()))  \(s)")
        if lines.count > 600 { lines.removeFirst(lines.count - 600) }
        appendFile(s)
    }

    func log(_ s: String) {
        logLocal(s)
        postEvent(["kind": "log", "detail": s, "node": nodeId])
    }

    // MARK: Peripheral lifecycle

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        powered = peripheral.state == .poweredOn
        guard powered else {
            // 0 unknown · 1 resetting · 2 unsupported · 3 unauthorized · 4 off
            log("RADIO NOT READY · state \(peripheral.state.rawValue)")
            return
        }
        let svc = CBMutableService(type: kServiceUUID, primary: true)
        rx = CBMutableCharacteristic(type: kRXUUID,
                                     properties: [.write, .writeWithoutResponse],
                                     value: nil,
                                     permissions: [.writeable])
        tx = CBMutableCharacteristic(type: kTXUUID,
                                     properties: [.notify],
                                     value: nil,
                                     permissions: [.readable])
        svc.characteristics = [rx, tx]
        pm.add(svc)
        startAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           willRestoreState dict: [String: Any]) {
        log("restored by macOS")
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            for s in services where s.uuid == kServiceUUID {
                for c in s.characteristics ?? [] {
                    if c.uuid == kRXUUID { rx = c as? CBMutableCharacteristic }
                    if c.uuid == kTXUUID { tx = c as? CBMutableCharacteristic }
                }
            }
        }
        startAdvertising()
    }

    func startAdvertising() {
        guard powered else { return }
        pm.startAdvertising([
            CBAdvertisementDataLocalNameKey: "AWAKE-ANCHOR",
            CBAdvertisementDataServiceUUIDsKey: [kServiceUUID]
        ])
        advertising = true
        log("advertising as AWAKE-ANCHOR")
        startProbeIfRequested()
    }

    /// `--probe` sends one message every five minutes, so an unattended
    /// overnight run produces a delivery-vs-time curve instead of anecdotes.
    private func startProbeIfRequested() {
        guard CommandLine.arguments.contains("--probe"), probeTimer == nil else { return }

        var interval: TimeInterval = 300
        if let i = CommandLine.arguments.firstIndex(of: "--probe-interval"),
           i + 1 < CommandLine.arguments.count,
           let v = Double(CommandLine.arguments[i + 1]) {
            interval = max(5, v)
        }

        log(String(format: "PROBE MODE: one message every %.0fs", interval))
        postEvent(["kind": "log",
                   "detail": String(format: "probe every %.0fs", interval),
                   "node": nodeId])

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.fireProbe()
        }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.fireProbe()
        }
        RunLoop.main.add(t, forMode: .common)
        probeTimer = t
    }

    /// Every third probe is ~400 bytes so the multi-chunk path is exercised on
    /// real hardware, not just in the unit tests.
    /// A local trigger so `dryrun.sh` can ask for a round trip **without
    /// restarting anything**. Restarting the anchor drops the link, and a
    /// suspended phone cannot rescan — so the check would disturb the very
    /// thing it measures.
    private func startPingTrigger() {
        let path = "/tmp/awake-ping-request"
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard FileManager.default.fileExists(atPath: path) else { return }
            try? FileManager.default.removeItem(atPath: path)
            self.fireProbe()
        }
        RunLoop.main.add(t, forMode: .common)
        pingTrigger = t
    }

    private func fireProbe() {
        probeCount += 1
        if probeCount % 3 == 0 {
            let filler = String(repeating: "abcdefghij", count: 40)
            ping("probe \(probeCount) long \(filler)")
        } else {
            ping("probe \(probeCount)")
        }
    }

    /// A round-trip probe that the phone acks **without showing it in the
    /// chat**, so a dry run leaves the demo transcript clean.
    private func ping(_ body: String) {
        let m = MeshMessage(from: nodeId, to: knownNode ?? "*", type: "ping", body: body)
        lastSendAt[m.mid] = Date().timeIntervalSince1970
        if let dest = knownNode {
            store.enqueue(m)
            refreshQueued()
        }
        transmit(m)
        logLocal("ping \(body)")
        postEvent(["kind": "send", "detail": body, "node": nodeId])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didAdd service: CBService, error: Error?) {
        if let e = error { log("add service error: \(e.localizedDescription)") }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        subscribers += 1
        logLocal("phone subscribed (\(subscribers))")
        postEvent(["kind": "sub", "detail": "phone subscribed", "node": nodeId])
        // The phone sends `hello` immediately after subscribing, and that
        // handler flushes. Flushing here too replayed the queue twice.
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers = max(0, subscribers - 1)
        log("phone unsubscribed (\(subscribers))")
    }

    // MARK: Receive

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            if let d = r.value { rxBuf.append(contentsOf: d) }
            peripheral.respond(to: r, withResult: .success)
        }
        drain()
    }

    private func drain() {
        while rxBuf.count >= 2 {
            let len = Int(rxBuf[0]) << 8 | Int(rxBuf[1])
            guard len > 0, len < 4096 else { rxBuf.removeAll(); return }
            guard rxBuf.count >= len + 2 else { return }
            let payload = Data(rxBuf[2..<(2 + len)])
            rxBuf.removeFirst(2 + len)
            if let m = try? JSONDecoder().decode(MeshMessage.self, from: payload) {
                handle(m)
            }
        }
    }

    private func handle(_ m: MeshMessage) {
        // Any inbound traffic proves the far end is alive, even duplicates.
        watchdog.heard(at: Date().timeIntervalSince1970)

        if seen.contains(m.mid) {
            // A retransmission means our receipt was probably lost. Re-ack it,
            // or the sender retries four times and then gives up.
            if m.type == "msg" || m.type == "selftest" {
                transmit(MeshMessage(from: nodeId, to: m.from, type: "ack", body: m.mid))
            }
            return
        }
        seen.insert(m.mid)
        if seen.count > 800 { seen.removeAll() }

        switch m.type {
        case "ack":
            store.remove(m.body, for: m.from)
            refreshQueued()
            if let t0 = lastSendAt[m.body] {
                let ms = (Date().timeIntervalSince1970 - t0) * 1000
                let bytes = sentBytes[m.body] ?? 0
                // The phone reports its own app state on the receipt, so the
                // dashboard's "locked deliveries" figure is measured rather
                // than assumed.
                let app = m.hops?.first ?? ""
                let locked = !app.isEmpty && app != "active"
                DispatchQueue.main.async { self.lastLatency = ms }
                logLocal(String(format: "ACK %dB in %.0f ms (%@)", bytes, ms, app))
                postEvent(["kind": "ack",
                           "detail": "acked \(bytes)B in \(Int(ms)) ms · app=\(app)",
                           "ms": ms,
                           "bytes": bytes,
                           "locked": locked,
                           "app": app,
                           "node": nodeId])
            }
        case "loc":
            if let la = m.lat, let lo = m.lon {
                logLocal(String(format: "GPS %.5f, %.5f", la, lo))
                postEvent(["kind": "loc", "lat": la, "lon": lo, "node": m.from])
            }
        case "msg", "selftest":
            // Receipt in the phone→anchor direction. Without this the phone's
            // outbox never clears and it retransmits every message 4 times.
            let body = openBody(m.body)
            logLocal("\(m.from): \(body)")
            postEvent(["kind": "recv", "detail": body, "node": m.from])
            transmit(MeshMessage(from: nodeId, to: m.from, type: "ack", body: m.mid))
        case "heartbeat":
            // Silence-keeper only; it proves the link is alive without
            // pretending to be a message. Surface one every five minutes.
            heartbeats += 1
            if let b = m.batt {
                DispatchQueue.main.async { self.phoneBattery = b }
            }
            if let r = m.rssi {
                DispatchQueue.main.async { self.phoneRSSI = r }
            }
            // Publish every heartbeat: the dashboard uses these for the
            // battery/signal readout and does not show them in the feed.
            var ev: [String: Any] = ["kind": "hb",
                                     "detail": "phone heartbeat \(heartbeats)",
                                     "node": m.from]
            if let b = m.batt { ev["batt"] = b }
            if let r = m.rssi { ev["rssi"] = r }
            postEvent(ev)
        case "hello":
            knownNode = m.from
            logLocal("hello from \(m.from) — \(m.body)")
            postEvent(["kind": "hello", "detail": m.body, "node": m.from])
            flushQueue(for: m.from)
        default:
            let body = openBody(m.body)
            logLocal("\(m.from): \(body)")
            postEvent(["kind": "recv", "detail": body, "node": m.from])
        }
    }

    // MARK: Send

    func send(_ body: String) {
        let now = Date().timeIntervalSince1970

        guard let dest = knownNode else {
            let m = MeshMessage(from: nodeId, to: "*", body: body)
            transmit(m)
            logLocal("-> \(body) (broadcast, no phone known yet)")
            postEvent(["kind": "send", "detail": body, "node": nodeId])
            return
        }

        // More than one phone linked: address everyone rather than only the
        // last phone that said hello.
        if subscribers > 1 {
            let m = MeshMessage(from: nodeId, to: "*", body: body)
            lastSendAt[m.mid] = now
            transmit(m)
            logLocal("-> \(body) (broadcast to \(subscribers) phones)")
            postEvent(["kind": "send", "detail": body, "node": nodeId])
            return
        }

        // At-least-once: always queue, transmit opportunistically, let the ack
        // clear it. A phone that is asleep or gone gets it on reconnect.
        let m = MeshMessage(from: nodeId, to: dest, body: body)
        lastSendAt[m.mid] = now
        store.enqueue(m)
        refreshQueued()
        transmit(m)

        if watchdog.isLive(now: now, subscribers: subscribers) {
            logLocal("-> \(body)")
            postEvent(["kind": "send", "detail": body, "node": nodeId])
        } else {
            let quiet = watchdog.silence(now: now)
                .map { String(format: "%.0fs quiet", $0) } ?? "no traffic yet"
            logLocal("queued for \(dest) — link stale, \(quiet)")
            postEvent(["kind": "queued", "detail": body, "node": nodeId])
        }
    }

    private func transmit(_ m: MeshMessage) {
        guard tx != nil else { return }
        var out = m
        if out.type == "msg", !out.body.hasPrefix("e1:") {
            if let sealed = try? Envelope.sealString(out.body, key: key) {
                out.body = "e1:" + sealed
            }
        }
        guard let payload = try? JSONEncoder().encode(out) else { return }
        sentBytes[m.mid] = payload.count
        enqueue(Wire.frame(payload))
    }

    private func openBody(_ s: String) -> String {
        guard s.hasPrefix("e1:") else { return s }
        let b64 = String(s.dropFirst(3))
        return (try? Envelope.openString(b64, key: key)) ?? "[unreadable]"
    }

    /// Replay everything still unacked for a node.
    private func flushQueue(for node: String) {
        guard subscribers > 0 else { return }
        let pending = store.pending(for: node)
        for m in pending {
            transmit(m)
            logLocal("replayed \(m.mid) -> \(node)")
        }
        if !pending.isEmpty {
            postEvent(["kind": "flush",
                       "detail": "\(pending.count) replayed",
                       "node": nodeId])
        }
        refreshQueued()
    }

    private func refreshQueued() {
        DispatchQueue.main.async { self.queued = self.store.pendingCount }
    }

    private func enqueue(_ frame: Data) {
        var i = 0
        while i < frame.count {
            let end = min(i + 150, frame.count)
            pending.append(frame.subdata(in: i..<end))
            i = end
        }
        flush()
    }

    private func flush() {
        guard let tx = tx else { return }
        while let next = pending.first {
            if pm.updateValue(next, for: tx, onSubscribedCentrals: nil) {
                pending.removeFirst()
            } else {
                return
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flush()
    }

    // MARK: Dashboard

    private func postEvent(_ dict: [String: Any]) {
        guard let url = URL(string: "http://127.0.0.1:8787/event") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = dict
        body["t"] = Date().timeIntervalSince1970
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }
}

// MARK: - UI

struct AnchorView: View {
    @EnvironmentObject var anchor: Anchor
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(anchor.linkLive ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(anchor.linkLive ? "PHONE LINKED" : "NO PHONE · QUEUEING")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .kerning(1)
                        .foregroundStyle(anchor.linkLive ? Color.green : Color.orange)
                    Text(anchor.advertising ? "AWAKE-ANCHOR · ADVERTISING" : "RADIO NOT READY")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if anchor.queued > 0 {
                    Text("\(anchor.queued) unacked")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                if let r = anchor.phoneRSSI {
                    Text("\(r) dBm")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(r > -70 ? Color.green : Color.orange)
                }
                if let b = anchor.phoneBattery {
                    Text("\(b)%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(b < 20 ? Color.orange : Color.secondary)
                }
                if let l = anchor.lastLatency {
                    Text(String(format: "%.0f ms", l))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(anchor.lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: anchor.lines.count) { _, _ in
                    withAnimation { proxy.scrollTo(anchor.lines.count - 1, anchor: .bottom) }
                }
            }

            Divider()

            HStack(spacing: 10) {
                TextField("Message the phone…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.12)))
                    .onSubmit(send)

                Button(action: send) {
                    HStack(spacing: 6) {
                        Image(systemName: "paperplane.fill")
                        Text("SEND")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .kerning(1)
                    }
                    .frame(width: 100, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9)
                        .fill(draft.isEmpty ? Color(white: 0.18) : Color.green))
                    .foregroundStyle(draft.isEmpty ? Color(white: 0.45) : Color.black)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(draft.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 480, minHeight: 560)
        .preferredColorScheme(.dark)
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        anchor.send(t)
        draft = ""
    }
}
