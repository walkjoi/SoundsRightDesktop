import Foundation
import os

/// Writes dictation audio to disk — and only ever when explicitly asked to.
///
/// Recordings are *not* saved by default: `DictationController` calls this only
/// for the save-recording shortcut (⌃⇧`). Every other dictation keeps its audio
/// in memory for the length of one transcription and then drops it.
struct DictationRecordingStore: Sendable {

    /// Metadata written next to each WAV, so a saved clip is still identifiable
    /// after the transcript has been pasted and forgotten.
    struct SavedRecording: Codable, Sendable {
        let fileName: String
        let recordedAt: Date
        let duration: TimeInterval
        let transcript: String?
        let language: String?
        let engine: String?
    }

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "DictationRecordingStore")

    /// `~/Library/Application Support/SoundsRight/Dictation`.
    static var directoryURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return base
            .appendingPathComponent("SoundsRight", isDirectory: true)
            .appendingPathComponent("Dictation", isDirectory: true)
    }

    /// Writes the clip plus a JSON sidecar, off the main actor. Returns the WAV
    /// URL so the caller can reveal it in Finder.
    @discardableResult
    func save(audio: DictationAudio, transcript: DictationTranscript?) async -> URL? {
        let directory = Self.directoryURL
        let stamp = Self.timestampFormatter.string(from: Date())
        let audioURL = directory.appendingPathComponent("\(stamp).wav")
        let metadataURL = directory.appendingPathComponent("\(stamp).json")

        let metadata = SavedRecording(
            fileName: audioURL.lastPathComponent,
            recordedAt: Date(),
            duration: audio.duration,
            transcript: transcript?.text,
            language: transcript?.language?.rawValue,
            engine: transcript?.engine.rawValue
        )
        let wavData = audio.wavData()
        let logger = self.logger

        return await Task.detached(priority: .utility) { () -> URL? in
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try wavData.write(to: audioURL, options: .atomic)

                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(metadata).write(to: metadataURL, options: .atomic)

                logger.info("Saved dictation recording: \(audioURL.lastPathComponent, privacy: .public)")
                return audioURL
            } catch {
                logger.error("Failed to save dictation recording: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
    }

    /// Number of saved clips, for the Settings row.
    func savedCount() -> Int {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: Self.directoryURL,
            includingPropertiesForKeys: nil
        )
        return contents?.filter { $0.pathExtension == "wav" }.count ?? 0
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
