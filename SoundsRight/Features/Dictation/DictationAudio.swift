import AVFoundation
import Foundation

/// A captured dictation clip, held as mono 16 kHz Float32 — the format Whisper's
/// feature extractor consumes directly, and a clean source for everything else.
///
/// The samples live in memory and nowhere else: writing a file is an explicit,
/// separate step (`wavData`) that only the save-recording shortcut takes.
struct DictationAudio: Sendable {
    let samples: [Float]
    let sampleRate: Double

    var duration: TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / sampleRate
    }

    /// Peak absolute amplitude — used to reject clips that are effectively
    /// silence before they reach Whisper, which otherwise hallucinates a
    /// plausible sentence out of room tone.
    var peakAmplitude: Float {
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        return peak
    }

    /// Root-mean-square level across the whole clip.
    var rootMeanSquare: Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// A buffer the Apple speech engines can consume.
    func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = buffer.floatChannelData?[0]
        else {
            return nil
        }

        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            destination.update(from: base, count: source.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }

    /// 16-bit PCM WAV bytes. Only ever called for the save-recording shortcut.
    func wavData() -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = channelCount * (bitsPerSample / 8)
        let dataByteCount = UInt32(samples.count * Int(bitsPerSample / 8))

        var data = Data(capacity: 44 + Int(dataByteCount))

        func appendASCII(_ value: String) {
            data.append(contentsOf: Array(value.utf8))
        }
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(36 + dataByteCount)
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)            // PCM subchunk size
        appendUInt16(1)             // PCM format tag
        appendUInt16(channelCount)
        appendUInt32(UInt32(sampleRate))
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(bitsPerSample)
        appendASCII("data")
        appendUInt32(dataByteCount)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            // Asymmetric scaling: Int16 reaches -32768 but only +32767, so
            // scaling positives by 32768 would wrap the loudest peak.
            let value = Int16(clamped < 0 ? clamped * 32768 : clamped * 32767)
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        return data
    }
}
