import Foundation

/// One word's timing within synthesized audio, from Edge TTS WordBoundary
/// metadata. Times are seconds from the start of the audio.
struct WordBoundary: Codable, Sendable, Equatable {
    let time: TimeInterval
    let duration: TimeInterval
    let text: String
}

/// Synthesized audio plus its word timings. `wordBoundaries` is empty when the
/// provider sent none; it is persisted alongside the audio in the disk cache
/// so cached replays can still drive read-along highlighting.
struct SynthesizedAudio: Codable, Sendable {
    let data: Data
    let wordBoundaries: [WordBoundary]
}
