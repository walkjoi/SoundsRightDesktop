import CryptoKit
import Foundation
import os

/// Two-tier LRU cache for synthesized audio: a small in-memory layer for the
/// hot path, backed by JSON files in Application Support so saved words and
/// recent lookups replay instantly — and offline — across launches. Disk
/// recency is tracked via file modification dates; eviction is size-based.
actor AudioCache {
    private var cacheOrder: [String] = []
    private var cacheStorage: [String: SynthesizedAudio] = [:]
    private let maxEntries: Int
    private let diskDirectory: URL?
    private let diskMaxBytes: Int
    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "AudioCache")

    init(
        maxEntries: Int = AppConstants.audioCacheMaxEntries,
        diskDirectory: URL? = AudioCache.defaultDiskDirectory(),
        diskMaxBytes: Int = AppConstants.audioCacheDiskMaxBytes
    ) {
        self.maxEntries = maxEntries
        self.diskDirectory = diskDirectory
        self.diskMaxBytes = diskMaxBytes
    }

    func get(_ key: String) -> SynthesizedAudio? {
        if let audio = cacheStorage[key] {
            if let index = cacheOrder.firstIndex(of: key) {
                cacheOrder.remove(at: index)
                cacheOrder.append(key)
            }
            return audio
        }

        // Miss in memory — try disk, and promote a hit back into memory.
        guard let url = diskURL(for: key),
              let data = try? Data(contentsOf: url),
              let audio = try? JSONDecoder().decode(SynthesizedAudio.self, from: data)
        else {
            return nil
        }

        // Touch the file so size-based eviction removes least-recently-used first.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        storeInMemory(key, audio)
        logger.debug("Disk cache hit")
        return audio
    }

    func set(_ key: String, _ audio: SynthesizedAudio) {
        storeInMemory(key, audio)
        writeToDisk(key: key, audio: audio)
    }

    func clear() {
        cacheOrder.removeAll()
        cacheStorage.removeAll()
        if let directory = diskDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func cacheKey(text: String, voice: TTSVoice, rate: PlaybackRate) -> String {
        return "\(text)|\(voice.rawValue)|\(rate.rawValue)"
    }

    // MARK: - Memory Tier

    private func storeInMemory(_ key: String, _ audio: SynthesizedAudio) {
        if cacheStorage[key] != nil {
            if let index = cacheOrder.firstIndex(of: key) {
                cacheOrder.remove(at: index)
            }
        } else if cacheStorage.count >= maxEntries && maxEntries > 0 {
            let oldestKey = cacheOrder.removeFirst()
            cacheStorage.removeValue(forKey: oldestKey)
        }

        cacheStorage[key] = audio
        cacheOrder.append(key)
    }

    // MARK: - Disk Tier

    private func writeToDisk(key: String, audio: SynthesizedAudio) {
        guard let directory = diskDirectory, let url = diskURL(for: key) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(audio)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("Failed to write audio cache entry: \(error.localizedDescription)")
            return
        }
        enforceDiskLimit()
    }

    private func enforceDiskLimit() {
        guard let directory = diskDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
              )
        else {
            return
        }

        var entries: [(url: URL, modified: Date, size: Int)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate,
                  let size = values.fileSize
            else {
                return nil
            }
            return (url, modified, size)
        }

        var totalBytes = entries.reduce(0) { $0 + $1.size }
        guard totalBytes > diskMaxBytes else { return }

        entries.sort { $0.modified < $1.modified }
        for entry in entries {
            guard totalBytes > diskMaxBytes else { break }
            try? FileManager.default.removeItem(at: entry.url)
            totalBytes -= entry.size
        }
        logger.info("Audio disk cache trimmed to \(totalBytes) bytes")
    }

    private func diskURL(for key: String) -> URL? {
        guard let directory = diskDirectory else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }

    static func defaultDiskDirectory() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        return base
            .appendingPathComponent("SoundsRight", isDirectory: true)
            .appendingPathComponent("AudioCache", isDirectory: true)
    }
}
