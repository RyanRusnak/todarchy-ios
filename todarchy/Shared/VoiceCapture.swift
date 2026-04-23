import Foundation
import AVFoundation
import Speech
import Combine

/// On-device voice capture + live transcription for quick task entry.
/// Uses Apple's `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`
/// so utterances never leave the device. Exposes `partial` for a live
/// preview and `level` (0…1) for an equalizer visualization driven by the
/// mic's instantaneous RMS.
@MainActor
final class VoiceCapture: ObservableObject {
    enum State: Equatable {
        case idle
        case preparing      // authorizing + starting
        case listening
        case error(String)
    }

    /// Live partial transcript; resets on each `start()`.
    @Published private(set) var partial: String = ""
    /// Smoothed 0…1 mic level for the visualizer.
    @Published private(set) var level: Float = 0
    @Published private(set) var state: State = .idle

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    init() {
        // `SFSpeechRecognizer(locale:)` can return nil for unsupported
        // locales — fall back to device default if en-US isn't set up.
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            ?? SFSpeechRecognizer()
    }

    // MARK: - Authorization

    /// Requests both mic + speech auth. Returns true if both granted.
    func ensureAuthorized() async -> Bool {
        // Speech
        let speechOK = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { return false }

        // Microphone
        #if os(iOS)
        let micOK: Bool = await withCheckedContinuation { cont in
            if #available(iOS 17, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
        return micOK
        #else
        let micOK: Bool = await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
        return micOK
        #endif
    }

    // MARK: - Lifecycle

    /// Start recording + recognition. Safe to call repeatedly — a second
    /// call stops the previous session first.
    func start() async {
        stop()
        partial = ""
        state = .preparing

        guard await ensureAuthorized() else {
            state = .error("Microphone or speech recognition access was denied. Grant permission in Settings.")
            return
        }

        guard let recognizer, recognizer.isAvailable else {
            state = .error("Speech recognizer isn't available on this device.")
            return
        }

        #if os(iOS)
        // Configure session for mic input. `.measurement` gives us the
        // raw signal; `.duckOthers` keeps playing audio quiet while we
        // listen.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            state = .error("Couldn't start the mic session: \(error.localizedDescription)")
            return
        }
        #endif

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        // Pipe mic buffers to both the recognizer and our level meter.
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        node.removeTap(onBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.updateLevel(from: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            state = .error("Audio engine failed to start: \(error.localizedDescription)")
            return
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.partial = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    // Recognition ended on its own — we keep the text and
                    // let the caller decide whether to commit or cancel.
                }
            }
        }

        state = .listening
    }

    /// Stop recording. Keeps `partial` intact so callers can commit it.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        level = 0
        if case .listening = state { state = .idle }
        if case .preparing = state { state = .idle }

        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Stop + return whatever we've transcribed. Convenience for the
    /// commit path.
    func finish() -> String {
        let captured = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        return captured
    }

    // MARK: - Level meter

    /// Root-mean-square of the buffer, compressed to 0…1 with a bit of
    /// smoothing so the visualizer doesn't jitter.
    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sum: Float = 0
        for i in 0..<frames {
            let s = channelData[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))
        // Map ~ -60dB…0dB (0.001…1.0) to 0…1 with a log curve.
        let db = 20 * log10(max(rms, 0.000_1))
        let norm = max(0, min(1, (db + 60) / 60))

        Task { @MainActor in
            // Smooth with an attack of 0.5 and decay of 0.15 so bars
            // rise quickly and fall gently.
            if norm > self.level {
                self.level = self.level * 0.5 + norm * 0.5
            } else {
                self.level = self.level * 0.85 + norm * 0.15
            }
        }
    }
}
