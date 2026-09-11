import Foundation

public struct SourceIdentity: Codable, Sendable, Equatable {
    public let path: String
    public let volume: String?
    public let file: String?
    public static func resolve(_ url: URL) throws -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard try resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        return Self(path: resolved.path, volume: FileIdentity.volumeIdentifier(for: resolved), file: FileIdentity.resourceIdentifier(for: resolved))
    }
    public func matches(_ other: Self) -> Bool {
        if let volume, let file, let otherVolume = other.volume, let otherFile = other.file {
            return volume == otherVolume && file == otherFile
        }
        return path == other.path
    }
}

public struct SourceMergePlan: Identifiable, Sendable {
    public let id = UUID()
    public var groups: [[SourceRoot]]
    public var conflicts: Int
    public var warnings: [String]
}
public struct SourceMergeReport: Sendable {
    public var mergedGroups = 0
    public var skipped: [String] = []
    public var invalidatedIDs: Set<String> = []
}

extension CatalogStore {
    public func registerSource(at url: URL) throws -> SourceRoot {
        let identity = try SourceIdentity.resolve(url)
        let canonicalURL = URL(fileURLWithPath: identity.path, isDirectory: true)
        let existing = try sources().sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        for var source in existing {
            let savedIdentity = source.directoryIdentityJSON.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(SourceIdentity.self, from: $0) }
            let resolved = (try? BookmarkStore.resolve(source).url) ?? URL(fileURLWithPath: source.pathHint)
            let other = (try? SourceIdentity.resolve(resolved)) ?? savedIdentity
            guard let other, identity.matches(other) else { continue }
            source.bookmarkData = try BookmarkStore.makeBookmark(for: canonicalURL)
            source.pathHint = identity.path; source.isOnline = true
            source.volumeIdentifier = identity.volume
            source.directoryIdentityJSON = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
            try upsertSource(source)
            return source
        }
        // An offline source at the same path requires revalidation instead of creating a duplicate.
        if existing.contains(where: { URL(fileURLWithPath: $0.pathHint).standardizedFileURL.path == url.standardizedFileURL.path }) {
            throw NSError(domain: "JingXu", code: 2, userInfo: [NSLocalizedDescriptionKey: "已有同路径来源无法验证，请先重新连接来源或移除失效记录。"])
        }
        var source = SourceRoot(name: canonicalURL.lastPathComponent, bookmarkData: try BookmarkStore.makeBookmark(for: canonicalURL), pathHint: identity.path, volumeIdentifier: identity.volume)
        source.directoryIdentityJSON = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
        try upsertSource(source)
        return source
    }
}
