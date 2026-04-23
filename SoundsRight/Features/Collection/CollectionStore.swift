import Foundation
import os

@MainActor
final class CollectionStore: ObservableObject {
    @Published private(set) var items: [CollectionItem] = []

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.soundsright.desktop", category: "CollectionStore")
    private var pendingWrite: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.items = loadFromDisk()
    }

    // MARK: - Queries

    func contains(sourceText: String) -> Bool {
        let key = CollectionItem.normalizedKey(for: sourceText)
        return items.contains { $0.normalizedKey == key }
    }

    // MARK: - Mutations

    @discardableResult
    func add(_ item: CollectionItem) -> Bool {
        if contains(sourceText: item.sourceText) { return false }
        items.insert(item, at: 0)
        schedulePersist()
        return true
    }

    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        schedulePersist()
    }

    func removeAll(ids: Set<UUID>) {
        let before = items.count
        items.removeAll { ids.contains($0.id) }
        if items.count != before {
            schedulePersist()
        }
    }

    // MARK: - Persistence

    private func loadFromDisk() -> [CollectionItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let items = try decoder.decode([CollectionItem].self, from: data)
            return items
        } catch {
            logger.error("Failed to load collection: \(error.localizedDescription) — quarantining file")
            quarantineCorruptFile()
            return []
        }
    }

    private func quarantineCorruptFile() {
        let timestamp = Int(Date().timeIntervalSince1970)
        let corrupt = fileURL
            .deletingPathExtension()
            .appendingPathExtension("corrupt-\(timestamp).json")
        try? FileManager.default.moveItem(at: fileURL, to: corrupt)
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

    nonisolated private static func write(items: [CollectionItem], to url: URL, logger: Logger) {
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
            logger.error("Failed to persist collection: \(error.localizedDescription)")
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
            .appendingPathComponent("collection.json")
    }
}
