import Foundation
import Darwin

public enum PhotoShareMode: String, CaseIterable, Sendable {
    case original, jpeg
    public var title: String { self == .original ? "分享原片" : "分享调色成片" }
}

public struct PhotoSharePlan: Sendable, Identifiable {
    public let id = UUID()
    public let mode: PhotoShareMode
    public let maximumDimension: Int?
    public let items: [ColorEditSnapshot]
    public let issues: [String]
}

public struct PhotoShareFile: Sendable {
    public let assetID: String
    public let url: URL
}

public struct PreparedPhotoShare: Sendable, Identifiable {
    public let id: UUID
    public let mode: PhotoShareMode
    public let files: [PhotoShareFile]
    public let issues: [String]
    public let cacheDirectory: URL?
    // Retain one balanced source access per original until the session ends.
    let accesses: [ColorSourceAccess]

    public func retainCacheForSystem(now: Date = Date()) throws {
        if let cacheDirectory { try PhotoShareCacheExpiry(expiresAt: now.addingTimeInterval(86_400)).write(in: cacheDirectory) }
    }
}

private struct PhotoShareCacheExpiry: Codable {
    let expiresAt: Date
    func write(in directory: URL) throws {
        try JSONEncoder().encode(self).write(to: directory.appendingPathComponent("expiry.json"), options: .atomic)
    }
}

