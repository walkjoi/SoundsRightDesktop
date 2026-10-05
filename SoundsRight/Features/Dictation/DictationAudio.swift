import Accelerate
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
    ///
    /// Vectorized because it runs between the user releasing the hotkey and the
    /// engine starting, over as many as 2.9 million samples.
    var peakAmplitude: Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return peak
    }

    /// Root-mean-square level across the whole clip.
    var rootMeanSquare: Float {
        guard !samples.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return rms
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
    ///
    /// Written into one buffer sized up front: the file has millions of samples,
    /// so appending them to a growing `Data` makes the per-sample overhead the
    /// dominant cost of saving a recording.
    func wavData() -> Data {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let byteRate = UInt32(sampleRate) * UInt32(channelCount) * UInt32(bytesPerSample)
        let blockAlign = channelCount * (bitsPerSample / 8)
        let dataByteCount = UInt32(samples.count * bytesPerSample)

        let headerByteCount = 44
        var bytes = [UInt8](repeating: 0, count: headerByteCount + Int(dataByteCount))

        bytes.withUnsafeMutableBytes { raw in
            var offset = 0
            func writeASCII(_ value: StaticString) {
                for index in 0..<value.utf8CodeUnitCount {
                    raw[offset + index] = value.utf8Start[index]
                }
                offset += value.utf8CodeUnitCount
            }
            func writeInteger<T: FixedWidthInteger>(_ value: T) {
                withUnsafeBytes(of: value.littleEndian) { source in
                    raw.baseAddress?.advanced(by: offset)
                        .copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
                offset += MemoryLayout<T>.size
            }

            writeASCII("RIFF")
            writeInteger(36 + dataByteCount)
            writeASCII("WAVE")
            writeASCII("fmt ")
            writeInteger(UInt32(16))        // PCM subchunk size
            writeInteger(UInt16(1))         // PCM format tag
            writeInteger(channelCount)
            writeInteger(UInt32(sampleRate))
            writeInteger(byteRate)
            writeInteger(blockAlign)
            writeInteger(bitsPerSample)
            writeASCII("data")
            writeInteger(dataByteCount)

            // Converted one sample at a time rather than through vDSP: the
            // asymmetric clamp has no vectorized equivalent.
            let payload = raw.baseAddress!.advanced(by: headerByteCount)
            samples.withUnsafeBufferPointer { source in
                for index in 0..<source.count {
                    let clamped = max(-1, min(1, source[index]))
                    // Int16 reaches -32768 but only +32767, so scaling
                    // positives by 32768 would wrap the loudest peak.
                    let value = Int16(clamped < 0 ? clamped * 32768 : clamped * 32767)
                    payload.advanced(by: index * bytesPerSample)
                        .storeBytes(of: value.littleEndian, as: Int16.self)
                }
            }
        }

        return Data(bytes)
    }
}
