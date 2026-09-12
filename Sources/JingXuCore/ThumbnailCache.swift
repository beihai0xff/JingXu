import Foundation
import CryptoKit

/// Owns all rebuildable thumbnail I/O. No caller traverses the cache on the main actor.
public actor ThumbnailCache {
    public struct Key: Sendable {
        public let assetID: String
        public let kind: String
        public let revision: Int
        public let fingerprint: AnalysisFingerprint
        public let pixelSize: Int
        public init(assetID: String, kind: String, revision: Int = 0, fingerprint: AnalysisFingerprint, pixelSize: Int) {
            self.assetID = assetID; self.kind = kind; self.revision = revision; self.fingerprint = fingerprint; self.pixelSize = pixelSize
        }
        var asset: String { ThumbnailCache.digest(assetID) }
        var version: String { "\(revision)-" + ThumbnailCache.digest("\(fingerprint.identifier ?? "")-\(fingerprint.size)-\(fingerprint.modifiedAt.timeIntervalSince1970)") }
    }
    public struct Ticket: Sendable { fileprivate let epoch: UUID; fileprivate let generation: Int }
    private struct Entry { let asset: String; let bytes: Int; var used: Date }
    private let directory: URL
    private let maximumBytes: Int
    private let trimBytes: Int
    private var prepared = false
    private var epoch = UUID()
    private var generations: [String: Int] = [:]
    private var revisions: [String: Int] = [:]
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0
    private let memory = NSCache<NSString, NSData>()

    public init(directory: URL, maximumBytes: Int = 1_024 * 1_024 * 1_024, trimBytes: Int = 800 * 1_024 * 1_024) {
        self.directory = directory.standardizedFileURL; self.maximumBytes = maximumBytes; self.trimBytes = min(trimBytes, maximumBytes)
        memory.countLimit = 600; memory.totalCostLimit = 256 * 1_024 * 1_024
    }
    public static func pixelSize(_ points: Int, scale: CGFloat = 1) -> Int {
        let pixels = CGFloat(points) * (scale.isFinite && scale > 0 ? scale : 1)
        return [256, 512, 1024, 2048].first { CGFloat($0) >= pixels } ?? 2048
    }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private var root: URL { directory.appendingPathComponent("Managed") }
    private func url(_ key: Key) -> URL { root.appendingPathComponent(key.asset).appendingPathComponent(Self.digest(key.kind)).appendingPathComponent(key.version).appendingPathComponent("\(key.pixelSize).thumbnail") }
    private func prepare() throws {
        guard !prepared else { return }
        try ensureDirectory(root)
        var loaded: [String: Entry] = [:]
        var loadedBytes = 0
        // Old flat files are disposable cache, not catalog data. Never follow links.
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map(\.standardizedFileURL) where url.path != root.path {
            try FileManager.default.removeItem(at: url)
        }
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let enumerated as URL in walker {
                let file = enumerated.standardizedFileURL
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
                guard attributes.isSymbolicLink != true else { walker.skipDescendants(); continue }
                guard attributes.isRegularFile == true else { continue }
                let components = Array(file.pathComponents.dropFirst(root.pathComponents.count))
                guard components.count == 4 else { continue }
                let asset = components[0]
                let family = asset + "/" + components[1]
                let revision = Int(components[2].split(separator: "-").first ?? "") ?? 0
                revisions[family] = max(revision, revisions[family, default: 0])
                let bytes = attributes.fileSize ?? 0
                loaded[file.path] = Entry(asset: asset, bytes: bytes, used: attributes.contentModificationDate ?? .distantPast); loadedBytes += bytes
            }
        }
        entries = loaded; totalBytes = loadedBytes; prepared = true; try trim()
    }
    private func ensureDirectory(_ path: URL) throws {
        let parent = path.deletingLastPathComponent()
        if path.path != directory.path && path.pathComponents.starts(with: directory.pathComponents) { try ensureDirectory(parent) }
        if FileManager.default.fileExists(atPath: path.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteInvalidFileName) }
            return
        }
        if parent.path != path.path && !path.pathComponents.starts(with: directory.pathComponents) { try ensureDirectory(parent) }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
    }
    public func lookup(_ key: Key) -> (Ticket, Data?) {
        let ticket = Ticket(epoch: epoch, generation: generations[key.assetID, default: 0])
        do {
            try prepare()
            let path = url(key), memoryKey = path.path as NSString
            let data: Data?
            if let cached = memory.object(forKey: memoryKey) { data = cached as Data }
            else { data = try? Data(contentsOf: path) }
            if let data {
                memory.setObject(data as NSData, forKey: memoryKey, cost: data.count)
                let now = Date()
                if let previous = entries[path.path]?.used, now.timeIntervalSince(previous) >= 60 {
                    try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path.path)
                }
                entries[path.path]?.used = now
            }
            return (ticket, data)
        } catch { return (ticket, nil) }
    }
    public func store(_ data: Data, for key: Key, ticket: Ticket) {
        guard !Task.isCancelled, ticket.epoch == epoch, ticket.generation == generations[key.assetID, default: 0] else { return }
        let family = key.asset + "/" + Self.digest(key.kind)
        do {
            try prepare()
            guard key.revision >= revisions[family, default: 0] else { return }
            let path = url(key), parent = path.deletingLastPathComponent()
            try ensureDirectory(parent)
            try data.write(to: path, options: .atomic)
            totalBytes -= entries[path.path]?.bytes ?? 0
            entries[path.path] = Entry(asset: key.asset, bytes: data.count, used: Date()); totalBytes += data.count
            memory.setObject(data as NSData, forKey: path.path as NSString, cost: data.count)
            revisions[family] = key.revision
            let kindDirectory = parent.deletingLastPathComponent()
            for old in try FileManager.default.contentsOfDirectory(at: kindDirectory, includingPropertiesForKeys: nil).map(\.standardizedFileURL) where old.path != parent.path {
                // A late request must never evict a newer committed color revision.
                let revision = Int(old.lastPathComponent.split(separator: "-").first ?? "") ?? 0
                if revision > key.revision { continue }
                try FileManager.default.removeItem(at: old)
                for file in Array(entries.keys) where (file as NSString).deletingLastPathComponent == old.path { removeEntry(file) }
            }
            try trim()
        } catch { /* A rendered thumbnail remains usable when its cache cannot be written. */ }
    }
    private func removeEntry(_ url: String) {
        totalBytes -= entries.removeValue(forKey: url)?.bytes ?? 0
        memory.removeObject(forKey: url as NSString)
    }
    private func trim() throws {
        guard totalBytes > maximumBytes else { return }
        for (url, _) in entries.sorted(by: { $0.value.used < $1.value.used }) {
            try FileManager.default.removeItem(atPath: url); removeEntry(url)
            if totalBytes <= trimBytes { break }
        }
    }
    public func invalidate(assetIDs: Set<String>) throws {
        for id in assetIDs { generations[id, default: 0] += 1 }
        memory.removeAllObjects()
        try prepare()
        let hashes = Set(assetIDs.map(Self.digest))
        for hash in hashes {
            let path = root.appendingPathComponent(hash)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
        for (url, entry) in entries where hashes.contains(entry.asset) { removeEntry(url) }
        revisions = revisions.filter { key, _ in !hashes.contains(String(key.split(separator: "/", maxSplits: 1)[0])) }
    }
    public func clear() throws {
        epoch = UUID(); generations.removeAll(); revisions.removeAll(); memory.removeAllObjects()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        entries.removeAll(); totalBytes = 0; prepared = false
    }
    public var diskBytes: Int { totalBytes }
}
