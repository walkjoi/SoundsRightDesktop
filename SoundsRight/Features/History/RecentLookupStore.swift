import Foundation
import os

/// One automatically-remembered lookup. Unlike a `CollectionItem`, a recent
/// lookup is not curated — it exists so "what was that word again?" is one
/// click away instead of a re-selection and a re-synthesis.
struct RecentLookup: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let text: String
    /// Short Chinese rendering (sentence translation or first definition), when one arrived.
    var summary: String?
    let createdAt: Date

    init(id: UUID = UUID(), text: String, summary: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.summary = summary
        self.createdAt = createdAt
    }

    static func normalizedKey(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Ring of the last `AppConstants.recentLookupsMaxEntries` lookups, newest
/// first, persisted as JSON next to the collection so "what was that word
/// yesterday" survives a relaunch. The Collection remains the curated store.
@MainActor
final class RecentLookupStore: ObservableObject {
    // MARK: - Published State

    @Published private(set) var items: [RecentLookup] = []

    // MARK: - Persistence State

    private let fileURL: URL
    private var pendingWrite: Task<Void, Never>?

    // MARK: - Logger

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "RecentLookupStore")

    // MARK: - Lifecycle

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.items = loadFromDisk()
    }

    // MARK: - Core Actions

    /// Records a lookup, or refreshes an existing entry for the same text
    /// (moved to the front; a non-nil summary always wins over nil).
    func record(text: String, summary: String? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let key = RecentLookup.normalizedKey(for: trimmed)

        if let index = items.firstIndex(where: { RecentLookup.normalizedKey(for: $0.text) == key }) {
            var existing = items.remove(at: index)
            if let summary {
                existing.summary = summary
            }
            items.insert(existing, at: 0)
        } else {
            items.insert(RecentLookup(text: trimmed, summary: summary), at: 0)
        }

        if items.count > AppConstants.recentLookupsMaxEntries {
            items.removeLast(items.count - AppConstants.recentLookupsMaxEntries)
        }

        schedulePersist()
        logger.debug("Recorded recent lookup (\(self.items.count) kept)")
    }

    func clear() {
        items.removeAll()
        schedulePersist()
    }

    // MARK: - Persistence

    /// Waits for all queued writes to land on disk. Each detached write awaits its
    /// predecessor, so awaiting the latest one drains the whole chain.
    func flush() async {
        await pendingWrite?.value
    }

    private func loadFromDisk() -> [RecentLookup] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([RecentLookup].self, from: data)
        } catch {
            // Recents are disposable convenience data — no quarantine, just start fresh.
            logger.error("Failed to load recents, starting empty: \(error.localizedDescription)")
            return []
        }
    }

    private func schedulePersist() {
        let snapshot = items
        let url = fileURL
        let logger = self.logger
        let previous = pendingWrite

        pendingWrite = Task.detached(priority: .utility) {
            await previous?.value
            Self.write(items: snapshot, to: url, logger: logger)
        }
    }

    nonisolated private static func write(items: [RecentLookup], to url: URL, logger: Logger) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)

            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            logger.error("Failed to persist recents: \(error.localizedDescription)")
        }
    }

    private static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return base
            .appendingPathComponent("SoundsRight", isDirectory: true)
            .appendingPathComponent("recents.json")
    }
}
