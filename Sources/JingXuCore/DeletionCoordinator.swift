import Foundation

public struct DeletionPlan: Identifiable, Codable, Sendable {
    public var id = UUID().uuidString
    public var files: [MediaAsset]
    public var sourcePaths: [String: String] = [:]
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.fileSize } }
    public init(files: [MediaAsset]) { self.files = files }
}

public struct DeletionReport: Sendable {
    public var deleted = 0
    public var skipped = 0
    public var skipReasons: [String] = []
    public var failures: [String] = []
    public var cancelled = false
    public init() {}
}

public protocol TrashService: Sendable {
    func trash(_ url: URL) throws -> URL?
}

public struct SystemTrashService: TrashService {
    public init() {}
    public func trash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

// The journal precedes each filesystem operation. Ambiguous interrupted moves
// are retained for review; a missing file alone never authorizes record removal.
public struct DeletionJournalEntry: Codable, Sendable {
    public var asset: MediaAsset
    public var state: String
    public var trashPath: String?
    public var relatedIDs: [String]?
    public init(asset: MediaAsset, state: String, trashPath: String? = nil) {
        self.asset = asset; self.state = state; self.trashPath = trashPath
    }
}

public actor DeletionCoordinator {
    private let store: CatalogStore
    private let trash: any TrashService
    private let journalURL: URL
    private var active = false
    public init(store: CatalogStore, journalURL: URL, trash: any TrashService = SystemTrashService()) {
        self.store = store; self.journalURL = journalURL; self.trash = trash
    }

    public func prepare(_ query: AssetQuery) async throws -> DeletionPlan {
        var plan = DeletionPlan(files: try await store.deletionCandidates(query))
        for sourceID in Set(plan.files.map(\.sourceID)) {
            if let source = try await store.source(id: sourceID) {
                let root = (try? BookmarkStore.resolve(source).url) ?? URL(fileURLWithPath: source.pathHint)
                plan.sourcePaths[sourceID] = root.standardizedFileURL.path
            }
        }
        return plan
    }

    public func recover() async throws -> [String] {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return [] }
        var entries = try JSONDecoder().decode([DeletionJournalEntry].self, from: Data(contentsOf: journalURL))
        var warnings: [String] = []
        for i in entries.indices {
            if entries[i].state == "moved" {
                try await store.removeAssetRecords(entries[i].relatedIDs ?? [entries[i].asset.id])
                entries[i].state = "complete"
            } else if entries[i].state == "moving" {
                let asset = entries[i].asset
                if let source = try await store.source(id: asset.sourceID),
                   let root = try? BookmarkStore.resolve(source).url {
                    let access = root.startAccessingSecurityScopedResource()
                    defer { if access { root.stopAccessingSecurityScopedResource() } }
                    let url = root.appendingPathComponent(asset.relativePath)
                    if let identity = asset.fileIdentifier, FileIdentity.resourceIdentifier(for: url) == identity {
                        entries[i].state = "failed"
                        continue
                    }
                }
                warnings.append("上次操作中断，请在访达恢复原文件后重试清理：\(asset.relativePath)。图库记录已保留。")
            }
        }
        try persist(entries)
        return warnings
    }

