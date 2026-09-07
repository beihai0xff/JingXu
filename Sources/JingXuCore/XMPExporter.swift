import Foundation

public enum XMPConflictPolicy: Sendable {
    case skip
    case replace
}

public struct XMPExportReport: Sendable, Equatable {
    public var written: [URL]
    public var skipped: [URL]
    public var failed: [URL: String]

    public init(written: [URL] = [], skipped: [URL] = [], failed: [URL: String] = [:]) {
        self.written = written
        self.skipped = skipped
        self.failed = failed
    }
}

public protocol XMPExporter: Sendable {
    func export(assetIDs: [String], conflictPolicy: XMPConflictPolicy) async throws -> XMPExportReport
}

public struct DefaultXMPExporter: XMPExporter {
    private let repository: any CatalogRepository

    public init(repository: any CatalogRepository) {
        self.repository = repository
    }

    public func export(assetIDs: [String], conflictPolicy: XMPConflictPolicy = .skip) async throws -> XMPExportReport {
        var report = XMPExportReport()
        for assetID in assetIDs {
            guard let asset = try await repository.asset(id: assetID),
                  let source = try await repository.source(id: asset.sourceID) else { continue }
            let root = try BookmarkStore.resolve(source).url
            let didAccess = root.startAccessingSecurityScopedResource()
            defer { if didAccess { root.stopAccessingSecurityScopedResource() } }
            let assetURL = root.appendingPathComponent(asset.relativePath)
            let xmpURL = assetURL.deletingPathExtension().appendingPathExtension("xmp")
            if FileManager.default.fileExists(atPath: xmpURL.path), conflictPolicy == .skip {
                report.skipped.append(xmpURL)
                continue
            }
            do {
                let annotation = try await repository.annotation(for: asset.id)
                let xml = Self.document(asset: asset, annotation: annotation)
                try Data(xml.utf8).write(to: xmpURL, options: .atomic)
                report.written.append(xmpURL)
            } catch {
                report.failed[xmpURL] = error.localizedDescription
            }
        }
        return report
    }

    public static func document(asset: MediaAsset, annotation: UserAnnotation) -> String {
        let escapedKeywords = annotation.keywords.map { "<rdf:li>\(escape($0))</rdf:li>" }.joined()
        let label: String
        switch annotation.flag {
        case .none: label = ""
        case .picked: label = "Pick"
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
