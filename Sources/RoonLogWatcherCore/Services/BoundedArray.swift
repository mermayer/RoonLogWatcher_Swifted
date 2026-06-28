import Foundation

struct BoundedArray<Element> {
    private(set) var items: [Element] = []
    let limit: Int

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    mutating func append(_ item: Element) {
        items.append(item)
        if items.count > limit {
            items.removeFirst(items.count - limit)
        }
    }

    mutating func append(contentsOf newItems: [Element]) {
        for item in newItems {
            append(item)
        }
    }

    mutating func replace(with newItems: [Element]) {
        items = Array(newItems.suffix(limit))
    }

    mutating func removeAll(where shouldRemove: (Element) -> Bool) {
        items.removeAll(where: shouldRemove)
    }
}
