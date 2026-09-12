import Foundation
import Darwin

public struct XMPExportItem: Sendable, Identifiable {
    public var id: String { asset.id }
    public let asset: MediaAsset
    public let source: SourceRoot
    public let annotation: UserAnnotation
    public let destination: URL
}
public struct XMPExportPlan: Sendable, Identifiable {
    public let id = UUID()
    public var items: [XMPExportItem] = []
    public var skipped: [String] = []
    public var failed: [String] = []
    public init() {}
}
public struct XMPExportReport: Sendable {
    public var written: [URL] = []
    public var skipped: [String] = []
    public var failed: [String] = []
    public var cancelled = false
    public var summary: String { "XMP：写入 \(written.count)，跳过 \(skipped.count)，失败 \(failed.count)" + (cancelled ? "；已取消后续项目" : "") }
}

/// Sidecars are only created. Existing files, including dangling links, are never replaced.
public actor DefaultXMPExporter {
    private let repository: any CatalogRepository
    private var running = false
    public init(repository: any CatalogRepository) { self.repository = repository }

    private static func occupied(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
    public func prepare(assetIDs: [String]) async throws -> XMPExportPlan {
        var plan = XMPExportPlan()
        for id in Set(assetIDs).sorted() {
            try Task.checkCancellation()
            do {
                guard let asset = try await repository.asset(id: id), asset.kind == .photo,
                      let source = try await repository.source(id: asset.sourceID) else { throw ColorEditError("照片或来源不存在") }
                let access = try ColorSourceAccess(ColorEditSnapshot(asset: asset, source: source, record: nil))
                let target = access.url.deletingPathExtension().appendingPathExtension("xmp")
                if try Self.occupied(target) { plan.skipped.append("\(asset.fileName)：XMP 已存在"); continue }
                plan.items.append(XMPExportItem(asset: asset, source: source,
                    annotation: try await repository.annotation(for: id), destination: target))
            } catch is CancellationError { throw CancellationError() }
            catch { plan.failed.append("\(id)：\(error.localizedDescription)") }
        }
        let groups = Dictionary(grouping: plan.items) {
            $0.destination.path.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let conflicts = Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
        for item in plan.items where conflicts.contains(item.id) { plan.skipped.append("\(item.asset.fileName)：多个照片对应同一 XMP，全部跳过") }
        plan.items.removeAll { conflicts.contains($0.id) }
        return plan
    }
    public func execute(_ plan: XMPExportPlan,
        beforeCommit: (@Sendable (URL) async throws -> Void)? = nil) async throws -> XMPExportReport {
        guard !running else { throw ColorEditError("XMP 导出正在执行") }
        running = true; defer { running = false }
        var report = XMPExportReport(); report.skipped = plan.skipped; report.failed = plan.failed
        for item in plan.items {
            if Task.isCancelled { report.cancelled = true; break }
            var temporary: URL?
            defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
            do {
                guard try await repository.asset(id: item.id) == item.asset,
                      try await repository.source(id: item.source.id) == item.source else { throw ColorEditError("照片或来源已变化，请重新生成清单") }
                let annotation = try await repository.annotation(for: item.id)
                guard annotation.rating == item.annotation.rating, annotation.flag == item.annotation.flag,
                      annotation.keywords == item.annotation.keywords else { throw ColorEditError("标注已变化，请重新生成清单") }
                let access = try ColorSourceAccess(ColorEditSnapshot(asset: item.asset, source: item.source, record: nil))
                defer { withExtendedLifetime(access) {} }
                guard access.url.deletingPathExtension().appendingPathExtension("xmp") == item.destination else { throw ColorEditError("目标路径已变化") }
                if try Self.occupied(item.destination) { report.skipped.append("\(item.asset.fileName)：XMP 已存在"); continue }
                let temp = item.destination.deletingLastPathComponent().appendingPathComponent(".jingxu-xmp-\(UUID().uuidString).tmp")
                temporary = temp
                try Data(Self.document(asset: item.asset, annotation: item.annotation).utf8).write(to: temp, options: .withoutOverwriting)
                try await beforeCommit?(item.destination)
                try Task.checkCancellation()
                _ = try ColorSourceAccess(ColorEditSnapshot(asset: item.asset, source: item.source, record: nil))
                try access.revalidate()
                let latest = try await repository.annotation(for: item.id)
                guard latest.rating == annotation.rating, latest.flag == annotation.flag, latest.keywords == annotation.keywords else { throw ColorEditError("标注已变化，请重新生成清单") }
                if renamex_np(temp.path, item.destination.path, UInt32(RENAME_EXCL)) != 0 {
                    let code = errno
                    if code == EEXIST { report.skipped.append("\(item.asset.fileName)：目标已存在"); continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                report.written.append(item.destination)
            } catch is CancellationError { report.cancelled = true; break }
            catch { report.failed.append("\(item.asset.fileName)：\(error.localizedDescription)") }
        }
        return report
    }
    public static func document(asset: MediaAsset, annotation: UserAnnotation) -> String {
        let escapedKeywords = annotation.keywords.map { "<rdf:li>\(escape($0))</rdf:li>" }.joined()
        let label: String
        switch annotation.flag {
        case .none: label = ""
        case .rejected: label = "Reject"
        }
        return """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmp:Rating="\(annotation.rating)" xmp:Label="\(label)">
              <dc:subject><rdf:Bag>\(escapedKeywords)</rdf:Bag></dc:subject>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
