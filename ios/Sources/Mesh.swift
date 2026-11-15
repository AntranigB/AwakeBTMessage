import Foundation
import CoreBluetooth
import CoreLocation
import UIKit
import UserNotifications
import Combine
import AwakeCore

struct LogEvent: Identifiable {
    let id = UUID()
    let t: Date
    let kind: String
    let detail: String
    let appState: String
}

enum Notifier {
    static func request() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.threadIdentifier = "awake"
        // Punches through Focus / Do Not Disturb. Requires the Time Sensitive
        // Notifications capability, declared in Awake.entitlements.
        c.interruptionLevel = .timeSensitive
        let r = UNNotificationRequest(identifier: UUID().uuidString,
                                      content: c,
                                      trigger: nil)
        UNUserNotificationCenter.current().add(r, withCompletionHandler: nil)
    }
}

final class Mesh: NSObject, ObservableObject {

    @Published var connected = false
    @Published var scanning = false
    @Published var centralState: CBManagerState = .unknown
    @Published var messages: [MeshMessage] = []
    @Published var log: [LogEvent] = []
    @Published var peerName = "—"
    @Published var lastLatency: Double?
    @Published var lockedHits = 0
    @Published var myLat: Double?
    @Published var myLon: Double?
    @Published var wakeReason = "launch"
    @Published var pendingIDs: Set<String> = []

    let nodeId = "IPH1"

    private var central: CBCentralManager!
    private var peer: CBPeripheral?
    private var rxChar: CBCharacteristic?
    private var txChar: CBCharacteristic?
    private var rxBuf: [UInt8] = []
    private var sentAt: [String: Double] = [:]
    private var seen = Set<String>()
    private var lastLocSent = Date.distantPast
    private var heartbeatTimer: Timer?
    private var lastRSSI: Int?
    private var linkWatchdog: Timer?
    private var reconnectAttempts = 0
    private var backoff: TimeInterval = 8
    private var nextScanAt = Date.distantPast
    private let loc = CLLocationManager()

    private let key = Envelope.key(from: kDemoPSK)
    private var outbox: [String: MeshMessage] = [:]
    private var attempts: [String: Int] = [:]
    private var retryTimer: Timer?

    /// `--sample`, or `SIMCTL_CHILD_AWAKE_SAMPLE=<count>` in the simulator.
    /// Any non-empty value counts; the value itself is the message count.
    static var isSampleMode: Bool {
        if CommandLine.arguments.contains("--sample") { return true }
        return !(ProcessInfo.processInfo.environment["AWAKE_SAMPLE"] ?? "").isEmpty
    }

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.awake.central"])
        loc.delegate = self
        loc.desiredAccuracy = kCLLocationAccuracyHundredMeters

