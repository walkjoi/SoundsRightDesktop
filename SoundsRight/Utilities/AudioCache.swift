import Foundation

actor AudioCache {
    private var cacheOrder: [String] = []
    private var cacheStorage: [String: Data] = [:]
    private let maxEntries: Int

    init(maxEntries: Int = AppConstants.audioCacheMaxEntries) {
        self.maxEntries = maxEntries
    }

    func get(_ key: String) -> Data? {
        guard let data = cacheStorage[key] else {
            return nil
        }

        if let index = cacheOrder.firstIndex(of: key) {
            cacheOrder.remove(at: index)
            cacheOrder.append(key)
        }

        return data
    }

    func set(_ key: String, _ data: Data) {
        if cacheStorage[key] != nil {
            if let index = cacheOrder.firstIndex(of: key) {
                cacheOrder.remove(at: index)
            }
        } else if cacheStorage.count >= maxEntries && maxEntries > 0 {
            let oldestKey = cacheOrder.removeFirst()
            cacheStorage.removeValue(forKey: oldestKey)
        }

        cacheStorage[key] = data
        cacheOrder.append(key)
    }

    func clear() {
        cacheOrder.removeAll()
        cacheStorage.removeAll()
    }

    static func cacheKey(text: String, rate: PlaybackRate) -> String {
        return "\(text)|\(rate.rawValue)"
    }
}
