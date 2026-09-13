import Foundation
import CoreGraphics
import ImageIO
import JingXuCore

extension CompositionChecks {
    /// Creates a new, isolated review catalog and image pairs outside every Git repository.
    /// Review categories are intentionally blank: no algorithm output is treated as a human label.
    static func reviewFiles(_ directory: URL, output: URL) async throws {
        var parent = output.standardizedFileURL.resolvingSymlinksInPath()
        while parent.path != "/" {
            guard !FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) else {
                throw ColorEditError("构图验收输出必须在 Git 仓库之外")
            }
            parent.deleteLastPathComponent()
        }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ColorEditError("验收输出目录已存在") }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { MediaSupport.kind(for: $0) == .photo }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw ColorEditError("验收目录没有照片") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = try CatalogStore(databaseURL: output.appendingPathComponent("Catalog.sqlite"))
        let source = SourceRoot(name: "构图验收样本", bookmarkData: nil, pathHint: directory.path)
        try await store.upsertSource(source)
        let renderer = ColorImageRenderer()
        struct Review: Codable {
            let name: String, result: String
            let crop: CropAdjustment?
            let regions: [CropAdjustment]
            let width: Int, height: Int
            let seconds: Double
            var humanReview = ""
        }
        var records: [Review] = []
        for (index, file) in files.enumerated() {
            let hash = try FileHasher.sha256(of: file)
            let id = try await PhotoShareChecks.index(file, store: store, source: source)
            let snapshot = try await store.colorSnapshot(assetID: id)
            let start = Date()
            let plain = try await renderer.render(snapshot, adjustments: ColorAdjustments(), maximumDimension: 2048)
            let regions = try await CompositionAnalyzer.shared.regions(in: plain.image)
            let suggestion = try CompositionAnalyzer.suggest(regions: regions, image: plain.nativeSize,
                ratio: plain.nativeSize.width / plain.nativeSize.height)
            var values = ColorAdjustments()
            let result: String
            switch suggestion {
            case .crop(let crop): values.crop = crop; result = "建议裁剪"
            case .keepOriginal: result = "建议保留原构图"
            case .cannotFit: result = "无法容纳主体"
            }
            let seconds = Date().timeIntervalSince(start)
            try await renderer.encode(snapshot, adjustments: ColorAdjustments(), format: .png,
                to: output.appendingPathComponent("\(index)-before.png"), maximumDimension: 1200)
            try await renderer.encode(snapshot, adjustments: values, format: .png,
                to: output.appendingPathComponent("\(index)-suggested.png"), maximumDimension: 1200)
            // Exercise actual native-pixel cropping even when the recommendation is to keep the original.
            values.crop = crop
            let rendered = try await renderer.render(snapshot, adjustments: values)
            for format in ColorExportFormat.allCases {
                let destination = output.appendingPathComponent("\(index)-manual.\(format.fileExtension)")
                try await renderer.encode(snapshot, adjustments: values, format: format, to: destination)
                let src = CGImageSourceCreateWithURL(destination as CFURL, nil)!, decoded = CGImageSourceCreateImageAtIndex(src, 0, nil)!
                try check(decoded.width == rendered.image.width && decoded.height == rendered.image.height, "真实样本裁剪导出尺寸不一致")
                if format == .png { try check(try SRGBPixels(decoded).rgba == SRGBPixels(rendered.image).rgba, "真实样本裁剪预览与 PNG 不一致") }
                if format == .tiff { try check(decoded.bitsPerComponent == 16, "真实样本 TIFF 不是 16 位") }
            }
            try check(try FileHasher.sha256(of: file) == hash, "验收改变原文件")
            let recommended: CropAdjustment? = if case .crop(let crop) = suggestion { crop } else { nil }
            records.append(Review(name: file.lastPathComponent, result: result, crop: recommended,
                regions: regions.map(CropAdjustment.init), width: Int(plain.nativeSize.width), height: Int(plain.nativeSize.height), seconds: seconds))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: output.appendingPathComponent("review.json"), options: .atomic)
        print("已生成 \(files.count) 组构图对比；三种成片格式与原片哈希检查通过。人工评价尚未填写。")
        print(output.path)
        await renderer.release()
    }
}
