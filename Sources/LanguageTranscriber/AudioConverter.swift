import AVFoundation

/// Converts arbitrary AVAudioPCMBuffer inputs to 24 kHz mono Int16 PCM (little-endian),
/// the format expected by OpenAI's realtime transcription API ("pcm16").
final class AudioConverter {
    static let targetSampleRate: Double = 24000
    static let targetChannels: AVAudioChannelCount = 1

    private let outputFormat: AVAudioFormat
    private var converters: [String: AVAudioConverter] = [:]

    init() {
        // Interleaved Int16 mono @ 24kHz
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: Self.targetChannels,
            interleaved: true
        )!
    }

    func convert(_ inputBuffer: AVAudioPCMBuffer) -> Data? {
        let inFormat = inputBuffer.format
        let key = formatKey(inFormat)
        let converter: AVAudioConverter
        if let cached = converters[key] {
            converter = cached
        } else {
            guard let c = AVAudioConverter(from: inFormat, to: outputFormat) else { return nil }
            converters[key] = c
            converter = c
        }

        let ratio = outputFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            return nil
        }

        var error: NSError?
        var supplied = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || error != nil { return nil }
        guard outBuffer.frameLength > 0,
              let ptr = outBuffer.int16ChannelData?[0] else { return nil }

        let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
        return Data(bytes: ptr, count: byteCount)
    }

    private func formatKey(_ fmt: AVAudioFormat) -> String {
        "\(fmt.sampleRate)-\(fmt.channelCount)-\(fmt.commonFormat.rawValue)-\(fmt.isInterleaved)"
    }
}
