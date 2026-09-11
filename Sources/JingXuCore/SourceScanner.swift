import Foundation
import UniformTypeIdentifiers

public struct ScanProgress: Sendable, Equatable {
    public var discovered: Int
    public var processed: Int
    public var currentFile: String

    public init(discovered: Int, processed: Int, currentFile: String) {
        self.discovered = discovered
        self.processed = processed
        self.currentFile = currentFile
    }
}

public struct ScanFailure: Sendable, Equatable {
    public enum Stage: String, Sendable { case directory = "读取目录", file = "读取文件", metadata = "解析元数据" }
    public var path: String
    public var stage: Stage
    public var reason: String
}

public struct ScanReport: Sendable, Equatable {
    public var sourceID: String
    public var assetIDs: [String] = []
    public var discoveredFiles = 0
    public var unchangedFiles = 0
    public var skippedFiles = 0
    public var failedFiles = 0
    public var failedDirectories = 0
    /// Counts remain complete; only the first 30 details are retained for presentation.
    public var failures: [ScanFailure] = []
    public var isPartial: Bool { failedFiles > 0 || failedDirectories > 0 }

    public init(sourceID: String) { self.sourceID = sourceID }

    mutating func record(path: String, stage: ScanFailure.Stage, reason: String) {
        if stage == .directory { failedDirectories += 1 } else { failedFiles += 1 }
        if failures.count < 30 { failures.append(ScanFailure(path: path, stage: stage, reason: reason)) }
    }
}

public typealias ScanProgressHandler = @Sendable (ScanProgress) async -> Void

public protocol SourceScanner: Sendable {
    func scan(source: SourceRoot, progress: ScanProgressHandler?) async throws -> ScanReport
}

public struct DefaultSourceScanner: SourceScanner {
    private let repository: any CatalogRepository
    private let metadataExtractor: any MetadataExtractor

    public init(repository: any CatalogRepository, metadataExtractor: any MetadataExtractor = DefaultMetadataExtractor()) {
        self.repository = repository
        self.metadataExtractor = metadataExtractor
    }

    public func scan(source: SourceRoot, progress: ScanProgressHandler? = nil) async throws -> ScanReport {
        guard var mutableSource = try await repository.source(id: source.id) else {
            throw NSError(domain: "JingXu.Scan", code: 1, userInfo: [NSLocalizedDescriptionKey: "来源已不在图库中，无法扫描"])
        }
        let resolved = try BookmarkStore.resolve(mutableSource)
        let root = resolved.url
        let didAccess = root.startAccessingSecurityScopedResource()
        defer { if didAccess { root.stopAccessingSecurityScopedResource() } }

        try Task.checkCancellation()
        do {
            _ = try root.checkResourceIsReachable()
        } catch {
            let failure = error as NSError
            // Permission and identity failures are not evidence that a source is offline.
            if failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) {
                mutableSource.isOnline = false
                try await repository.upsertSource(mutableSource)
            }
            throw error
        }

        let (files, enumerationReport) = try mediaFiles(under: root, sourceID: source.id)
        var report = enumerationReport
        let existingAssets = try await repository.assets(sourceID: source.id)
        let existingByPath = Dictionary(uniqueKeysWithValues: existingAssets.map { ($0.relativePath, $0) })
        var pendingAssets: [MediaAsset] = []

