import Foundation

struct ResolveCache {
    private struct Entry { let value: WtsDeepLink; let expiresAt: Date }
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    let capacity: Int

    init(capacity: Int = 100) { self.capacity = capacity }

    mutating func value(for key: String, now: Date) -> WtsDeepLink? {
        guard let entry = entries[key], entry.expiresAt > now else {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.value
    }

    mutating func insert(_ value: WtsDeepLink, for key: String, expiresAt: Date) {
        entries[key] = Entry(value: value, expiresAt: expiresAt)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    mutating func removeAll() { entries.removeAll(); order.removeAll() }
}
