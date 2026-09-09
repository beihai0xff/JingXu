import Darwin
import Foundation
import ImageIO

public struct ArchiveFile: Codable, Sendable {
    public var asset: MediaAsset?
    public var from: String
    public var to: String
    public var fingerprint: AnalysisFingerprint
    public var hash: String
}

public struct ArchiveGroup: Codable, Sendable {
    public var source: SourceRoot
    public var identity: SourceIdentity
    public var files: [ArchiveFile]
    public var destination: SourceRoot? = nil
    public var destinationIdentity: SourceIdentity? = nil
    public var destinationDirectoryIdentity: SourceIdentity? = nil
    public var state = "pending"
}

public struct ArchivePlan: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var groups: [ArchiveGroup] = []
    public var warnings: [String] = []
    public var isBatchMove: Bool? = nil
    public var bytes: Int64 { groups.flatMap(\.files).reduce(0) { $0 + $1.fingerprint.size } }
    public var count: Int { groups.flatMap(\.files).count }
}

public struct ArchiveReport: Sendable {
    public var completed = 0
    public var warnings: [String] = []
    public var summary: String { "已完成 \(completed) 个文件。\n" + warnings.joined(separator: "\n") }
}

public protocol ArchiveMover: Sendable {
    func move(_ from: URL, _ to: URL) throws
}

public struct SameVolumeArchiveMover: ArchiveMover {
    public init() {}
    public func move(_ from: URL, _ to: URL) throws {
        // renamex_np is a single-filesystem operation. RENAME_EXCL forbids replacement,
        // including races after the plan was confirmed. EXDEV never falls back to copy.
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        for directory in Set([from.deletingLastPathComponent().path, to.deletingLastPathComponent().path]) {
            let fd = open(directory, O_RDONLY)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        }
    }
}

public enum ArchiveDate {
    /// EXIF wall-clock date is intentional: applying the machine time zone can change the day.
    public static func folder(exif: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.isLenient = false
        guard let date = formatter.date(from: exif), formatter.string(from: date) == exif else { return nil }
        return String(exif.prefix(4)) + "/" + exif.prefix(10).replacingOccurrences(of: ":", with: "-")
    }
    public static func read(_ url: URL) -> String? {
        guard let image = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let value = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        return folder(exif: value)
    }
}

