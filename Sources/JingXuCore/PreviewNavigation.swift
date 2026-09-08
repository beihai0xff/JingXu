import Foundation

/// Keeps an entry-time order, even when the displayed photo is filtered out.
public struct PreviewNavigation: Sendable {
    private let order: [String]
    private var eligible: Set<String>

    public init(photoIDs: [String]) {
        var seen = Set<String>()
        order = photoIDs.filter { seen.insert($0).inserted }
        eligible = seen
    }

    public mutating func refresh(photoIDs: [String]) {
        eligible = Set(photoIDs)
    }

    /// The current filtered-out photo remains an anchor until the user leaves it.
    public func filmstripIDs(currentID: String) -> [String] {
        order.filter { eligible.contains($0) || $0 == currentID }
    }

    public func neighbor(of id: String, direction: Int) -> String? {
        guard direction == -1 || direction == 1,
              let position = order.firstIndex(of: id) else { return nil }
        var index = position + direction
        while order.indices.contains(index) {
            if eligible.contains(order[index]) { return order[index] }
            index += direction
        }
        return nil
    }
}
