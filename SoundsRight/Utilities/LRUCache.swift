import Foundation

/// Minimal in-memory LRU used for completed lookup results. Not synchronized —
/// owners confine it to their actor or main-actor context.
struct LRUCache<Key: Hashable, Value> {
    private var values: [Key: Value] = [:]
    /// Access order, most recently used last. O(n) maintenance is fine at the
    /// small capacities this is used with.
    private var order: [Key] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        markUsed(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        values[key] = value
        markUsed(key)
        while values.count > capacity, let oldest = order.first {
            order.removeFirst()
            values[oldest] = nil
        }
    }

    private mutating func markUsed(_ key: Key) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
        }
        order.append(key)
    }
}
