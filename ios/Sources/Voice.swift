import Foundation
import AVFoundation
import WhisperKit

/// Fully on-device voice: Argmax WhisperKit for speech-to-text,
/// AVSpeechSynthesizer for playback. No network, ever, once the model is cached.
final class Voice: ObservableObject {

    static let shared = Voice()

    @Published var status = "idle"        // idle | loading | ready | recording | transcribing | error
    @Published var lastText = ""
    @Published var lastError = ""

    private var pipe: WhisperKit?
    private var recorder: AVAudioRecorder?
    private let synth = AVSpeechSynthesizer()

    private var fileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("awake-voice.m4a")
    }

    var isReady: Bool { pipe != nil }

    /// Loads the Whisper model. First call needs network to fetch weights,
    /// after that the model is cached on device and works offline.
    func prepare() async {
        if pipe != nil { return }
        if Mesh.isSampleMode {
            await setStatus("sample")
            return
        }
        await setStatus("loading")
        do {
            let config = WhisperKitConfig(model: "base.en")
            let loaded = try await WhisperKit(config)
            pipe = loaded
            await setStatus("ready")
        } catch {
            await setStatus("error")
            await setError(error.localizedDescription)
        }
    }

    func startRecording() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 mode: .default,
                                 options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        recorder = try? AVAudioRecorder(url: fileURL, settings: settings)
        recorder?.record()
        setStatus("recording")
    }

    /// Stops, transcribes on device, returns the text.
    func stopRecording() async -> String {
        recorder?.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
        guard let pipe else { return "" }
        setStatus("transcribing")
        do {
            let results = try await pipe.transcribe(audioPath: fileURL.path)
            let text = results.map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lastText = text
            setStatus("ready")
            return text
        } catch {
            setStatus("error")
            lastError = error.localizedDescription
            return ""
        }
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? session.setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        u.rate = 0.52
        synth.speak(u)
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { self.status = s }
    }

    private func setError(_ s: String) {
        DispatchQueue.main.async { self.lastError = s }
    }
}