    public func execute(_ plan: DeletionPlan, progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> DeletionReport {
        guard !active else { throw CocoaError(.fileWriteUnknown) }
        active = true
        defer { active = false }
        let unresolved = try await recover()
        guard unresolved.isEmpty else { throw NSError(domain: "JingXu", code: 1, userInfo: [NSLocalizedDescriptionKey: unresolved.joined(separator: "\n")]) }
        var entries = plan.files.map { DeletionJournalEntry(asset: $0, state: "pending") }
        try persist(entries)
        var report = DeletionReport()
        var handledPaths = Set<String>()
        let confirmedIDs = Set(plan.files.map(\.id))
        for i in entries.indices {
            if Task.isCancelled { report.cancelled = true; break }
            await progress(i, entries.count)
                let planned = entries[i].asset
            do {
                guard let current = try await store.asset(id: planned.id), current == planned, current.kind == .photo,
                      try await store.annotation(for: planned.id).flag == .rejected,
                      let source = try await store.source(id: planned.sourceID), source.isOnline else {
                    entries[i].state = "skipped"; report.skipped += 1
                    report.skipReasons.append("\(planned.relativePath)：标记或图库记录已改变")
                    continue
                }
                let root = try BookmarkStore.resolve(source).url
                if let confirmedRoot = plan.sourcePaths[source.id], root.standardizedFileURL.path != confirmedRoot {
                    entries[i].state = "skipped"; report.skipped += 1
                    report.skipReasons.append("\(planned.relativePath)：来源路径已改变")
                    continue
                }
                let access = root.startAccessingSecurityScopedResource()
                defer { if access { root.stopAccessingSecurityScopedResource() } }
                let url = root.appendingPathComponent(planned.relativePath).standardizedFileURL
                let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot),
                      handledPaths.insert(url.path).inserted else {
                    entries[i].state = "skipped"; report.skipped += 1
                    report.skipReasons.append("\(planned.relativePath)：重复路径或超出来源目录")
                    continue
                }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      Int64(values.fileSize ?? -1) == planned.fileSize,
                      abs((values.contentModificationDate ?? .distantPast).timeIntervalSince(planned.modifiedAt)) < 0.001,
                      let identity = planned.fileIdentifier, identity == FileIdentity.resourceIdentifier(for: url) else {
                    entries[i].state = "skipped"; report.skipped += 1
                    report.skipReasons.append("\(planned.relativePath)：文件身份、大小或修改时间已改变")
                    continue
                }
                var relatedIDs = [planned.id]
                var unsafeAlias = false
                for alias in try await store.assetsWithFileIdentifier(identity) where alias.id != planned.id {
                    guard let aliasSource = try await store.source(id: alias.sourceID),
                          let aliasRoot = try? BookmarkStore.resolve(aliasSource).url else { continue }
                    if aliasRoot.appendingPathComponent(alias.relativePath).resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL {
                        let aliasFlag = try await store.annotation(for: alias.id).flag
                        if !confirmedIDs.contains(alias.id) || alias.kind != .photo || aliasFlag != .rejected {
                            unsafeAlias = true
                        }
                        relatedIDs.append(alias.id)
                    }
                }
                guard !unsafeAlias, try await store.annotation(for: planned.id).flag == .rejected else {
                    entries[i].state = "skipped"; report.skipped += 1
                    report.skipReasons.append("\(planned.relativePath)：存在未确认的重复索引或已取消淘汰")
                    continue
                }
                // Recheck after the actor hops above, immediately before the synchronous move.
                if Task.isCancelled { report.cancelled = true; break }
                let finalValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard FileIdentity.resourceIdentifier(for: url) == identity,
                      url.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot),
                      finalValues.fileSize == values.fileSize,
                      finalValues.contentModificationDate == values.contentModificationDate else {
                    entries[i].state = "skipped"; report.skipped += 1
                    report.skipReasons.append("\(planned.relativePath)：执行前文件再次发生变化")
                    continue
                }
                entries[i].relatedIDs = relatedIDs
                entries[i].state = "moving"
                try persist(entries)
                let destination = try trash.trash(url)
                entries[i].state = "moved"
                entries[i].trashPath = destination?.path
                try persist(entries)
                try await store.removeAssetRecords(relatedIDs)
                entries[i].state = "complete"
                report.deleted += 1
            } catch {
                // Preserve moved/moving entries for recovery, including journal write failures.
                if entries[i].state == "pending" {
                    entries[i].state = "skipped"
                    report.skipped += 1
                    report.skipReasons.append("\(planned.relativePath)：无法复核来源或访问文件，\(error.localizedDescription)")
                } else {
                    report.failures.append("\(planned.relativePath)：\(error.localizedDescription)")
                }
            }
            try persist(entries)
            await progress(i + 1, entries.count)
        }
        try persist(entries)
        return report
    }

    private func persist(_ entries: [DeletionJournalEntry]) throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: journalURL, options: .atomic)
    }
}
