import AVFoundation

struct RecorderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func check(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else {
        throw RecorderError(message: "Could not \(action) (OSStatus \(status))")
    }
}

/// 16-bit PCM WAV with a fixed rate and channel count. whisper.cpp and ffmpeg read it directly.
func makeWavFile(at url: URL, sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFile {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
}

/// Writes buffers into one file even when the device format changes mid-call (AirPods switch
/// to call mode and drop from 48 kHz to 16/24 kHz). Gaps while a device restarts are filled
/// with silence, so me.wav and them.wav stay aligned with the wall clock.
final class TrackWriter {
    private let file: AVAudioFile
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var converter: AVAudioConverter?
    private var framesWritten: Int64 = 0

    init(file: AVAudioFile) {
        self.file = file
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let converted = convert(buffer) else { return }
        let rate = file.processingFormat.sampleRate
        let expectedEnd = Int64((ProcessInfo.processInfo.systemUptime - startedAt) * rate)
        let gap = expectedEnd - framesWritten - Int64(converted.frameLength)
        if gap > Int64(rate / 2) {
            writeSilence(frames: gap)
        }
        append(converted)
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = file.processingFormat
        if buffer.format == target { return buffer }
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? output : nil
    }

    private func writeSilence(frames: Int64) {
        var left = frames
        while left > 0 {
            let count = AVAudioFrameCount(min(left, 48_000))
            guard let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { return }
            silence.frameLength = count
            if let channels = silence.floatChannelData {
                for channel in 0..<Int(file.processingFormat.channelCount) {
                    channels[channel].update(repeating: 0, count: Int(count))
                }
            }
            append(silence)
            left -= Int64(count)
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        do {
            try file.write(from: buffer)
            framesWritten += Int64(buffer.frameLength)
        } catch {
            NSLog("Could not write audio: \(error)")
        }
    }
}
