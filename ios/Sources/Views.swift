import SwiftUI
import AwakeCore

struct ContentView: View {
    @EnvironmentObject var mesh: Mesh
    @StateObject private var voice = Voice.shared
    @State private var draft = ""
    @State private var showLog = false
    @State private var recording = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                proofBar
                messageList
                composer
            }
            .background(Color(white: 0.04).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("A W A K E")
                        .font(.system(.footnote, design: .monospaced))
                        .kerning(4)
                        .foregroundStyle(.white.opacity(0.85))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showLog = true } label: {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(.green)
                    }
                }
            }
            .sheet(isPresented: $showLog) {
                LogView().environmentObject(mesh)
            }
            .onAppear { Task { await voice.prepare() } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(mesh.connected ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(mesh.connected
                     ? "LINKED · \(mesh.peerName.uppercased())"
                     : (mesh.scanning ? "SEARCHING FOR ANCHOR" : "RADIO OFF"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(mesh.connected ? .green : .orange)
                Spacer()
                if let l = mesh.lastLatency {
                    Text(String(format: "%.0f ms", l))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                if voice.status != "ready" && voice.status != "idle" {
                    Text("VOICE·\(voice.status.uppercased())")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 12) {
                Label("NO WIFI", systemImage: "wifi.slash")
                Label("NO CELL", systemImage: "antenna.radiowaves.left.and.right.slash")
                if mesh.myLat != nil {
                    Label("GPS", systemImage: "location.fill")
                }
            }
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var proofBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 10))
            Text("\(mesh.lockedHits) DELIVERED WHILE LOCKED")
                .font(.system(size: 10, design: .monospaced))
            Spacer()
            if mesh.wakeReason != "launch" {
                Text(mesh.wakeReason.uppercased())
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .foregroundStyle(mesh.lockedHits > 0 ? Color.green : Color.white.opacity(0.4))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if mesh.messages.isEmpty {
                        VStack(spacing: 6) {
                            Text("NO MESSAGES")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                            Text("Lock this phone, then send from the anchor.")
                                .font(.system(.caption2, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.2))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }
                    ForEach(mesh.messages) { m in
                        bubble(m).id(m.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: mesh.messages.count) { _, _ in
                guard let last = mesh.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func bubble(_ m: MeshMessage) -> some View {
        let mine = m.from == mesh.nodeId
        return HStack {
            if mine { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 3) {
                Text(m.body)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
                Text(mesh.pendingIDs.contains(m.id)
                     ? "\(m.from) · queued…"
                     : "\(m.from) · \(clock(m.ts))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(mine ? Color(red: 0.08, green: 0.42, blue: 0.28)
                               : Color(white: 0.13))
            )
            if !mine { Spacer(minLength: 44) }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Button { Task { await toggleMic() } } label: {
                Image(systemName: recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(recording ? Color.black : Color.white.opacity(0.8))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(recording ? Color.red : Color(white: 0.13)))
            }

            Button { mesh.sendLocation() } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color(white: 0.13)))
            }

            TextField("", text: $draft,
                      prompt: Text("Message…").foregroundStyle(.white.opacity(0.3)))
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 19).fill(Color(white: 0.10)))
                .submitLabel(.send)
                .onSubmit(sendDraft)

            Button(action: sendDraft) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(canSend ? Color.green : Color(white: 0.3)))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.07).ignoresSafeArea(edges: .bottom))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func toggleMic() async {
        if recording {
            recording = false
            let text = await voice.stopRecording()
            if !text.isEmpty {
                _ = mesh.send(text)
                draft = ""
            }
        } else {
            if !voice.isReady { await voice.prepare() }
            voice.startRecording()
            recording = true
        }
    }

    private func sendDraft() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if mesh.send(t) { draft = "" }
    }

    private func clock(_ ts: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

struct LogView: View {
    @EnvironmentObject var mesh: Mesh
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    info("radio", mesh.centralState == .poweredOn
                              ? "powered on" : "state \(mesh.centralState.rawValue)")
                    info("link", mesh.connected ? mesh.peerName : "searching")
                    info("wake reason", mesh.wakeReason)
                    info("locked deliveries", "\(mesh.lockedHits)")
                    info("last latency", mesh.lastLatency.map { String(format: "%.0f ms", $0) } ?? "—")
                } header: {
                    Text("RADIO").font(.system(.caption2, design: .monospaced))
                }

                Section {
                    ForEach(mesh.log.reversed()) { e in
                        HStack(alignment: .top, spacing: 8) {
                            Text(e.appState)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .leading)
                            Text(e.kind)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.green)
                                .frame(width: 52, alignment: .leading)
                            Text(e.detail)
                                .font(.system(size: 10, design: .monospaced))
                        }
                    }
                } header: {
                    Text("EVENT LOG").font(.system(.caption2, design: .monospaced))
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text(v)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
        }
    }
}
