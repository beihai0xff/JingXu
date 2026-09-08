import Foundation

public struct ImportProgress: Sendable, Equatable {
    public var totalFiles: Int
    public var completedFiles: Int
    public var skippedFiles: Int
    public var failedFiles: Int
    public var currentFile: String

    public init(totalFiles: Int, completedFiles: Int, skippedFiles: Int, failedFiles: Int, currentFile: String) {
        self.totalFiles = totalFiles
        self.completedFiles = completedFiles
        self.skippedFiles = skippedFiles
        self.failedFiles = failedFiles
        self.currentFile = currentFile
    }
}

public struct ImportReport: Sendable, Equatable {
    public var session: ImportSession
    public var destination: URL
    public var source: SourceRoot?
    public var scanReport: ScanReport?

    public init(session: ImportSession, destination: URL, source: SourceRoot?, scanReport: ScanReport?) {
        self.session = session
        self.destination = destination
        self.source = source
        self.scanReport = scanReport
    }
}

public typealias ImportProgressHandler = @Sendable (ImportProgress) async -> Void

public protocol Importing: Sendable {
    func importMedia(
        from sourceURL: URL,
        to destinationRoot: URL,
        batchName: String,
        progress: ImportProgressHandler?
    ) async throws -> ImportReport
}

public actor ImportCoordinator: Importing {
    private let repository: any CatalogRepository
    private let scanner: any SourceScanner
    private let fileManager: FileManager

    public init(repository: any CatalogRepository, scanner: any SourceScanner, fileManager: FileManager = .default) {
        self.repository = repository
        self.scanner = scanner
        self.fileManager = fileManager
    }

    public func importMedia(
        from sourceURL: URL,
        to destinationRoot: URL,
        batchName: String,
        progress: ImportProgressHandler? = nil
    ) async throws -> ImportReport {
        let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
        let destinationAccess = destinationRoot.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
            if destinationAccess { destinationRoot.stopAccessingSecurityScopedResource() }
        }

        let relativeFolder = ImportNaming.destinationFolder(date: Date(), batchName: batchName)
        let destination = destinationRoot.appendingPathComponent(relativeFolder, isDirectory: true)
        let files = mediaFiles(under: sourceURL)
        let totalBytes = try files.reduce(Int64(0)) { partial, url in
            partial + Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        try verifyCapacity(for: totalBytes, at: destinationRoot)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var session = ImportSession(
            sourcePath: sourceURL.path,
            destinationPath: destination.path,
            batchName: batchName,
            status: .running,
            totalFiles: files.count
        )
        try await repository.saveImportSession(session)

        do {
            for fileURL in files {
                try Task.checkCancellation()
                await progress?(ImportProgress(
                    totalFiles: files.count,
                    completedFiles: session.completedFiles,
                    skippedFiles: session.skippedFiles,
                    failedFiles: session.failedFiles,
                    currentFile: fileURL.lastPathComponent
                ))
                do {
                    let outcome = try safeCopy(fileURL, into: destination)
                    switch outcome {
                    case .copied: session.completedFiles += 1
                    case .skipped: session.skippedFiles += 1
                    }
                } catch {
                    session.failedFiles += 1
                    session.errorMessage = error.localizedDescription
                }
                session.updatedAt = Date()
                try await repository.saveImportSession(session)
            }

            let source = try await repository.registerSource(at: destination)
            let scanReport = try await scanner.scan(source: source, progress: nil)
            session.status = session.failedFiles == 0 ? .completed : .failed
            session.updatedAt = Date()
            try await repository.saveImportSession(session)
            await progress?(ImportProgress(
                totalFiles: files.count,
                completedFiles: session.completedFiles,
                skippedFiles: session.skippedFiles,
                failedFiles: session.failedFiles,
                currentFile: ""
            ))
            return ImportReport(session: session, destination: destination, source: source, scanReport: scanReport)
        } catch is CancellationError {
            session.status = .cancelled
            session.updatedAt = Date()
            try? await repository.saveImportSession(session)
            throw CancellationError()
        } catch {
            session.status = .failed
            session.errorMessage = error.localizedDescription
            session.updatedAt = Date()
            try? await repository.saveImportSession(session)
            throw error
        }
    }

    private enum CopyOutcome {
        case copied
        case skipped
    }

    private func safeCopy(_ source: URL, into directory: URL) throws -> CopyOutcome {
        let sourceHash = try FileHasher.sha256(of: source)
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            if try FileHasher.sha256(of: destination) == sourceHash { return .skipped }
            destination = availableDestination(for: source, in: directory)
        }

        let partial = directory.appendingPathComponent(".\(destination.lastPathComponent).jingxu-partial")
        if fileManager.fileExists(atPath: partial.path) { try fileManager.removeItem(at: partial) }
        do {
            try fileManager.copyItem(at: source, to: partial)
            guard try FileHasher.sha256(of: partial) == sourceHash else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try fileManager.moveItem(at: partial, to: destination)
            return .copied
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private func availableDestination(for source: URL, in directory: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var index = 2
        while true {
            let name = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func verifyCapacity(for bytes: Int64, at destination: URL) throws {
        let values = try destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let capacity = values.volumeAvailableCapacityForImportantUsage, capacity < bytes + 512 * 1_024 * 1_024 {
            throw CocoaError(.fileWriteOutOfSpace)
        }
    }

    private func mediaFiles(under root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, MediaSupport.kind(for: url) != nil else { return nil }
            return url
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