public actor ArchiveCoordinator {
    private let store: CatalogStore
    private let journalURL: URL
    private let mover: any ArchiveMover
    private let dateReader: @Sendable (URL) -> String?
    private var busy = false
    public init(store: CatalogStore, journalURL: URL, mover: any ArchiveMover = SameVolumeArchiveMover(),
                dateReader: @escaping @Sendable (URL) -> String? = ArchiveDate.read) {
        self.store = store; self.journalURL = journalURL; self.mover = mover; self.dateReader = dateReader
    }

    public func hasPending() throws -> Bool {
        try load()?.groups.contains { !["done", "undone", "skipped"].contains($0.state) } ?? false
    }

    /// Startup reconciliation performs no file moves. Ambiguous/partial groups remain blocked
    /// until the user explicitly continues or reverses the operation.
    public func reconcile() async throws {
        guard !busy else { throw CocoaError(.fileLocking) }
        busy = true
        defer { busy = false }
        guard var plan = try load() else { return }
        for index in plan.groups.indices where plan.groups[index].state == "moving" || plan.groups[index].state == "undoing" {
            let group = plan.groups[index]
            let reversed = group.state == "undoing"
            do {
                let root = try root(group)
                let access = root.startAccessingSecurityScopedResource()
                defer { if access { root.stopAccessingSecurityScopedResource() } }
                try validateRoot(root, group.identity)
                let targetRoot = try destinationRoot(group, fallback: root)
                let targetAccess = targetRoot.startAccessingSecurityScopedResource()
                defer { if targetAccess { targetRoot.stopAccessingSecurityScopedResource() } }
                if let identity = group.destinationIdentity { try validateRoot(targetRoot, identity) }
                try validateDestinationDirectory(group, root: targetRoot)
                for file in group.files {
                    let old = try url(reversed ? file.to : file.from, root: reversed ? targetRoot : root)
                    let target = try url(reversed ? file.from : file.to, root: reversed ? root : targetRoot)
                    if old != target {
                        guard (try? FileManager.default.attributesOfItem(atPath: old.path)) == nil else { throw CocoaError(.fileLocking) }
                    }
                    try verify(file, at: target)
                }
                try await store.commitArchive(group.files, reversed: reversed, destination: group.destination)
                plan.groups[index].state = reversed ? "undone" : "done"
                try save(plan)
            } catch { continue }
        }
    }

    public func recoverySources() throws -> [SourceRoot] {
        guard let plan = try load() else { return [] }
        return Dictionary(grouping: plan.groups.flatMap { [$0.source] + ($0.destination.map { [$0] } ?? []) }, by: \.id).values.compactMap(\.first).sorted { $0.id < $1.id }
    }

    public func authorize(_ url: URL, sourceID: String) throws {
        guard !busy, var plan = try load() else { throw CocoaError(.fileLocking) }
        let identity = try SourceIdentity.resolve(url)
        let bookmark = try BookmarkStore.makeBookmark(for: url)
        for index in plan.groups.indices where plan.groups[index].source.id == sourceID {
            guard plan.groups[index].identity.matches(identity) else { throw CocoaError(.fileReadNoPermission) }
            plan.groups[index].source.bookmarkData = bookmark
        }
        for index in plan.groups.indices where plan.groups[index].destination?.id == sourceID {
            guard plan.groups[index].destinationIdentity?.matches(identity) == true else { throw CocoaError(.fileReadNoPermission) }
            plan.groups[index].destination?.bookmarkData = bookmark
        }
        try save(plan)
    }

    private func load() throws -> ArchivePlan? {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return nil }
        return try JSONDecoder().decode(ArchivePlan.self, from: Data(contentsOf: journalURL))
    }

    private func save(_ plan: ArchivePlan) throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(plan).write(to: journalURL, options: .atomic)
        let fd = open(journalURL.path, O_RDONLY)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        let parent = open(journalURL.deletingLastPathComponent().path, O_RDONLY)
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
    }

    private func root(_ group: ArchiveGroup) throws -> URL {
        let resolved = try BookmarkStore.resolve(group.source)
        guard group.source.isOnline, !resolved.isStale else { throw CocoaError(.fileReadNoPermission) }
        return resolved.url
    }

    private func destinationRoot(_ group: ArchiveGroup, fallback: URL) throws -> URL {
        guard let source = group.destination else { return fallback }
        let resolved = try BookmarkStore.resolve(source)
        guard source.isOnline, !resolved.isStale else { throw CocoaError(.fileReadNoPermission) }
        return resolved.url
    }

    private func validateDestinationDirectory(_ group: ArchiveGroup, root: URL) throws {
        guard let identity = group.destinationDirectoryIdentity, let file = group.files.first else { return }
        let directory = try url(file.to, root: root).deletingLastPathComponent()
        try validateRoot(directory, identity)
        guard identity.volume == group.identity.volume else { throw POSIXError(.EXDEV) }
    }

    private func validateRoot(_ root: URL, _ identity: SourceIdentity) throws {
        guard try SourceIdentity.resolve(root).matches(identity), identity.volume != nil, identity.file != nil,
              root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw CocoaError(.fileReadNoPermission)
        }
    }

    private func url(_ relative: String, root: URL, createParents: Bool = false) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CocoaError(.fileReadInvalidFileName) }
        var current = root
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(String(part))
            if index == parts.count - 1 { break }
            if createParents && !FileManager.default.fileExists(atPath: current.path) {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: current.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  FileIdentity.volumeIdentifier(for: current) == FileIdentity.volumeIdentifier(for: root) else { throw POSIXError(.EXDEV) }
        }
        return current
    }

    private func verify(_ file: ArchiveFile, at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              file.fingerprint.identifier != nil,
              file.fingerprint.identifier == FileIdentity.resourceIdentifier(for: url),
              file.fingerprint.matches(try AnalysisFingerprint(url: url)),
              try FileHasher.sha256(of: url) == file.hash else { throw CocoaError(.fileReadCorruptFile) }
    }

    public func prepare(selectedIDs: Set<String>? = nil, destination: URL? = nil) async throws -> ArchivePlan {
        guard !busy else { throw CocoaError(.fileLocking) }
        busy = true
        defer { busy = false }
        guard try !hasPending() else { throw CocoaError(.fileLocking) }
        var plan = ArchivePlan()
        plan.isBatchMove = destination != nil
        let sources = try await store.sources()
        var targetSource: SourceRoot?
        var targetIdentity: SourceIdentity?
        var directoryIdentity: SourceIdentity?
        var targetPrefix = ""
        let targetAccess = destination?.startAccessingSecurityScopedResource() ?? false
        defer { if targetAccess { destination?.stopAccessingSecurityScopedResource() } }
        if let destination {
            guard let selectedIDs, !selectedIDs.isEmpty else { throw CocoaError(.fileReadUnknown) }
            let identity = try SourceIdentity.resolve(destination)
            directoryIdentity = identity
            try validateRoot(destination, identity)
            let canonicalPath: (SourceRoot) -> String = { URL(fileURLWithPath: $0.pathHint).resolvingSymlinksInPath().standardizedFileURL.path }
            let containing = sources.filter { identity.path == canonicalPath($0) || identity.path.hasPrefix(canonicalPath($0) + "/") }
            guard containing.count <= 1,
                  !sources.contains(where: { canonicalPath($0).hasPrefix(identity.path + "/") }) else { throw CocoaError(.fileLocking) }
            if let existing = containing.first {
                let resolved = try BookmarkStore.resolve(existing)
                guard !resolved.isStale, existing.isOnline else { throw CocoaError(.fileReadNoPermission) }
                targetSource = existing
                targetIdentity = try SourceIdentity.resolve(resolved.url)
                guard identity.path == targetIdentity!.path || identity.path.hasPrefix(targetIdentity!.path + "/") else { throw CocoaError(.fileReadNoPermission) }
                if let saved = existing.directoryIdentityJSON {
                    guard try JSONDecoder().decode(SourceIdentity.self, from: Data(saved.utf8)).matches(targetIdentity!) else { throw CocoaError(.fileReadNoPermission) }
                }
                targetPrefix = identity.path == targetIdentity!.path ? "" : String(identity.path.dropFirst(targetIdentity!.path.count + 1))
            } else {
                var source = SourceRoot(name: destination.lastPathComponent, bookmarkData: try BookmarkStore.makeBookmark(for: destination), pathHint: identity.path, volumeIdentifier: identity.volume)
                source.directoryIdentityJSON = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
                targetSource = source; targetIdentity = identity
            }
        }
        var reservedTargets = Set<String>()
        // Parent/child and duplicate roots are conservatively excluded, even when offline.
        let paths = sources.map { URL(fileURLWithPath: $0.pathHint).resolvingSymlinksInPath().standardizedFileURL.path }
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            do {
                guard !paths.enumerated().contains(where: { $0.offset != index &&
                    ($0.element == paths[index] || $0.element.hasPrefix(paths[index] + "/") || paths[index].hasPrefix($0.element + "/")) }) else { throw CocoaError(.fileLocking) }
                let resolved = try BookmarkStore.resolve(source)
                let root = resolved.url
                let access = root.startAccessingSecurityScopedResource()
                defer { if access { root.stopAccessingSecurityScopedResource() } }
                guard source.isOnline, !resolved.isStale else { throw CocoaError(.fileReadNoPermission) }
                let identity = try SourceIdentity.resolve(root)
                try validateRoot(root, identity)
                if let volume = source.volumeIdentifier, volume != identity.volume { throw POSIXError(.EXDEV) }
                if let saved = source.directoryIdentityJSON {
                    guard try JSONDecoder().decode(SourceIdentity.self, from: Data(saved.utf8)).matches(identity) else { throw CocoaError(.fileReadNoPermission) }
                }
                let assets = try await store.assets(sourceID: source.id)
                if let selectedIDs, !assets.contains(where: { selectedIDs.contains($0.id) }) { continue }
                if let targetIdentity, targetIdentity.volume != identity.volume { throw POSIXError(.EXDEV) }
                let grouped = Dictionary(grouping: assets.filter { $0.kind == .photo }) {
                    ($0.relativePath as NSString).deletingPathExtension
                }
                var reserved = Set<String>()
                var directoryEntries: [String: [URL]] = [:]
                for key in grouped.keys.sorted() {
                    try Task.checkCancellation()
                    do {
                        let photos = grouped[key]!.sorted {
                            let a = MediaSupport.isRaw(URL(fileURLWithPath: $0.fileName))
                            let b = MediaSupport.isRaw(URL(fileURLWithPath: $1.fileName))
                            return a == b ? $0.id < $1.id : a
                        }
                        if let selectedIDs {
                            guard photos.contains(where: { selectedIDs.contains($0.id) }) else { continue }
                            guard photos.allSatisfy({ selectedIDs.contains($0.id) }) else {
                                plan.warnings.append("\(key)：RAW/JPEG 配对未全部选中，跳过整组"); continue
                            }
                        }
                        guard photos.count <= 2, photos.count == 1 ||
                            (MediaSupport.isRaw(URL(fileURLWithPath: photos[0].fileName)) && ["jpg", "jpeg"].contains((photos[1].fileName as NSString).pathExtension.lowercased())) else { throw CocoaError(.fileReadUnknown) }
                        let dates = destination == nil ? try photos.compactMap { dateReader(try url($0.relativePath, root: root)) } : []
                        guard let folder = destination != nil ? targetPrefix : dates.first else {
                            plan.warnings.append("\(source.name)/\(key)：无可靠 EXIF 拍摄日期"); continue
                        }
                        if Set(dates).count > 1 { plan.warnings.append("\(key)：配对日期不同，采用 \(folder)") }
                        let parent = try url(photos[0].relativePath, root: root).deletingLastPathComponent()
                        let entries: [URL]
                        if let cached = directoryEntries[parent.path] { entries = cached }
                        else {
                            entries = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                            directoryEntries[parent.path] = entries
                        }
                        let stem = (photos[0].fileName as NSString).deletingPathExtension
                        let sameStemMedia = entries.filter { $0.deletingPathExtension().lastPathComponent == stem && MediaSupport.kind(for: $0) != nil }
                        guard Set(sameStemMedia.map(\.lastPathComponent)) == Set(photos.map(\.fileName)) else { throw CocoaError(.fileReadUnknown) }
                        var files: [ArchiveFile] = []
                        for photo in photos {
                            let original = try url(photo.relativePath, root: root)
                            let fingerprint = try AnalysisFingerprint(url: original)
                            guard fingerprint.matches(AnalysisFingerprint(asset: photo)), FileIdentity.volumeIdentifier(for: original) == identity.volume else { throw CocoaError(.fileReadCorruptFile) }
                            let file = ArchiveFile(asset: photo, from: photo.relativePath, to: "", fingerprint: fingerprint, hash: try FileHasher.sha256(of: original))
                            try verify(file, at: original); files.append(file)
                        }
                        let sidecars = entries.filter { $0.pathExtension.lowercased() == "xmp" &&
                            $0.deletingPathExtension().lastPathComponent == stem }
                        // Both shared stem.xmp and explicit image.ext.xmp are supported.
                        let explicit = entries.filter { candidate in candidate.pathExtension.lowercased() == "xmp" && photos.contains { $0.fileName == candidate.deletingPathExtension().lastPathComponent } }
                        for sidecar in Set(sidecars + explicit).sorted(by: { $0.path < $1.path }) {
                            let relative = FileIdentity.relativePath(of: sidecar, under: root)
                            let file = ArchiveFile(asset: nil, from: relative, to: "", fingerprint: try AnalysisFingerprint(url: sidecar), hash: try FileHasher.sha256(of: sidecar))
                            try verify(file, at: sidecar); files.append(file)
                        }
                        var suffix = 0
                        while true {
                            try Task.checkCancellation()
                            guard suffix < 100_000 else { throw CocoaError(.fileWriteFileExists) }
                            let newStem = stem + (suffix == 0 ? "" : "-\(suffix)")
                            for i in files.indices {
                                let name = (files[i].from as NSString).lastPathComponent
                                files[i].to = (folder.isEmpty ? "" : folder + "/") + newStem + name.dropFirst(stem.count)
                            }
                            let outputRoot = targetSource.map { URL(fileURLWithPath: $0.pathHint) } ?? root
                            if outputRoot == root && files.allSatisfy({ $0.from == $0.to }) { break }
                            if files.allSatisfy({ file in
                                let target = outputRoot.appendingPathComponent(file.to)
                                return !reservedTargets.contains(target.path) && !reserved.contains(file.to) && (target == root.appendingPathComponent(file.from) || (try? FileManager.default.attributesOfItem(atPath: target.path)) == nil)
                            }) { break }
                            suffix += 1
                        }
                        if (targetSource == nil || targetSource?.id == source.id) && files.allSatisfy({ $0.from == $0.to }) { continue }
                        if suffix > 0 { plan.warnings.append("\(key)：目标重名，整组追加 -\(suffix)") }
                        reserved.formUnion(files.map(\.to))
                        reservedTargets.formUnion(files.map { (targetSource.map { URL(fileURLWithPath: $0.pathHint) } ?? root).appendingPathComponent($0.to).path })
                        plan.groups.append(ArchiveGroup(source: source, identity: identity, files: files, destination: targetSource, destinationIdentity: targetIdentity, destinationDirectoryIdentity: directoryIdentity))
                    } catch is CancellationError { throw CancellationError() }
                    catch { plan.warnings.append("\(source.name)/\(key)：跳过（\(error.localizedDescription)）") }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { plan.warnings.append("\(source.pathHint)：跳过来源（离线、授权、目录重叠或身份冲突：\(error.localizedDescription)）") }
        }
        return plan
    }

    public func execute(_ confirmed: ArchivePlan, backupURL: URL) async throws -> ArchiveReport {
        guard !busy else { throw CocoaError(.fileLocking) }
        busy = true
        defer { busy = false }
        guard try !hasPending() else { throw CocoaError(.fileLocking) }
        guard !(try await store.qualityJobs()).contains(where: { $0.job.state != .completed && $0.job.state != .cancelled }) else { throw CocoaError(.fileLocking) }
        try await store.backup(to: backupURL)
        if let previous = try load() {
            let history = journalURL.deletingLastPathComponent().appendingPathComponent("archive-\(previous.id).json")
            try JSONEncoder().encode(previous).write(to: history, options: .withoutOverwriting)
        }
        var plan = confirmed
        try save(plan)
        return try await run(&plan, undo: false)
    }

    public func resume(undo: Bool = false) async throws -> ArchiveReport {
        guard !busy else { throw CocoaError(.fileLocking) }
        busy = true
        defer { busy = false }
        guard !(try await store.qualityJobs()).contains(where: { $0.job.state != .completed && $0.job.state != .cancelled }) else { throw CocoaError(.fileLocking) }
        guard var plan = try load() else { return ArchiveReport() }
        if undo {
            try await store.backup(to: journalURL.deletingLastPathComponent().appendingPathComponent("Backups/archive-undo-\(UUID()).sqlite"))
        }
        return try await run(&plan, undo: undo)
    }

    private func run(_ plan: inout ArchivePlan, undo: Bool) async throws -> ArchiveReport {
        var report = ArchiveReport()
        for index in plan.groups.indices {
            if Task.isCancelled { report.warnings.append("已取消后续项目，可继续归档"); break }
            let group = plan.groups[index]
            if group.state == "skipped" || (undo ? group.state == "undone" : (group.state == "done" || group.state == "undone")) { continue }
            do {
                let root = try root(group)
                let access = root.startAccessingSecurityScopedResource()
                defer { if access { root.stopAccessingSecurityScopedResource() } }
                try validateRoot(root, group.identity)
                let reversing = undo || group.state == "undoing" || group.state == "rollbackForward"
                let targetRoot = try destinationRoot(group, fallback: root)
                let targetAccess = targetRoot.startAccessingSecurityScopedResource()
                defer { if targetAccess { targetRoot.stopAccessingSecurityScopedResource() } }
                if let identity = group.destinationIdentity {
                    try validateRoot(targetRoot, identity)
                    guard identity.volume == group.identity.volume else { throw POSIXError(.EXDEV) }
                }
                try validateDestinationDirectory(group, root: targetRoot)
                let fromRoot = reversing ? targetRoot : root
                let toRoot = reversing ? root : targetRoot
                let moves = group.files.map { file -> ArchiveFile in
                    var result = file
                    if reversing { swap(&result.from, &result.to) }
                    return result
                }
                try await store.validateArchive(group.files, reversed: reversing, destination: group.destination)
                // Before the first mutation, validate the entire group. Replaced/offline files are
                // skips, not ambiguous recovery work. Resuming a partial group uses the journal below.
                if group.state == "pending" && !undo || group.state == "done" && undo {
                    for file in moves {
                        let from = try url(file.from, root: fromRoot)
                        try verify(file, at: from)
                        if file.from != file.to || fromRoot != toRoot {
                            let to = toRoot.appendingPathComponent(file.to)
                            guard (try? FileManager.default.attributesOfItem(atPath: to.path)) == nil else { throw CocoaError(.fileWriteFileExists) }
                        }
                    }
                }
                plan.groups[index].state = reversing ? "undoing" : "moving"
                try save(plan)
                do {
                    for file in moves where file.from != file.to || fromRoot != toRoot {
                        let from = try url(file.from, root: fromRoot, createParents: true)
                        let to = try url(file.to, root: toRoot, createParents: true)
                        if (try? FileManager.default.attributesOfItem(atPath: from.path)) != nil {
                            try verify(file, at: from)
                            try save(plan)
                            try mover.move(from, to)
                            try verify(file, at: to)
                            try save(plan)
                        } else {
                            // A missing original alone is not evidence: require exact identity AND hash.
                            try verify(file, at: to)
                        }
                    }
                    try await store.commitArchive(group.files, reversed: reversing, destination: group.destination)
                    plan.groups[index].state = reversing ? "undone" : "done"
                    try save(plan)
                    report.completed += moves.count
                } catch {
                    let failure = error
                    // Persist the rollback direction before touching any file. A second interruption
                    // can then finish rollback rather than accidentally completing the forward move.
                    plan.groups[index].state = reversing ? "rollbackUndo" : "rollbackForward"
                    try save(plan)
                    do {
                        for file in moves.reversed() where file.from != file.to || fromRoot != toRoot {
                            let from = try url(file.from, root: fromRoot, createParents: true)
                            let to = try url(file.to, root: toRoot, createParents: true)
                            if (try? FileManager.default.attributesOfItem(atPath: from.path)) != nil {
                                try verify(file, at: from)
                            } else {
                                try verify(file, at: to)
                                try mover.move(to, from)
                                try verify(file, at: from)
                            }
                            try save(plan)
                        }
                        try await store.commitArchive(group.files, reversed: !reversing, destination: group.destination)
                        plan.groups[index].state = reversing ? "done" : "pending"
                        try save(plan)
                        report.warnings.append("本组已安全回退：\(failure.localizedDescription)。可继续或撤销剩余归档。")
                        if reversing { continue }
                    } catch {
                        report.warnings.append("归档及回退暂停：\(error.localizedDescription)。请恢复归档或撤销；禁止扫描和清理。")
                    }
                    return report
                }
            } catch {
                if group.state == "pending" && plan.groups[index].state == "pending" && !undo {
                    plan.groups[index].state = "skipped"
                    let warning = "\(group.source.name)/\(group.files.first?.from ?? "")：跳过（\(error.localizedDescription)）"
                    plan.warnings.append(warning); report.warnings.append(warning)
                    try save(plan)
                    continue
                }
                if group.state == "done" && plan.groups[index].state == "done" && undo {
                    report.warnings.append("撤销跳过 \(group.files.first?.to ?? "")：\(error.localizedDescription)")
                    continue
                }
                report.warnings.append("\(group.source.name)：暂停（\(error.localizedDescription)）")
                return report
            }
        }
        return report
    }
}
