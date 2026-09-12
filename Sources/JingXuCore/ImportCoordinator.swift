import Foundation
import CryptoKit
import Darwin

public actor ImportCoordinator: Importing {
    public typealias Capacity = @Sendable (URL) throws -> Int64?
    public typealias BeforeCommit = @Sendable (URL) throws -> Void
    private let repository: CatalogStore
    private let scanner: any SourceScanner
    private let capacity: Capacity
    private let beforeCommit: BeforeCommit
    private var running = false

    public init(repository: CatalogStore, scanner: any SourceScanner,
                capacity: @escaping Capacity = { try $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage },
                beforeCommit: @escaping BeforeCommit = { _ in }) {
        self.repository = repository; self.scanner = scanner; self.capacity = capacity; self.beforeCommit = beforeCommit
    }

    public func prepare(from source: URL, to target: URL, batchName: String) async throws -> ImportPlan {
        try makePlan(from: source, to: target, batchName: batchName, folder: ImportNaming.destinationFolder(date: Date(), batchName: batchName))
    }
    public func prepareRetry(_ report: ImportReport) async throws -> ImportPlan {
        let source = try BookmarkStore.resolve(report.plan.sourceRoot), target = try BookmarkStore.resolve(report.plan.targetRoot)
        guard !source.isStale, !target.isStale else { throw ColorEditError("来源或目标授权已失效，请重新选择目录") }
        return try makePlan(from: source.url, to: target.url, batchName: report.plan.batchName, folder: report.plan.relativeFolder)
    }

    private func makePlan(from sourceURL: URL, to targetURL: URL, batchName: String, folder: String) throws -> ImportPlan {
        guard !running else { throw ColorEditError("正在导入，请等待当前任务完成") }
        let sourceLease = PreviewAccessLease(url: sourceURL), targetLease = PreviewAccessLease(url: targetURL)
        defer { withExtendedLifetime((sourceLease, targetLease)) {} }
        let sourceIdentity = try Self.directoryIdentity(sourceURL), targetIdentity = try Self.directoryIdentity(targetURL)
        let source = URL(fileURLWithPath: sourceIdentity.path), target = URL(fileURLWithPath: targetIdentity.path)
        guard !source.pathComponents.starts(with: target.pathComponents), !target.pathComponents.starts(with: source.pathComponents) else {
            throw ColorEditError("来源与目标不能相同，也不能互相包含")
        }
        let sourceRoot = SourceRoot(name: source.lastPathComponent, bookmarkData: try BookmarkStore.makeBookmark(for: source), pathHint: source.path)
        let targetRoot = SourceRoot(name: target.lastPathComponent, bookmarkData: try BookmarkStore.makeBookmark(for: target), pathHint: target.path)
        var existingDirectories: [String: SourceIdentity] = [:], directory = target
        var relative = ""
        for part in try Self.parts(folder) {
            relative = relative.isEmpty ? part : relative + "/" + part
            directory.appendPathComponent(part)
            if try Self.exists(directory) { existingDirectories[relative] = try Self.directoryIdentity(directory) }
        }
        let destination = target.appendingPathComponent(folder)
        let entries = try Self.exists(destination) ? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) : []
        let destinationFamilies = Dictionary(grouping: entries, by: { Self.fold(Self.familyStem($0)) })
        _ = try FileManager.default.contentsOfDirectory(atPath: source.path)
        var issues: [ImportIssue] = [], allFiles: [URL] = []
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in
            issues.append(.init(path: FileIdentity.relativePath(of: url, under: source), stage: .directory, reason: error.localizedDescription)); return true
        }) else { throw ColorEditError("无法枚举来源目录") }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw ColorEditError("符号链接不参与导入") }
                if attributes[.type] as? FileAttributeType == .typeRegular { allFiles.append(url) }
            } catch { issues.append(.init(path: FileIdentity.relativePath(of: url, under: source), stage: .directory, reason: error.localizedDescription)) }
        }
        let byDirectory = Dictionary(grouping: allFiles, by: { $0.deletingLastPathComponent() })
        var groups: [ImportGroup] = [], reserved = Set<String>()
        for parent in byDirectory.keys.sorted(by: { $0.path < $1.path }) {
            let siblings = byDirectory[parent]!
            let media = siblings.filter { MediaSupport.kind(for: $0) != nil }
            let families = Dictionary(grouping: media.filter { MediaSupport.kind(for: $0) == .photo }, by: { $0.deletingPathExtension().lastPathComponent })
            let ambiguousCase = Dictionary(grouping: families.keys, by: Self.fold).filter { $0.value.count > 1 }
            var associated = Set<URL>()
            let work = Array(families.values) + media.filter { MediaSupport.kind(for: $0) == .video }.map { [$0] }
            for family in work.sorted(by: { $0[0].path < $1[0].path }) {
                try Task.checkCancellation()
                let stem = family[0].deletingPathExtension().lastPathComponent
                let groupID = FileIdentity.relativePath(of: family[0], under: source)
                do {
                    guard ambiguousCase[Self.fold(stem)] == nil else { throw ColorEditError("大小写同名关系不明确") }
                    let members: [URL]
                    if family.count == 1, MediaSupport.kind(for: family[0]) == .video { members = family }
                    else { members = try MediaFileGroup.members(photos: family, entries: siblings.filter { MediaSupport.kind(for: $0) != .video }) }
                    associated.formUnion(members)
                    var inputs: [(URL, AnalysisFingerprint, String)] = []
                    for url in members {
                        try Self.requireSafe(url, root: source)
                        let fingerprint = try AnalysisFingerprint(url: url)
                        guard fingerprint.identifier != nil else { throw ColorEditError("无法确认文件身份") }
                        let hash = try FileHasher.sha256(of: url)
                        try ColorSourceAccess.requireSame(fingerprint, AnalysisFingerprint(url: url))
                        inputs.append((url, fingerprint, hash))
                    }
                    let base = Self.fold(stem)
                    let candidates = destinationFamilies.keys.compactMap { key -> Int? in
                        if key == base { return 1 }
                        guard key.hasPrefix(base + "-"), let n = Int(key.dropFirst(base.count + 1)), n >= 2 else { return nil }
                        return n
                    }.sorted()
                    var complete: [ImportFile]?, partial: [ImportFile]?, selectedStem: String?
                    for index in candidates {
                        let candidate = stem + (index == 1 ? "" : "-\(index)")
                        guard !reserved.contains(Self.fold(candidate)) else { continue }
                        let existing = destinationFamilies[Self.fold(candidate)] ?? []
                        let names = Set(inputs.map { Self.fold(candidate + $0.0.lastPathComponent.dropFirst(stem.count)) })
                        guard existing.allSatisfy({ names.contains(Self.fold($0.lastPathComponent)) }),
                              Set(existing.map { Self.fold($0.lastPathComponent) }).count == existing.count else { continue }
                        var files: [ImportFile] = [], matches = true
                        for (url, fingerprint, hash) in inputs {
                            let name = candidate + url.lastPathComponent.dropFirst(stem.count)
                            let found = existing.first { Self.fold($0.lastPathComponent) == Self.fold(name) }
                            var foundFingerprint: AnalysisFingerprint?
                            if let found {
                                try Self.requireSafe(found, root: target)
                                let other = try AnalysisFingerprint(url: found)
                                guard other.size == fingerprint.size, try FileHasher.sha256(of: found) == hash else { matches = false; break }
                                try ColorSourceAccess.requireSame(other, AnalysisFingerprint(url: found)); foundFingerprint = other
                            }
                            files.append(.init(relativePath: FileIdentity.relativePath(of: url, under: source), destinationName: found?.lastPathComponent ?? name, fingerprint: fingerprint, hash: hash, existingFingerprint: foundFingerprint))
                        }
                        if matches, files.allSatisfy(\.isDuplicate) { complete = files; selectedStem = candidate; break }
                        if matches, partial == nil { partial = files }
                    }
                    let files: [ImportFile]
                    if let complete { files = complete }
                    else if let partial { files = partial; selectedStem = Self.familyStem(URL(fileURLWithPath: partial[0].destinationName)) }
                    else {
                        var index = 1, candidate = stem
                        while destinationFamilies[Self.fold(candidate)] != nil || reserved.contains(Self.fold(candidate)) {
                            try Task.checkCancellation(); index += 1; candidate = stem + "-\(index)"
                        }
                        selectedStem = candidate
                        files = inputs.map { url, fingerprint, hash in
                            .init(relativePath: FileIdentity.relativePath(of: url, under: source), destinationName: candidate + url.lastPathComponent.dropFirst(stem.count), fingerprint: fingerprint, hash: hash, existingFingerprint: nil)
                        }
                    }
                    reserved.insert(Self.fold(selectedStem!)); groups.append(.init(id: groupID, files: files))
                } catch is CancellationError { throw CancellationError() }
                catch { issues.append(.init(path: groupID, stage: .grouping, reason: error.localizedDescription)) }
            }
            for sidecar in siblings where sidecar.pathExtension.lowercased() == "xmp" && !associated.contains(sidecar) {
                issues.append(.init(path: FileIdentity.relativePath(of: sidecar, under: source), stage: .grouping, reason: "无法明确关联照片，未复制 XMP"))
            }
        }
        let plan = ImportPlan(id: UUID().uuidString, sourceRoot: sourceRoot, targetRoot: targetRoot, sourceIdentity: sourceIdentity, targetIdentity: targetIdentity, relativeFolder: folder, existingDirectories: existingDirectories, batchName: batchName, groups: groups, issues: issues)
        try verifyCapacity(plan.bytesToCopy, at: target)
        return plan
    }

    public func execute(_ plan: ImportPlan, progress: ImportProgressHandler? = nil) async throws -> ImportReport {
        guard !running else { throw ColorEditError("正在导入，请勿重复执行") }
        running = true; defer { running = false }
        let source = try BookmarkStore.resolve(plan.sourceRoot), target = try BookmarkStore.resolve(plan.targetRoot)
        guard !source.isStale, !target.isStale else { throw ColorEditError("来源或目标需要重新授权") }
        let leases = (PreviewAccessLease(url: source.url), PreviewAccessLease(url: target.url))
        let sourceURL = URL(fileURLWithPath: try Self.directoryIdentity(source.url).path)
        let targetURL = URL(fileURLWithPath: try Self.directoryIdentity(target.url).path)
        defer { withExtendedLifetime(leases) {} }
        var report = ImportReport(plan: plan, session: .init(id: plan.id, sourcePath: source.url.path, destinationPath: plan.destination.path, batchName: plan.batchName, status: .running, totalFiles: plan.totalFiles), issues: plan.issues)
        try await repository.saveImportReport(report, starting: true)
        var stage: ImportIssue.Stage = .copy
        do {
            try Task.checkCancellation()
            try validateRoots(plan, source: sourceURL, target: targetURL)
            try verifyCapacity(plan.bytesToCopy, at: targetURL)
            let destination = try makeDestination(plan, target: targetURL)
            let destinationIdentity = try Self.directoryIdentity(destination)
            for group in plan.groups {
                try Task.checkCancellation()
                var value = report.progress; value.currentFile = group.id; await progress?(value)
                try Task.checkCancellation()
                try validateRoots(plan, source: sourceURL, target: targetURL)
                guard try Self.directoryIdentity(destination) == destinationIdentity else { throw ColorEditError("导入目标目录已变化") }
                let temporary = destination.appendingPathComponent(".jingxu-import-" + UUID().uuidString)
                var submitted = 0, skipped = 0
                var failed = false
                do {
                    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    for (index, file) in group.files.enumerated() {
                        _ = try Self.parts(file.relativePath)
                        guard try Self.parts(file.destinationName).count == 1 else { throw ColorEditError("目标文件名越界") }
                        let original = sourceURL.appendingPathComponent(file.relativePath)
                        try Self.requireSafe(original, root: sourceURL)
                        try ColorSourceAccess.requireSame(file.fingerprint, AnalysisFingerprint(url: original))
                        let output = destination.appendingPathComponent(file.destinationName)
                        try Self.requireSafe(output, root: targetURL, missingLeaf: true)
                        if let expected = file.existingFingerprint {
                            try ColorSourceAccess.requireSame(expected, AnalysisFingerprint(url: output))
                            guard try FileHasher.sha256(of: output) == file.hash else { throw ColorEditError("重复文件在确认后已变化") }
                        } else {
                            guard try !Self.exists(output) else { throw ColorEditError("目标在确认后出现同名文件，请重新预检") }
                            let staged = temporary.appendingPathComponent(String(index))
                            try Self.copy(original, to: staged)
                            guard try FileHasher.sha256(of: staged) == file.hash else { throw ColorEditError("复制校验失败") }
                        }
                        try ColorSourceAccess.requireSame(file.fingerprint, AnalysisFingerprint(url: original))
                    }
                    for (index, file) in group.files.enumerated() {
                        try Task.checkCancellation()
                        try validateRoots(plan, source: sourceURL, target: targetURL)
                        try Self.requireSafe(destination, root: targetURL)
                        guard try Self.directoryIdentity(destination) == destinationIdentity else { throw ColorEditError("导入目标目录已变化") }
                        let output = destination.appendingPathComponent(file.destinationName)
                        try ColorSourceAccess.requireSame(file.fingerprint, AnalysisFingerprint(url: sourceURL.appendingPathComponent(file.relativePath)))
                        if let expected = file.existingFingerprint {
                            try Self.requireSafe(output, root: targetURL)
                            try ColorSourceAccess.requireSame(expected, AnalysisFingerprint(url: output)); skipped += 1
                        } else {
                            try beforeCommit(output)
                            guard try Self.directoryIdentity(destination) == destinationIdentity else { throw ColorEditError("导入目标已变化") }
                            try Self.requireSafe(output, root: targetURL, missingLeaf: true)
                            if renamex_np(temporary.appendingPathComponent(String(index)).path, output.path, UInt32(RENAME_EXCL)) != 0 {
                                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                            }
                            submitted += 1
                        }
                    }
                } catch is CancellationError {
                    report.session.completedFiles += submitted; report.session.skippedFiles += skipped
                    throw CancellationError()
                } catch {
                    failed = true
                    report.issues.append(.init(path: group.id, stage: .copy, reason: error.localizedDescription))
                    report.session.failedFiles += group.files.count - submitted - skipped
                }
                report.session.completedFiles += submitted; report.session.skippedFiles += skipped; report.session.updatedAt = Date()
                try await repository.saveImportReport(report, includePayload: failed)
                // Once publication began, do not guess about the rest of this batch.
                if failed && submitted > 0 { break }
            }
            try Task.checkCancellation()
            stage = .index
            report.source = try await repository.registerSource(at: destination)
            report.scanReport = try await scanner.scan(source: report.source!, progress: nil)
            if let scan = report.scanReport {
                report.issues += scan.failures.map { .init(path: $0.path, stage: .index, reason: $0.reason) }
            }
            report.outcome = report.issues.isEmpty ? .completed : (report.session.completedFiles + report.session.skippedFiles > 0 ? .partial : .failed)
        } catch is CancellationError { report.outcome = .cancelled }
        catch { report.outcome = .failed; report.issues.append(.init(path: plan.relativeFolder, stage: stage, reason: error.localizedDescription)) }
        report.session.status = report.outcome == .completed ? .completed : (report.outcome == .cancelled ? .cancelled : .failed)
        report.session.errorMessage = report.issues.last?.reason; report.session.updatedAt = Date()
        try await repository.saveImportReport(report)
        await progress?(report.progress)
        return report
    }

    private func verifyCapacity(_ bytes: Int64, at url: URL) throws {
        if let available = try capacity(url), available < bytes + 512 * 1_024 * 1_024 { throw CocoaError(.fileWriteOutOfSpace) }
    }
    private func validateRoots(_ plan: ImportPlan, source: URL, target: URL) throws {
        guard try Self.directoryIdentity(source) == plan.sourceIdentity, try Self.directoryIdentity(target) == plan.targetIdentity else { throw ColorEditError("来源或目标身份已变化，请重新预检") }
    }
    private func makeDestination(_ plan: ImportPlan, target: URL) throws -> URL {
        var directory = target, relative = ""
        for part in try Self.parts(plan.relativeFolder) {
            directory.appendPathComponent(part); relative = relative.isEmpty ? part : relative + "/" + part
            if let expected = plan.existingDirectories[relative] {
                guard try Self.directoryIdentity(directory) == expected else { throw ColorEditError("目标目录已变化") }
            } else {
                guard try !Self.exists(directory) else { throw ColorEditError("目标目录在预检后出现，请重新预检") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
        }
        return directory
    }
    static func fold(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    static func familyStem(_ url: URL) -> String {
        let base = url.deletingPathExtension()
        if url.pathExtension.lowercased() == "xmp", MediaSupport.kind(for: base) != nil { return base.deletingPathExtension().lastPathComponent }
        return base.lastPathComponent
    }
    static func parts(_ relative: String) throws -> [String] {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ColorEditError("路径越界") }
        return parts
    }
    static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        if errno == ENOENT { return false }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    static func directoryIdentity(_ url: URL) throws -> SourceIdentity {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ColorEditError("目录无效或包含符号链接") }
        let identity = try SourceIdentity.resolve(url)
        guard identity.file != nil, identity.volume != nil else { throw ColorEditError("无法确认目录身份") }
        return identity
    }
    static func requireSafe(_ url: URL, root: URL, missingLeaf: Bool = false) throws {
        let base = URL(fileURLWithPath: root.path).standardizedFileURL, candidate = URL(fileURLWithPath: url.path).standardizedFileURL
        guard candidate.pathComponents.starts(with: base.pathComponents), candidate.pathComponents.count > base.pathComponents.count else { throw ColorEditError("路径越界") }
        var current = base
        let parts = candidate.pathComponents.dropFirst(base.pathComponents.count)
        for part in parts {
            current.appendPathComponent(part)
            if missingLeaf && current == candidate { if try !exists(current) { return } }
            let a = try FileManager.default.attributesOfItem(atPath: current.path)
            guard a[.type] as? FileAttributeType != .typeSymbolicLink else { throw ColorEditError("路径包含符号链接") }
        }
    }
    static func copy(_ source: URL, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        while true {
            try Task.checkCancellation()
            guard let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty else { break }
            try output.write(contentsOf: bytes)
        }
        try output.synchronize()
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        if let date = attributes[.modificationDate] { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: destination.path) }
    }
}
