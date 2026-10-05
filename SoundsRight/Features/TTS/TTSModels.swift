import Foundation

/// One word's timing within synthesized audio, from Edge TTS WordBoundary
/// metadata. Times are seconds from the start of the audio.
struct WordBoundary: Sendable, Equatable {
    let time: TimeInterval
    let duration: TimeInterval
    let text: String
}

/// Synthesized audio plus its word timings. `wordBoundaries` is empty when the
/// provider sent none; it is persisted alongside the audio in the disk cache
/// so cached replays can still drive read-along highlighting.
struct SynthesizedAudio: Sendable {
    let data: Data
    let wordBoundaries: [WordBoundary]
}

// MARK: - Disk Encoding

/// Compact binary container for the disk cache.
///
/// Deliberately not `Codable`: the payload is an MP3 blob, and a text-based
/// encoder (JSON included) base64s it — a third more bytes on disk plus a
/// transform over every one of them, on the path whose whole purpose is to
/// return instantly. Here the audio is copied verbatim and only the small
/// timing header is serialized.
///
/// Layout, all integers little-endian:
///
///     "SRA1"              magic + version
///     UInt32              word-boundary count
///     per boundary:       Float64 time, Float64 duration,
///                         UInt32 UTF-8 byte count, UTF-8 bytes
///     UInt32              audio byte count
///     bytes               audio
extension SynthesizedAudio {
    static let diskFormatMagic = Array("SRA1".utf8)

    func encodedForDisk() -> Data {
        var out = Data()
        out.reserveCapacity(data.count + wordBoundaries.count * 24 + 32)

        out.append(contentsOf: Self.diskFormatMagic)
        out.appendLittleEndian(UInt32(wordBoundaries.count))
        for boundary in wordBoundaries {
            out.appendLittleEndian(boundary.time.bitPattern)
            out.appendLittleEndian(boundary.duration.bitPattern)
            let textBytes = Array(boundary.text.utf8)
            out.appendLittleEndian(UInt32(textBytes.count))
            out.append(contentsOf: textBytes)
        }
        out.appendLittleEndian(UInt32(data.count))
        out.append(data)
        return out
    }

    /// Returns nil for anything that isn't a well-formed container — a
    /// truncated or stale cache file is a miss, never a crash.
    static func decodedFromDisk(_ bytes: Data) -> SynthesizedAudio? {
        var reader = ByteReader(bytes)

        guard let magic = reader.readBytes(diskFormatMagic.count),
              Array(magic) == diskFormatMagic,
              let boundaryCount = reader.readUInt32()
        else {
            return nil
        }

        var boundaries: [WordBoundary] = []
        boundaries.reserveCapacity(Int(boundaryCount))
        for _ in 0..<boundaryCount {
            guard let time = reader.readUInt64(),
                  let duration = reader.readUInt64(),
                  let textLength = reader.readUInt32(),
                  let textBytes = reader.readBytes(Int(textLength)),
                  let text = String(data: Data(textBytes), encoding: .utf8)
            else {
                return nil
            }
            boundaries.append(WordBoundary(
                time: Double(bitPattern: time),
                duration: Double(bitPattern: duration),
                text: text
            ))
        }

        guard let audioLength = reader.readUInt32(),
              let audio = reader.readBytes(Int(audioLength))
        else {
            return nil
        }
        return SynthesizedAudio(data: Data(audio), wordBoundaries: boundaries)
    }
}

/// Bounds-checked sequential cursor over a `Data` buffer.
private struct ByteReader {
    private let bytes: Data
    private var offset: Data.Index

    init(_ bytes: Data) {
        self.bytes = bytes
        self.offset = bytes.startIndex
    }

    mutating func readBytes(_ count: Int) -> Data.SubSequence? {
        guard count >= 0, bytes.distance(from: offset, to: bytes.endIndex) >= count else { return nil }
        let end = bytes.index(offset, offsetBy: count)
        defer { offset = end }
        return bytes[offset..<end]
    }

    mutating func readUInt32() -> UInt32? {
        readBytes(4).map { slice in slice.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
    }

    mutating func readUInt64() -> UInt64? {
        readBytes(8).map { slice in slice.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) } }
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        // Qualified: the unqualified name resolves to Data's own instance method.
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
