import Foundation

/// Selection membership is independent of the checkbox interaction mode.
public struct PhotoSelectionState: Equatable, Sendable {
    public private(set) var selectedIDs = Set<String>()
    public var focusID: String?
    public private(set) var anchorID: String?
    public init() {}

    public func orderedIDs(in photoIDs: [String]) -> [String] {
        var seen = Set<String>()
        return photoIDs.filter { selectedIDs.contains($0) && seen.insert($0).inserted }
    }
    public mutating func clear() { selectedIDs = []; focusID = nil; anchorID = nil }
    public mutating func selectOnly(_ id: String, isPhoto: Bool = true) {
        selectedIDs = isPhoto ? [id] : []; focusID = id; anchorID = isPhoto ? id : nil
    }
    public mutating func selectAll(_ photoIDs: [String]) {
        selectedIDs.formUnion(photoIDs)
        if !selectedIDs.contains(focusID ?? "") { focusID = photoIDs.first }
        anchorID = focusID
    }
    public mutating func reconcile(visibleIDs: [String], photoIDs: [String], resetAnchor: Bool = false) {
        selectedIDs.subtract(Set(visibleIDs).subtracting(photoIDs))
        if let focusID, !visibleIDs.contains(focusID) { self.focusID = nil }
        if resetAnchor || !photoIDs.contains(anchorID ?? "") { anchorID = nil }
    }

    public mutating func retain(validIDs: Set<String>) {
        selectedIDs.formIntersection(validIDs)
        if let anchorID, !validIDs.contains(anchorID) { self.anchorID = nil }
    }

    /// Returns true only when this event should open the single-photo viewer.
    @discardableResult
    public mutating func click(_ id: String, photoIDs: [String], command: Bool = false,
                               shift: Bool = false, checkboxMode: Bool = false, count: Int = 1) -> Bool {
        guard count == 1 else {
            return count == 2 && !command && !shift && !checkboxMode && photoIDs.contains(id)
        }
        guard let end = photoIDs.firstIndex(of: id) else {
            if !command && !shift && !checkboxMode { selectOnly(id, isPhoto: false) }
            return false
        }
        if shift {
            let anchor = anchorID.flatMap { photoIDs.contains($0) ? $0 : nil }
                ?? focusID.flatMap { photoIDs.contains($0) ? $0 : nil } ?? id
            let start = photoIDs.firstIndex(of: anchor)!
            let range = Set(photoIDs[min(start, end)...max(start, end)])
            selectedIDs = command ? selectedIDs.union(range) : range
            anchorID = anchor
        } else if command || checkboxMode {
            if !selectedIDs.insert(id).inserted { selectedIDs.remove(id) }
            anchorID = id
        } else {
            if !selectedIDs.contains(id) || selectedIDs.count <= 1 { selectedIDs = [id] }
            anchorID = id
        }
        focusID = id
        return false
    }
}