        // Start the radio from process launch, not from a view's onAppear.
        // If the app is launched while the phone is locked, no SwiftUI scene
        // is created and onAppear never fires — the radio would stay cold and
        // nothing would ever connect.
        DispatchQueue.main.async { [weak self] in self?.boot() }
        // NOTE: allowsBackgroundLocationUpdates must only be set once
        // authorization is granted, otherwise CoreLocation raises and the app
        // dies at launch. It is therefore set in the authorization callback.
        loc.pausesLocationUpdatesAutomatically = false
    }

    private var booted = false

    func boot() {
        guard !booted else { return }
        booted = true
        restore()

        // Sample mode is a UI-inspection aid: no radio, no permission prompts.
        let sample = Mesh.isSampleMode
        if sample { seedSamples() }

        if !sample { Notifier.request() }
        startRetryTimer()
        startHeartbeat()
        startLinkWatchdog()
        if !sample {
            if loc.authorizationStatus == .notDetermined {
                loc.requestWhenInUseAuthorization()
            } else if loc.authorizationStatus == .authorizedWhenInUse {
                loc.startUpdatingLocation()
            }
            start()
        }
    }

    /// UI development aid: `simctl launch <device> <bundle> --sample`
    /// populates the transcript so bubble layout can be inspected without a
    /// radio. Never reached in normal operation.
    private func seedSamples() {
        // AWAKE_SAMPLE sets the message count: `AWAKE_SAMPLE=40` for a long
        // transcript, unset for the three-message default.
        let count = max(1, Int(ProcessInfo.processInfo.environment["AWAKE_SAMPLE"] ?? "3") ?? 3)
        let now = Date().timeIntervalSince1970
        let lines = [
            "where are you",
            "north gate, by the speakers",
            "queue is long at the west entrance — come round to the east side, I'll wait by the blue sign and keep the radio on",
            "ok",
            "two minutes",
            "security says the east gate is shut",
            "heading to the front",
            "can you see the green tent",
            "yes",
            "almost there"
        ]
        var out: [MeshMessage] = []
        for i in 0..<count {
            let mine = i % 2 == 1
            var m = MeshMessage(from: mine ? nodeId : "ANCH",
                                to: mine ? "*" : nodeId,
                                body: lines[i % lines.count],
                                mid: String(format: "S%03d", i))
            m.ts = now - Double(count - i) * 45
            out.append(m)
        }
        messages = out
    }

    // MARK: Persistence

    private var storeDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Awake", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(Array(messages.suffix(300))) {
            try? d.write(to: storeDir.appendingPathComponent("messages.json"))
        }
        if let d = try? JSONEncoder().encode(Array(outbox.values)) {
            try? d.write(to: storeDir.appendingPathComponent("outbox.json"))
        }
    }

    private func restore() {
        if let d = try? Data(contentsOf: storeDir.appendingPathComponent("messages.json")),
           let m = try? JSONDecoder().decode([MeshMessage].self, from: d) {
            messages = m
            // Seed dedupe from the restored transcript. Without this, a replayed
            // message whose ack was lost shows up as a second bubble after a
            // relaunch.
            seen = Set(m.map(\.mid))
        }
        if let d = try? Data(contentsOf: storeDir.appendingPathComponent("outbox.json")),
           let o = try? JSONDecoder().decode([MeshMessage].self, from: d) {
            for m in o {
                outbox[m.mid] = m
                pendingIDs.insert(m.id)
            }
        }
    }

    // MARK: Link management

    func start() {
        guard central.state == .poweredOn else { return }

        // A peripheral handed back by state restoration can already be
        // connected. Returning here was a deadlock: no didConnect fires, so
        // services were never discovered and tx never worked again.
        if let p = peer, p.state == .connected {
            if rxChar == nil {
                p.delegate = self
                addLog("connect", "restored link — re-discovering services")
                p.discoverServices([kServiceUUID])
            }
            return
        }

        if let s = UserDefaults.standard.string(forKey: "peerID"),
           let u = UUID(uuidString: s),
           let p = central.retrievePeripherals(withIdentifiers: [u]).first {
            peer = p
            p.delegate = self
            central.connect(p, options: nil)
            addLog("connect", "reconnecting to known anchor")
            return
        }
        scan()
    }

    func scan() {
        guard central.state == .poweredOn else { return }
        central.stopScan()
        central.scanForPeripherals(
            withServices: [kServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true
        addLog("scan", "searching for anchor")
    }

    // MARK: Sending

    @discardableResult
    func send(_ body: String) -> Bool {
        let m = MeshMessage(from: nodeId, to: "*", body: body)
        messages.append(m)
        outbox[m.mid] = m
        pendingIDs.insert(m.id)
        attempts[m.mid] = 1
        transmit(m)
        persist()
        return true
    }

    /// One ~500-byte message, used to exercise the upload direction:
    /// multi-chunk framing phone→anchor, and the anchor's receipt coming back.
    func sendSelfTest() {
        let body = "selftest " + String(repeating: "x", count: 480)
        let m = MeshMessage(from: nodeId, to: "*", type: "selftest", body: body)
        outbox[m.mid] = m
        pendingIDs.insert(m.id)
        attempts[m.mid] = 1
        transmit(m)
        persist()
        addLog("selftest", "sent \(body.utf8.count) bytes")
    }

    func sendLocation() {
        guard let la = myLat, let lo = myLon else {
            addLog("loc", "no fix yet")
            return
        }
        _ = transmit(MeshMessage(from: nodeId, to: "*", type: "loc", lat: la, lon: lo))
        lastLocSent = Date()
    }

    @discardableResult
    private func transmit(_ m: MeshMessage) -> Bool {
        guard let rx = rxChar, let p = peer, p.state == .connected else {
            addLog("queue", "holding \(m.mid) until link returns")
            return false
        }

        var out = m
        if out.type == "msg", let sealed = try? Envelope.sealString(out.body, key: key) {
            out.body = "e1:" + sealed
        }
        guard let payload = try? JSONEncoder().encode(out) else { return false }
        sentAt[m.mid] = Date().timeIntervalSince1970

        var frame = Data()
        let n = UInt16(payload.count)
        frame.append(UInt8((n >> 8) & 0xFF))
        frame.append(UInt8(n & 0xFF))
        frame.append(payload)

        for part in Wire.chunks(frame) {
            p.writeValue(part, for: rx, type: .withResponse)
        }

        if m.type == "msg" { addLog("send", "-> \(m.body)") }
        else { addLog(m.type, "sent \(m.type)") }
        return true
    }

    /// The anchor decides the link is stale after 90 s of silence. Without this,
    /// the only routine traffic is GPS — so denying location, or standing
    /// indoors with no fix, makes a perfectly healthy link look dead.
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.connected else { return }
            // A peripheral cannot read RSSI from a connected central, but the
            // central can read the peripheral. So the phone measures its own
            // link to the anchor and reports it.
            self.peer?.readRSSI()
            _ = self.transmit(MeshMessage(from: self.nodeId, to: "*",
                                          type: "heartbeat", body: "",
                                          batt: self.batteryPercent(),
                                          rssi: self.lastRSSI))
        }
        RunLoop.main.add(t, forMode: .common)
        heartbeatTimer = t
    }

    /// Battery rides along with the heartbeat so the venue dashboard can flag
    /// a phone that is about to die before it dies.
    private func batteryPercent() -> Int? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return nil }
        return Int((level * 100).rounded())
    }

    /// A pending `connect()` never times out. If the anchor comes back with a
    /// different identity, or the saved peripheral stops existing, the app will
    /// otherwise wait forever and never look again. This forces a rescan.
    private func startLinkWatchdog() {
        linkWatchdog?.invalidate()
        let t = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.central.state == .poweredOn, !self.connected else { return }
            guard Date() >= self.nextScanAt else { return }

            self.reconnectAttempts += 1
            if self.reconnectAttempts == 1 || self.reconnectAttempts % 4 == 0 {
                self.addLog("recover", "not linked — rescanning (#\(self.reconnectAttempts), next in \(Int(self.backoff))s)")
            }
            self.scan()

            // Recover fast when it just dropped, then stop hammering the radio:
            // an unlinked phone left in a bag should not scan every 8s all day.
            self.backoff = min(60, self.backoff * 1.6)
            self.nextScanAt = Date().addingTimeInterval(self.backoff)
        }
        RunLoop.main.add(t, forMode: .common)
        linkWatchdog = t
    }

    private func startRetryTimer() {
        retryTimer?.invalidate()
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            self?.retryPending()
        }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    private func retryPending() {
        guard connected, !outbox.isEmpty else { return }
        for (mid, m) in Array(outbox) {
            let n = attempts[mid] ?? 0
            if n >= 4 {
                outbox.removeValue(forKey: mid)
                pendingIDs.remove(m.id)
                addLog("drop", "no ack for \(mid) after \(n) tries")
                continue
            }
            attempts[mid] = n + 1
            transmit(m)
        }
        persist()
    }

    private func flushOutbox() {
        guard connected else { return }
        for (_, m) in Array(outbox) { transmit(m) }
    }

    // MARK: Receiving

    private func feed(_ data: Data) {
        rxBuf.append(contentsOf: data)
        for payload in Wire.drain(&rxBuf) {
            if let m = Wire.decode(payload) { handle(m) }
        }
    }

    private func handle(_ m: MeshMessage) {
        if m.type == "ack" {
            outbox.removeValue(forKey: m.body)
            pendingIDs.remove(m.body + nodeId)
            if let t0 = sentAt[m.body] {
                let ms = (Date().timeIntervalSince1970 - t0) * 1000
                lastLatency = ms
                addLog("ack", String(format: "delivered in %.0f ms", ms))
            }
            // Persist unconditionally. After a relaunch `sentAt` is empty, but
            // the ack still cleared the outbox and that must survive a restart
            // or the message is re-sent forever.
            persist()
            return
        }

        guard !seen.contains(m.mid) else { return }
        seen.insert(m.mid)
        if seen.count > 800 { seen.removeAll() }

        // Not addressed to us.
        if m.to != "*" && m.to != nodeId { return }

        var msg = m
        if msg.type == "msg", msg.body.hasPrefix("e1:") {
            let b64 = String(msg.body.dropFirst(3))
            if let plain = try? Envelope.openString(b64, key: key) {
                msg.body = plain
            } else {
                addLog("crypto", "could not open body from \(m.from)")
            }
        }

        let state = UIApplication.shared.applicationState
        let name = state == .active ? "active"
                 : (state == .background ? "background" : "inactive")
        let wasLocked = state != .active

        // Receipts for anything that expects one: chat, upload probes, and the
        // anchor's silent round-trip ping.
        if msg.type == "msg" || msg.type == "ping" || msg.type == "selftest" {
            _ = transmit(MeshMessage(from: nodeId, to: msg.from, type: "ack",
                                     body: msg.mid, hops: [name]))
        }

        if msg.type == "msg" {
            messages.append(msg)
            if wasLocked { lockedHits += 1 }
            addLog("recv", "\(msg.from): \(msg.body) · app=\(name)")
            Notifier.post(title: "Awake · \(msg.from)", body: msg.body)
            if state == .active { Voice.shared.speak(msg.body) }
            persist()
        } else if msg.type == "ping" {
            addLog("ping", "acked \(msg.mid)")
        } else {
            addLog(msg.type, "from \(msg.from)")
        }
    }

    func addLog(_ kind: String, _ detail: String) {
        let s = UIApplication.shared.applicationState
        let name = s == .active ? "fg" : (s == .background ? "bg" : "inact")
        log.append(LogEvent(t: Date(), kind: kind, detail: detail, appState: name))
        if log.count > 500 { log.removeFirst(log.count - 500) }
        appendFile("\(name) \(kind) \(detail)")
    }

    /// Persisted diagnostics, so the device can be debugged without unlocking
    /// it: `xcrun devicectl device copy from ... Documents/awake.log`
    private func appendFile(_ line: String) {
        let dir = FileManager.default.urls(for: .documentDirectory,
                                           in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("awake.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Central

extension Mesh: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        centralState = central.state
        addLog("state", "CBManagerState \(central.state.rawValue)")
        if central.state == .poweredOn {
            start()
        } else {
            connected = false
        }
    }

    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {
        wakeReason = "restored by iOS"
        addLog("wake", "iOS restored BLE state")
        if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for p in restored {
                peer = p
                p.delegate = self
                if p.state == .connected {
                    // Already up; go straight to discovery.
                    p.discoverServices([kServiceUUID])
                    addLog("connect", "restored peripheral already connected")
                } else {
                    central.connect(p, options: nil)
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        central.stopScan()
        scanning = false
        peer = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "peerID")
        addLog("found", "anchor \(peripheral.name ?? "?") rssi \(RSSI)")
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        connected = true
        reconnectAttempts = 0
        backoff = 8
        nextScanAt = .distantPast
        peerName = peripheral.name ?? "anchor"
        addLog("link", "connected to \(peerName)")
        peripheral.discoverServices([kServiceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        connected = false
        rxChar = nil
        txChar = nil
        addLog("link", "disconnected — reconnecting")
        // A pending connect never times out. iOS will wake us when it completes.
        central.connect(peripheral, options: nil)
    }
}

// MARK: - Peripheral

extension Mesh: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == kServiceUUID })
        else { return }
        peripheral.discoverCharacteristics([kRXUUID, kTXUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == kRXUUID { rxChar = c }
            if c.uuid == kTXUUID {
                txChar = c
                peripheral.setNotifyValue(true, for: c)
                // Prime the signal reading so the first heartbeat carries one.
                peripheral.readRSSI()
            }
        }
        guard rxChar != nil else { return }
        addLog("ready", "subscribed — wakes on lock")
        if CommandLine.arguments.contains("--selftest") {
            sendSelfTest()
        }
        _ = transmit(MeshMessage(from: nodeId, to: "*", type: "hello",
                                 body: UIDevice.current.name))
        sendLocation()
        flushOutbox()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didReadRSSI RSSI: NSNumber,
                    error: Error?) {
        guard error == nil else { return }
        lastRSSI = RSSI.intValue
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == kTXUUID, let d = characteristic.value else { return }
        let s = UIApplication.shared.applicationState
        if s != .active {
            wakeReason = "BLE notify while \(s == .background ? "background" : "inactive")"
        }
        feed(d)
    }
}

// MARK: - Location

extension Mesh: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else { return }

        // Keeps the process resident so the BLE link survives the screen going
        // off. Justified by the group location-sharing feature we actually
        // ship, not a trick to dodge suspension.
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        addLog("loc", "background updates armed")
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        myLat = l.coordinate.latitude
        myLon = l.coordinate.longitude
        if Date().timeIntervalSince(lastLocSent) > 25 {
            lastLocSent = Date()
            sendLocation()
        }
    }
}
