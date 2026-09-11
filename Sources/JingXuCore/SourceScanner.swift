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

public struct ScanReport: Sendable, Equatable {
    public var sourceID: String
    public var assetIDs: [String]
    public var skippedFiles: Int
    public var failedFiles: Int

    public init(sourceID: String, assetIDs: [String], skippedFiles: Int, failedFiles: Int) {
        self.sourceID = sourceID
        self.assetIDs = assetIDs
        self.skippedFiles = skippedFiles
        self.failedFiles = failedFiles
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
        var mutableSource = source
        let resolved = try BookmarkStore.resolve(source)
        let root = resolved.url
        let didAccess = root.startAccessingSecurityScopedResource()
        defer { if didAccess { root.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: root.path) else {
            mutableSource.isOnline = false
            try await repository.upsertSource(mutableSource)
            throw CocoaError(.fileNoSuchFile)
        }

        let files = mediaFiles(under: root)
        let existingAssets = try await repository.assets(sourceID: source.id)
        let existingByPath = Dictionary(uniqueKeysWithValues: existingAssets.map { ($0.relativePath, $0) })
        var assetIDs: [String] = []
        var pendingAssets: [MediaAsset] = []
        var skipped = 0
        var failed = 0

        for (index, fileURL) in files.enumerated() {
            try Task.checkCancellation()
            guard let kind = MediaSupport.kind(for: fileURL) else {
                skipped += 1
                continue
            }
            await progress?(ScanProgress(discovered: files.count, processed: index, currentFile: fileURL.lastPathComponent))
            do {
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let relativePath = FileIdentity.relativePath(of: fileURL, under: root)
                let fileSize = Int64(values.fileSize ?? 0)
                let modifiedAt = values.contentModificationDate ?? Date.distantPast
                let fileIdentifier = FileIdentity.resourceIdentifier(for: fileURL)
                if let existing = existingByPath[relativePath],
                   existing.fileIdentifier == fileIdentifier,
                   existing.fileSize == fileSize,
                   abs(existing.modifiedAt.timeIntervalSince(modifiedAt)) < 0.001 {
                    continue
                }
                let metadata = await metadataExtractor.extract(from: fileURL, kind: kind)
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
                if pendingAssets.count >= 200 {
                    let stored = try await repository.upsertAssets(pendingAssets)
                    assetIDs.append(contentsOf: stored.map(\.id))
                    pendingAssets.removeAll(keepingCapacity: true)
                }
                if metadata.errorMessage != nil { failed += 1 }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
            }
        }

        if !pendingAssets.isEmpty {
            let stored = try await repository.upsertAssets(pendingAssets)
            assetIDs.append(contentsOf: stored.map(\.id))
        }

        mutableSource.isOnline = true
        mutableSource.lastScanAt = Date()
        if let identity = try? SourceIdentity.resolve(root), let data = try? JSONEncoder().encode(identity) {
            mutableSource.volumeIdentifier = identity.volume
            mutableSource.directoryIdentityJSON = String(decoding: data, as: UTF8.self)
        }
        if resolved.isStale {
            mutableSource.bookmarkData = try? BookmarkStore.makeBookmark(for: root)
        }
        try await repository.upsertSource(mutableSource)
        await progress?(ScanProgress(discovered: files.count, processed: files.count, currentFile: ""))
        return ScanReport(sourceID: source.id, assetIDs: assetIDs, skippedFiles: skipped, failedFiles: failed)
    }

    private func mediaFiles(under root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isHidden != true else { continue }
            if MediaSupport.kind(for: url) != nil { result.append(url) }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
