import Foundation

struct BoundedArray<Element> {
    private var storage: [Element] = []
    private var startIndex = 0
    private(set) var limit: Int

    var items: [Element] {
        guard storage.count == limit, startIndex != 0 else { return storage }
        return Array(storage[startIndex...]) + Array(storage[..<startIndex])
    }

    var count: Int { storage.count }

    var last: Element? {
        guard !storage.isEmpty else { return nil }
        guard storage.count == limit else { return storage.last }
        let index = (startIndex + storage.count - 1) % storage.count
        return storage[index]
    }

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    mutating func append(_ item: Element) {
        _ = appendEvicting(item)
    }

    @discardableResult
    mutating func appendEvicting(_ item: Element) -> Element? {
        if storage.count < limit {
            storage.append(item)
            return nil
        }

        let evicted = storage[startIndex]
        storage[startIndex] = item
        startIndex = (startIndex + 1) % limit
        return evicted
    }

    mutating func append(contentsOf newItems: [Element]) {
        for item in newItems {
            append(item)
        }
    }

    mutating func replace(with newItems: [Element]) {
        storage = Array(newItems.suffix(limit))
        startIndex = 0
    }

    func orderedSuffix(_ requestedCount: Int) -> [Element] {
        let resultCount = min(max(0, requestedCount), storage.count)
        guard resultCount > 0 else { return [] }
        guard storage.count == limit, startIndex != 0 else {
            return Array(storage.suffix(resultCount))
        }

        let logicalOffset = storage.count - resultCount
        return (0..<resultCount).map { offset in
            storage[(startIndex + logicalOffset + offset) % storage.count]
        }
    }

    func containsInSuffix(_ requestedCount: Int, where predicate: (Element) -> Bool) -> Bool {
        let inspectedCount = min(max(0, requestedCount), storage.count)
        guard inspectedCount > 0 else { return false }
        let logicalOffset = storage.count - inspectedCount
        for offset in 0..<inspectedCount {
            let index: Int
            if storage.count == limit {
                index = (startIndex + logicalOffset + offset) % storage.count
            } else {
                index = logicalOffset + offset
            }
            if predicate(storage[index]) { return true }
        }
        return false
    }

    mutating func removeAll(where shouldRemove: (Element) -> Bool) {
        storage = items.filter { !shouldRemove($0) }
        startIndex = 0
    }

    mutating func resize(to newLimit: Int) {
        let orderedItems = items
        limit = max(1, newLimit)
        storage = Array(orderedItems.suffix(limit))
        startIndex = 0
    }
}