        for (index, discoveredURL) in files.enumerated() {
            try Task.checkCancellation()
            var fileURL = discoveredURL
            guard let kind = MediaSupport.kind(for: fileURL) else {
                report.skippedFiles += 1
                continue
            }
            await progress?(ScanProgress(discovered: files.count, processed: index, currentFile: fileURL.lastPathComponent))
            try Task.checkCancellation()
            // Enumeration can cache attributes; reread before deciding that a file is unchanged.
            fileURL.removeAllCachedResourceValues()
            do {
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let relativePath = FileIdentity.relativePath(of: fileURL, under: root)
                let fileSize = Int64(values.fileSize ?? 0)
                let modifiedAt = values.contentModificationDate ?? Date.distantPast
                let fileIdentifier = FileIdentity.resourceIdentifier(for: fileURL)
                if let existing = existingByPath[relativePath], existing.metadataError == nil,
                   existing.fileIdentifier == fileIdentifier,
                   existing.fileSize == fileSize,
                   abs(existing.modifiedAt.timeIntervalSince(modifiedAt)) < 0.001 {
                    report.unchangedFiles += 1
                    continue
                }
                let metadata = await metadataExtractor.extract(from: fileURL, kind: kind)
                try Task.checkCancellation()
                let pairKey = fileURL.deletingPathExtension().lastPathComponent.lowercased()
                let asset = MediaAsset(
                    sourceID: source.id,
                    relativePath: relativePath,
                    fileIdentifier: fileIdentifier,
                    fileName: fileURL.lastPathComponent,
                    uniformType: metadata.uniformType ?? UTType(filenameExtension: fileURL.pathExtension)?.identifier,
                    kind: kind,
                    fileSize: fileSize,
                    modifiedAt: modifiedAt,
                    capturedAt: metadata.capturedAt,
                    width: metadata.width,
                    height: metadata.height,
                    duration: metadata.duration,
                    cameraMake: metadata.cameraMake,
                    cameraModel: metadata.cameraModel,
                    lens: metadata.lens,
                    orientation: metadata.orientation,
                    latitude: metadata.latitude,
                    longitude: metadata.longitude,
                    rawPairKey: pairKey,
                    metadataError: metadata.errorMessage
                )
                pendingAssets.append(asset)
                if let reason = metadata.errorMessage {
                    report.record(path: relativePath, stage: .metadata, reason: reason)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.record(path: FileIdentity.relativePath(of: fileURL, under: root), stage: .file, reason: error.localizedDescription)
            }
            // Database errors must escape: do not treat a failed batch as one bad photo.
            try Task.checkCancellation()
            if pendingAssets.count >= 200 {
                let stored = try await repository.upsertAssets(pendingAssets)
                report.assetIDs.append(contentsOf: stored.map(\.id))
                pendingAssets.removeAll(keepingCapacity: true)
            }
        }

        try Task.checkCancellation()
        if !pendingAssets.isEmpty {
            let stored = try await repository.upsertAssets(pendingAssets)
            report.assetIDs.append(contentsOf: stored.map(\.id))
        }

        try Task.checkCancellation()
        mutableSource.isOnline = true
        if !report.isPartial { mutableSource.lastScanAt = Date() }
        if let identity = try? SourceIdentity.resolve(root), let data = try? JSONEncoder().encode(identity) {
            mutableSource.volumeIdentifier = identity.volume
            mutableSource.directoryIdentityJSON = String(decoding: data, as: UTF8.self)
        }
        if resolved.isStale {
            mutableSource.bookmarkData = try? BookmarkStore.makeBookmark(for: root)
        }
        try await repository.upsertSource(mutableSource)
        await progress?(ScanProgress(discovered: files.count, processed: files.count, currentFile: ""))
        return report
    }

    private func mediaFiles(under root: URL, sourceID: String) throws -> ([URL], ScanReport) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        var report = ScanReport(sourceID: sourceID)
        var rootError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                if url.standardizedFileURL == root.standardizedFileURL {
                    rootError = error
                    return false
                }
                report.record(path: FileIdentity.relativePath(of: url, under: root), stage: .directory, reason: error.localizedDescription)
                return true
            }
        ) else { throw CocoaError(.fileReadUnknown) }

        var result: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true, values.isHidden != true else { continue }
                if MediaSupport.kind(for: url) != nil { result.append(url) }
                else { report.skippedFiles += 1 }
            } catch {
                report.record(path: FileIdentity.relativePath(of: url, under: root), stage: .file, reason: error.localizedDescription)
            }
        }
        try Task.checkCancellation()
        if let rootError { throw rootError }
        report.discoveredFiles = result.count
        return (result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, report)
    }
}