/// Does not publish anything externally. Only a user action in the system picker does so.
public actor PhotoShareCoordinator {
    public typealias Encoder = @Sendable (ColorEditSnapshot, Int?, URL) async throws -> Void
    private let store: CatalogStore
    private let cacheRoot: URL
    private let encode: Encoder
    private var active = Set<UUID>()
    private var preparing = false

    public init(store: CatalogStore, cacheRoot: URL, encode: Encoder? = nil) {
        self.store = store; self.cacheRoot = cacheRoot
        self.encode = encode ?? { snapshot, limit, url in
            do {
                try await ColorImageRenderer.shared.encode(snapshot, adjustments: snapshot.adjustments, format: .jpeg,
                                                           to: url, maximumDimension: limit)
            } catch { await ColorImageRenderer.shared.release(); throw error }
            await ColorImageRenderer.shared.release()
        }
    }

    public func plan(assetIDs: [String], mode: PhotoShareMode, maximumDimension: Int? = nil) async throws -> PhotoSharePlan {
        guard maximumDimension == nil || maximumDimension == 2048 else { throw ColorEditError("不支持的分享尺寸") }
        var seen = Set<String>(), items: [ColorEditSnapshot] = [], issues: [String] = []
        for id in assetIDs where seen.insert(id).inserted {
            try Task.checkCancellation()
            do { items.append(try await store.colorSnapshot(assetID: id)) }
            catch { issues.append("\(id)：照片已不在图库或不是照片") }
        }
        return PhotoSharePlan(mode: mode, maximumDimension: mode == .jpeg ? maximumDimension : nil, items: items, issues: issues)
    }

    public func prepare(_ plan: PhotoSharePlan, progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> PreparedPhotoShare {
        guard !preparing, !active.contains(plan.id) else { throw ColorEditError("分享准备正在进行或清单已使用") }
        preparing = true; active.insert(plan.id)
        var createdDirectory = false
        let directory = plan.mode == .jpeg ? cacheRoot.appendingPathComponent("share-\(plan.id.uuidString)") : nil
        defer { preparing = false }
        do {
            try cleanupExpired()
            if let directory {
                try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
                guard !FileManager.default.fileExists(atPath: directory.path) else { throw ColorEditError("分享缓存目录已存在，请重新准备") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                createdDirectory = true
                try PhotoShareCacheExpiry(expiresAt: Date().addingTimeInterval(86_400)).write(in: directory)
            }
            var files: [PhotoShareFile] = [], issues = plan.issues, accesses: [ColorSourceAccess] = []
            var paths = Set<Data>()
            for (index, snapshot) in plan.items.enumerated() {
                try Task.checkCancellation()
                await progress(index, plan.items.count)
                do {
                    try await store.validatePhotoShareSnapshot(snapshot, includeAdjustments: plan.mode == .jpeg)
                    let access = try ColorSourceAccess(snapshot, checkAdjustment: plan.mode == .jpeg)
                    guard paths.insert(Data(access.url.standardizedFileURL.path.utf8)).inserted else {
                        issues.append("\(snapshot.asset.fileName)：重复文件路径，仅分享一次")
                        continue
                    }
                    if let directory {
                        let temporary = directory.appendingPathComponent(".partial-\(UUID().uuidString)")
                        defer { try? FileManager.default.removeItem(at: temporary) }
                        try await encode(snapshot, plan.maximumDimension, temporary)
                        try Task.checkCancellation()
                        try await store.validatePhotoShareSnapshot(snapshot, includeAdjustments: true)
                        try access.revalidate()
                        let stem = access.url.deletingPathExtension().lastPathComponent + "-调色"
                        var sequence = 1
                        while true {
                            let suffix = sequence == 1 ? "" : "-\(sequence)"
                            let target = directory.appendingPathComponent(stem + suffix + ".jpg")
                            if renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                                files.append(PhotoShareFile(assetID: snapshot.asset.id, url: target)); break
                            }
                            let code = errno
                            guard code == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
                            sequence += 1
                        }
                    } else {
                        try access.revalidate()
                        files.append(PhotoShareFile(assetID: snapshot.asset.id, url: access.url))
                        accesses.append(access)
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append("\(snapshot.asset.fileName)：\(error.localizedDescription)") }
                await progress(index + 1, plan.items.count)
            }
            try Task.checkCancellation()
            if plan.mode == .original {
                // Preparing later items can take time. Recheck all retained originals
                // before publishing the fixed list, rather than trusting the first read.
                var verifiedFiles: [PhotoShareFile] = [], verifiedAccesses: [ColorSourceAccess] = []
                let snapshots = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.asset.id, $0) })
                for (file, access) in zip(files, accesses) {
                    try Task.checkCancellation()
                    do {
                        guard let snapshot = snapshots[file.assetID] else { continue }
                        try await store.validatePhotoShareSnapshot(snapshot, includeAdjustments: false)
                        try access.revalidate()
                        verifiedFiles.append(file); verifiedAccesses.append(access)
                    } catch { issues.append("\(file.url.lastPathComponent)：\(error.localizedDescription)") }
                }
                files = verifiedFiles; accesses = verifiedAccesses
            }
            try Task.checkCancellation()
            return PreparedPhotoShare(id: plan.id, mode: plan.mode, files: files, issues: issues,
                                      cacheDirectory: directory, accesses: accesses)
        } catch {
            active.remove(plan.id)
            if createdDirectory, let directory {
                do { try removeOwnedDirectory(directory) }
                catch let cleanupError {
                    throw ColorEditError("分享准备未完成（\(error.localizedDescription)）；缓存清理失败：\(cleanupError.localizedDescription)。缓存保留在 \(directory.path)")
                }
            }
            throw error
        }
    }

    public func finish(id: UUID, cacheDirectory: URL?, handedToSystem: Bool) throws {
        guard active.contains(id) else { return }
        if let cacheDirectory {
            guard ownedID(cacheDirectory) == id else { throw ColorEditError("分享缓存与会话不匹配，未清理") }
            if handedToSystem {
                // A service can run longer than a day. Retain another full day
                // after completion / manual release, not just after preparation.
                try PhotoShareCacheExpiry(expiresAt: Date().addingTimeInterval(86_400)).write(in: cacheDirectory)
            } else { try removeOwnedDirectory(cacheDirectory) }
        }
        active.remove(id)
    }

    public func cleanupExpired(now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: cacheRoot.path) else { return }
        for directory in try FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard let id = ownedID(directory), !active.contains(id) else { continue }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            if let expiry = try? JSONDecoder().decode(PhotoShareCacheExpiry.self, from: Data(contentsOf: directory.appendingPathComponent("expiry.json"))) {
                if now >= expiry.expiresAt { try removeOwnedDirectory(directory) }
            } else {
                // Crashed before writing the manifest: retain a full day as well.
                let date = try directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let date, now.timeIntervalSince(date) >= 86_400 { try removeOwnedDirectory(directory) }
            }
        }
    }
    private func ownedID(_ directory: URL) -> UUID? {
        guard directory.deletingLastPathComponent().standardizedFileURL == cacheRoot.standardizedFileURL,
              directory.lastPathComponent.hasPrefix("share-") else { return nil }
        return UUID(uuidString: String(directory.lastPathComponent.dropFirst(6)))
    }
    private func removeOwnedDirectory(_ directory: URL) throws {
        guard ownedID(directory) != nil else { throw ColorEditError("拒绝清理分享缓存之外的目录") }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}

extension CatalogStore {
    public func validatePhotoShareSnapshot(_ snapshot: ColorEditSnapshot, includeAdjustments: Bool) throws {
        if includeAdjustments { try validateColorSnapshot(snapshot) }
        else {
            guard try asset(id: snapshot.asset.id) == snapshot.asset,
                  try source(id: snapshot.source.id) == snapshot.source else { throw ColorEditError("照片或来源已变化，请重新准备分享") }
            let access = try ColorSourceAccess(snapshot, checkAdjustment: false)
            // A readable directory / stat result alone does not grant file read
            // permission. Opening a handle checks permission without decoding.
            try FileHandle(forReadingFrom: access.url).close()
        }
    }
}
