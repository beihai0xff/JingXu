import Foundation
import Darwin

public struct ColorExportItem: Sendable, Identifiable {
    public var id: String { snapshot.asset.id }
    public let snapshot: ColorEditSnapshot
    public let adjustments: ColorAdjustments
    public let destination: URL
}
public struct ColorExportPlan: Sendable, Identifiable {
    public let id = UUID()
    public let directory: URL
    public let identity: SourceIdentity
    public let format: ColorExportFormat
    public var items: [ColorExportItem] = []
    public var skipped: [String] = []
}
public struct ColorExportReport: Sendable {
    public var written: [URL] = []
    public var skipped: [String] = []
    public var failed: [String] = []
    public var cancelled = false
    public init() {}
}

public actor ColorExportCoordinator {
    public typealias Encoder = @Sendable (ColorEditSnapshot, ColorAdjustments, ColorExportFormat, URL) async throws -> Void
    private let store: CatalogStore
    private let encode: Encoder
    private var running = false
    public init(store: CatalogStore, encode: Encoder? = nil) {
        self.store = store
        self.encode = encode ?? { snapshot, adjustments, format, url in
            try await ColorImageRenderer.shared.encode(snapshot, adjustments: adjustments, format: format, to: url)
        }
    }

    public func prepare(assetIDs: [String], directory: URL, format: ColorExportFormat) async throws -> ColorExportPlan {
        let lease = PreviewAccessLease(url: directory)
        defer { withExtendedLifetime(lease) {} }
        var plan = ColorExportPlan(directory: directory, identity: try SourceIdentity.resolve(directory), format: format)
        var targets = Set<String>()
        for id in Array(Set(assetIDs)).sorted() {
            try Task.checkCancellation()
            do {
                let snapshot = try await store.colorSnapshot(assetID: id)
                let adjustments = try snapshot.adjustments
                _ = try await ColorImageRenderer.shared.render(snapshot, adjustments: adjustments, maximumDimension: 64)
                let stem = (snapshot.asset.fileName as NSString).deletingPathExtension
                let destination = directory.appendingPathComponent(stem + "-调色." + format.fileExtension)
                let key = destination.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard targets.insert(key).inserted else { plan.skipped.append("\(snapshot.asset.fileName)：批次目标重名"); continue }
                guard !Self.exists(destination) else { plan.skipped.append("\(destination.lastPathComponent)：目标已存在"); continue }
                plan.items.append(ColorExportItem(snapshot: snapshot, adjustments: adjustments, destination: destination))
            } catch is CancellationError { throw CancellationError() }
            catch { plan.skipped.append("\((try? await store.asset(id: id))?.fileName ?? id)：\(error.localizedDescription)") }
        }
        return plan
    }

    public func execute(_ plan: ColorExportPlan, progress: @Sendable (Int, Int) async -> Void = { _,_ in }) async throws -> ColorExportReport {
        guard !running else { throw ColorEditError("导出正在执行") }
        running = true
        let lease = PreviewAccessLease(url: plan.directory)
        defer { running = false; withExtendedLifetime(lease) {} }
        guard try SourceIdentity.resolve(plan.directory) == plan.identity else { throw ColorEditError("导出目录已变化") }
        var report = ColorExportReport(); report.skipped = plan.skipped
        for (index, item) in plan.items.enumerated() {
            if Task.isCancelled { report.cancelled = true; break }
            let temporary = plan.directory.appendingPathComponent(".jingxu-export-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                guard item.destination.deletingLastPathComponent().standardizedFileURL.pathComponents == plan.directory.standardizedFileURL.pathComponents,
                      try SourceIdentity.resolve(plan.directory) == plan.identity else { throw ColorEditError("导出目标越界或目录已变化") }
                try await store.validateColorSnapshot(item.snapshot)
                if Self.exists(item.destination) { report.skipped.append("\(item.destination.lastPathComponent)：目标已存在"); continue }
                try await encode(item.snapshot, item.adjustments, plan.format, temporary)
                try Task.checkCancellation()
                try await store.validateColorSnapshot(item.snapshot)
                guard try SourceIdentity.resolve(plan.directory) == plan.identity else { throw ColorEditError("导出目录已变化") }
                // Atomic no-replace publication on the destination volume, including symlink conflicts.
                if renamex_np(temporary.path, item.destination.path, UInt32(RENAME_EXCL)) != 0 {
                    let code = errno
                    if code == EEXIST { report.skipped.append("\(item.destination.lastPathComponent)：目标已存在"); continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                report.written.append(item.destination)
            } catch is CancellationError { report.cancelled = true; break }
            catch { report.failed.append("\(item.snapshot.asset.fileName)：\(error.localizedDescription)") }
            await progress(index + 1, plan.items.count)
        }
        return report
    }
    private static func exists(_ url: URL) -> Bool {
        // lstat also sees dangling symlinks. Other errors are checked again by no-replace publication.
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}
