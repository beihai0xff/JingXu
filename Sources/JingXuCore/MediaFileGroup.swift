import Foundation

/// The same association rules serve import and file organization. No date or catalog policy here.
public enum MediaFileGroup {
    public static func members(photos: [URL], entries: [URL]) throws -> [URL] {
        guard let first = photos.first else { return [] }
        let stem = first.deletingPathExtension().lastPathComponent
        let sameStem = entries.filter { $0.deletingPathExtension().lastPathComponent == stem && MediaSupport.kind(for: $0) != nil }
        guard Set(sameStem.map(\.lastPathComponent)) == Set(photos.map(\.lastPathComponent)), photos.count <= 2,
              photos.count == 1 || (photos.filter { MediaSupport.isRaw($0) }.count == 1 &&
                photos.filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }.count == 1) else {
            throw ColorEditError("同名媒体关系不明确，跳过整组")
        }
        let sidecars = entries.filter { url in
            url.pathExtension.lowercased() == "xmp" &&
                (url.deletingPathExtension().lastPathComponent == stem ||
                 photos.contains { $0.lastPathComponent == url.deletingPathExtension().lastPathComponent })
        }
        return (photos + sidecars).sorted { $0.path < $1.path }
    }
}
