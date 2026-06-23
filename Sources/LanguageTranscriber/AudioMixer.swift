import Foundation

/// Sums two 24 kHz mono Int16 PCM streams (microphone + system audio) into a single
/// PCM16 stream of the same format, which is what the OpenAI realtime API consumes.
///
/// Each input source feeds raw PCM bytes via `feedMic`/`feedSystem`. A timer-driven
/// 20 ms tick pulls equal-length chunks from both internal buffers, pads with zeros
/// for whichever side is short, sample-adds, clamps to Int16, and emits the mixed PCM.
///
/// Why a timer instead of event-driven mixing: if one source briefly stops emitting
/// (network hiccup, paused stream), an event-driven mixer would either block forever
/// waiting for the silent side, or risk dropping audio when the cap is hit. The timer
/// guarantees we keep streaming at exactly 50 Hz regardless of per-source jitter.
final class AudioMixer {
    static let sampleRate: Double = 24000
    private let chunkSamples: Int = 480                       // 20 ms at 24 kHz
    private let maxBufferedSamples: Int = 24000 * 2           // 2 s safety cap

    private var micBuffer:  [Int16] = []
    private var sysBuffer:  [Int16] = []
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    /// Emitted on the mixer's internal queue. Callers should hop to whatever queue
    /// they need (e.g. for WebSocket send, none required).
    var onMixedPCM16: ((Data) -> Void)?

    func start() {
        stop()
        let queue = DispatchQueue(label: "com.languagetranscriber.audiomixer", qos: .userInitiated)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(20),
                   repeating: .milliseconds(20),
                   leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        micBuffer.removeAll(keepingCapacity: false)
        sysBuffer.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func feedMic(_ data: Data)    { append(data, toMic: true) }
    func feedSystem(_ data: Data) { append(data, toMic: false) }

    // MARK: - Internals

    private func append(_ data: Data, toMic: Bool) {
        let samples = data.toInt16Array()
        guard !samples.isEmpty else { return }
        lock.lock()
        if toMic {
            micBuffer.append(contentsOf: samples)
            if micBuffer.count > maxBufferedSamples {
                micBuffer.removeFirst(micBuffer.count - maxBufferedSamples)
            }
        } else {
            sysBuffer.append(contentsOf: samples)
            if sysBuffer.count > maxBufferedSamples {
                sysBuffer.removeFirst(sysBuffer.count - maxBufferedSamples)
            }
        }
        lock.unlock()
    }

    private func tick() {
        var mic = [Int16](repeating: 0, count: chunkSamples)
        var sys = [Int16](repeating: 0, count: chunkSamples)

        lock.lock()
        let micTake = min(micBuffer.count, chunkSamples)
        if micTake > 0 {
            for i in 0..<micTake { mic[i] = micBuffer[i] }
            micBuffer.removeFirst(micTake)
        }
        let sysTake = min(sysBuffer.count, chunkSamples)
        if sysTake > 0 {
            for i in 0..<sysTake { sys[i] = sysBuffer[i] }
            sysBuffer.removeFirst(sysTake)
        }
        lock.unlock()

        // If neither side has any data this tick, suppress the emission entirely so we
        // don't flood the API with empty silence frames before audio is actually flowing.
        if micTake == 0 && sysTake == 0 { return }

        var mixed = [Int16](repeating: 0, count: chunkSamples)
        for i in 0..<chunkSamples {
            let summed = Int32(mic[i]) &+ Int32(sys[i])
            mixed[i] = Int16(clamping: summed)
        }
        let data = mixed.withUnsafeBufferPointer { Data(buffer: $0) }
        onMixedPCM16?(data)
    }
}

private extension Data {
    /// Reinterpret raw bytes as Int16 little-endian samples. Trailing odd byte is dropped.
    func toInt16Array() -> [Int16] {
        let sampleCount = count / 2
        guard sampleCount > 0 else { return [] }
        return self.withUnsafeBytes { raw in
            let typed = raw.bindMemory(to: Int16.self)
            return Array(typed.prefix(sampleCount))
        }
    }
}
