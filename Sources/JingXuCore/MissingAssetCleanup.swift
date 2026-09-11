import Foundation
import Darwin

public struct MissingAssetPlan: Identifiable, Sendable {
    public let id = UUID()
    public var files: [MediaAsset] = []
    public var sources: [String: SourceRoot] = [:]
    public var identities: [String: SourceIdentity] = [:]
    public var warnings: [String] = []
    public init() {}
}

public struct MissingAssetReport: Sendable {
    public var removedIDs: Set<String> = []
    public var skipped: [String] = []
    public init() {}
}

/// Never infer absence from fileExists (which also returns false on access errors).
public enum MissingAssetProbe {
    private static func requireReadableDirectory(_ url: URL) throws {
        // Opening the directory verifies read permission without allocating its
        // full listing once per asset (quadratic work for large camera folders).
        guard let directory = opendir(url.path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        closedir(directory)
    }
    public static func identity(for source: SourceRoot) throws -> SourceIdentity {
        guard source.isOnline else { throw CocoaError(.fileReadNoSuchFile) }
        let resolved = try BookmarkStore.resolve(source)
        guard !resolved.isStale else { throw CocoaError(.fileReadNoPermission) }
        let identity = try SourceIdentity.resolve(resolved.url)
        if let volume = source.volumeIdentifier, volume != identity.volume {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "来源磁盘身份已变化，请重新授权并扫描来源"])
        }
        if let json = source.directoryIdentityJSON {
            let saved = try JSONDecoder().decode(SourceIdentity.self, from: Data(json.utf8))
            guard saved.matches(identity) else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "来源目录身份已变化，请重新授权并扫描来源"])
            }
        }
        return identity
    }

    public static func isMissing(_ asset: MediaAsset, source: SourceRoot, expected: SourceIdentity) throws -> Bool {
        let root = try BookmarkStore.resolve(source).url
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        guard try identity(for: source) == expected else { throw CocoaError(.fileReadUnknown) }
        let parts = asset.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        var parent = root
        for (index, part) in parts.enumerated() {
            // Use filesystem lookup, not case-sensitive filename comparison.
            try requireReadableDirectory(parent)
            let child = parent.appendingPathComponent(String(part))
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
                if index == parts.count - 1 { return false }
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    // Do not traverse symlinks or treat a replaced directory as absence.
                    throw CocoaError(.fileReadUnknown)
                }
            } catch {
                let error = error as NSError
                let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
                let absent = (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) ||
                    (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT))
                guard absent else { throw error }
                try requireReadableDirectory(parent)
                guard try identity(for: source) == expected else { throw CocoaError(.fileReadUnknown) }
                return true
            }
            parent = child
        }
        return false
    }
}
