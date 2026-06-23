import AVFoundation

final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private let converter = AudioConverter()
    private var tapInstalled = false

    var onAudio: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    func start() {
        do {
            let input = engine.inputNode
            // NOTE: we deliberately do NOT enable AVAudioEngine voice processing here.
            // It would activate macOS's audio-ducking pipeline (drops the volume of every
            // other app's output, including the system-audio we're trying to capture)
            // AND requires the engine to have a connected output node we don't provide,
            // which silently breaks the input tap. Echo from the speakers is now handled
            // by the text-level Jaccard dedup in TranscriberViewModel — users on speakers
            // should still wear headphones for best results.
            let format = input.outputFormat(forBus: 0)

            // Some virtual devices report 0Hz at startup — bail with a clear message.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                onError?("Microphone input format unavailable (\(format)). Is a mic connected and permission granted?")
                return
            }

            if tapInstalled {
                input.removeTap(onBus: 0)
            }
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                if let pcm16 = self.converter.convert(buffer) {
                    self.onAudio?(pcm16)
                }
            }
            tapInstalled = true

            engine.prepare()
            try engine.start()
        } catch {
            onError?("Failed to start microphone: \(error.localizedDescription)")
        }
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }
}
