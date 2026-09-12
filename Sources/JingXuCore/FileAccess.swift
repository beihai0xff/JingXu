import CryptoKit
import Foundation
import UniformTypeIdentifiers

public enum JingXuPaths {
    public static func applicationSupport() throws -> URL {
        // Explicit UI-test isolation applies to the whole catalog, backups, journals and caches.
        if let path = ProcessInfo.processInfo.environment["JINGXU_UI_TEST_ROOT"] {
            guard path.hasPrefix("/"), path != "/" else { throw CocoaError(.fileReadInvalidFileName) }
            let isolated = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
            return isolated
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("JingXu", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    public static func databaseURL() throws -> URL {
        try applicationSupport().appendingPathComponent("Catalog.sqlite")
    }

    public static func thumbnailCache() throws -> URL {
        let directory = try applicationSupport().appendingPathComponent("Thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

public enum BookmarkStore {
    public static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public static func resolve(_ source: SourceRoot) throws -> (url: URL, isStale: Bool) {
        guard let data = source.bookmarkData else {
            return (URL(fileURLWithPath: source.pathHint, isDirectory: true), false)
        }
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }
}

public enum MediaSupport {
    public static let rawExtensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "dng", "erf", "iiq", "kdc", "mef", "mos",
        "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "srw", "x3f"
    ]
    public static let standardPhotoExtensions: Set<String> = [
        "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff"
    ]
    public static let videoExtensions: Set<String> = [
        "avi", "m4v", "mov", "mp4", "mts", "mxf"
    ]

    public static var supportedExtensions: Set<String> {
        rawExtensions.union(standardPhotoExtensions).union(videoExtensions)
    }

    public static func kind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if rawExtensions.contains(ext) || standardPhotoExtensions.contains(ext) { return .photo }
        if videoExtensions.contains(ext) { return .video }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .image) { return .photo }
            if type.conforms(to: .movie) { return .video }
        }
        return nil
    }

    public static func isRaw(_ url: URL) -> Bool {
        rawExtensions.contains(url.pathExtension.lowercased())
    }
}

public enum FileIdentity {
    public static func relativePath(of url: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents) else { return url.lastPathComponent }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    public static func resourceIdentifier(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
        return values?.fileResourceIdentifier.map { String(describing: $0) }
    }

    public static func volumeIdentifier(for url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey])
        return values?.volumeIdentifier.map { String(describing: $0) }
    }
}

public enum FileHasher {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ImportNaming {
    public static func destinationFolder(date: Date, batchName: String, calendar: Calendar = .current) -> String {
        let year = calendar.component(.year, from: date)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let datePart = formatter.string(from: date)
        let sanitized = sanitizePathComponent(batchName)
        let leaf = sanitized.isEmpty ? datePart : "\(datePart)-\(sanitized)"
        return "\(year)/\(leaf)"
    }

    public static func sanitizePathComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let pieces = value.components(separatedBy: invalid)
        return pieces.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
    }
}

public enum AssetLocation {
    public static func url(for asset: MediaAsset, source: SourceRoot) throws -> URL {
        let root = try BookmarkStore.resolve(source).url
        return root.appendingPathComponent(asset.relativePath)
    }
}
