import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let converter = AudioConverter()
    private let sampleQueue = DispatchQueue(label: "com.languagetranscriber.systemaudio")

    var onAudio: ((Data) -> Void)?
    var onError: ((String) -> Void)?

    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                onError?("No display available for system audio capture.")
                return
            }

            // We capture audio from the entire display. Video is captured at a tiny size to minimize cost
            // (SCStream requires capturing *something* visual on macOS 13).
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 24000
            config.channelCount = 1
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps video — we ignore it
            config.queueDepth = 5

            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            // We must also add a (dummy) screen output on macOS 13 even if we ignore frames.
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)

            try await s.startCapture()
            self.stream = s
        } catch {
            onError?("Failed to start system audio capture: \(error.localizedDescription). " +
                    "Grant Screen Recording permission in System Settings → Privacy & Security.")
        }
    }

    func stop() async {
        guard let s = stream else { return }
        do {
            try await s.stopCapture()
        } catch {
            // ignore
        }
        stream = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }
        if let data = converter.convert(pcmBuffer) {
            onAudio?(data)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("System audio stream stopped: \(error.localizedDescription)")
    }
}

@available(macOS 13.0, *)
private extension CMSampleBuffer {
    /// Convert an audio CMSampleBuffer into an AVAudioPCMBuffer.
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frameCount > 0 else { return nil }
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        pcmBuffer.frameLength = frameCount

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let src = dataPointer else { return nil }

        // SCStream audio comes back as deinterleaved Float32 by default. Copy each channel.
        if !format.isInterleaved, let dstPtrs = pcmBuffer.floatChannelData {
            let bytesPerChannel = totalLength / Int(format.channelCount)
            for ch in 0..<Int(format.channelCount) {
                memcpy(dstPtrs[ch], src.advanced(by: ch * bytesPerChannel), bytesPerChannel)
            }
        } else if format.isInterleaved {
            switch format.commonFormat {
            case .pcmFormatFloat32:
                if let dst = pcmBuffer.floatChannelData?[0] {
                    memcpy(dst, src, totalLength)
                }
            case .pcmFormatInt16:
                if let dst = pcmBuffer.int16ChannelData?[0] {
                    memcpy(dst, src, totalLength)
                }
            case .pcmFormatInt32:
                if let dst = pcmBuffer.int32ChannelData?[0] {
                    memcpy(dst, src, totalLength)
                }
            default:
                return nil
            }
        } else {
            return nil
        }

        return pcmBuffer
    }
}
