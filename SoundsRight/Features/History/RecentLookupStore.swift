import Foundation
import os

/// One automatically-remembered lookup. Unlike a `CollectionItem`, a recent
/// lookup is not curated — it exists so "what was that word again?" is one
/// click away instead of a re-selection and a re-synthesis.
struct RecentLookup: Identifiable, Equatable, Sendable {
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

/// In-memory ring of the last `AppConstants.recentLookupsMaxEntries` lookups,
/// newest first. Deliberately not persisted: history is a convenience for the
/// current session; the Collection is the durable store.
@MainActor
final class RecentLookupStore: ObservableObject {
    // MARK: - Published State

    @Published private(set) var items: [RecentLookup] = []

    // MARK: - Logger

    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "RecentLookupStore")

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

        logger.debug("Recorded recent lookup (\(self.items.count) kept)")
    }

    func clear() {
        items.removeAll()
    }
}
