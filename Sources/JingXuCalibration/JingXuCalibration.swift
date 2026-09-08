import CryptoKit
import Darwin
import Foundation
import GRDB
import ImageIO
import JingXuCore
import UniformTypeIdentifiers

private struct Sample: Codable {
    var assetID: String
    var groupID: String
    var split: String
    var stratum: String
    var filePath: String
    var fingerprint: AnalysisFingerprint?
    var diagnostic: QualityDiagnosticSummary?
    var error: String?
    var accessNote: String?
}
private struct Manifest: Codable {
    var schema = 1
    var createdAt = Date()
    var algorithmVersion = 2
    var parameterDigest: String
    var samples: [Sample]
}
private struct LabelEntry: Codable {
    var assetID: String
    var label: CalibrationLabel?
    var reviewedAt100Percent = false
}
private struct Frozen: Codable {
    var manifestDigest: String
    var calibrationLabelsDigest: String
    var parameters: QualityParameters
    var calibrationCounts: CalibrationCounts
}
private struct LocalError: Error, CustomStringConvertible { var description: String }

@main
enum JingXuCalibration {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { print(usage); return }
        func argument(_ key: String) throws -> String {
            guard let index = args.firstIndex(of: key), args.indices.contains(index+1) else { throw LocalError(description: "缺少 \(key)\n\(usage)") }
            return args[index+1]
        }
        switch command {
        case "prepare":
            let catalog = URL(fileURLWithPath: try argument("--catalog"))
            let output = URL(fileURLWithPath: try argument("--output"))
            let count = (try? Int(argument("--count"))) ?? 120
            try await prepare(catalog: catalog, output: output, count: min(150, max(100, count)))
        case "calibrate", "evaluate":
            let directory = URL(fileURLWithPath: try argument("--directory"))
            try evaluate(directory: directory, calibrate: command == "calibrate")
        default: throw LocalError(description: usage)
        }
    }

    static let usage = """
    私有校准（所有输出必须位于 Git 仓库外；不写图库，不更改应用参数）
    JingXuCalibration prepare --catalog <Catalog.sqlite> --output <新建私有目录> [--count 120]
    人工按 review.html 说明，在 100% 下填写 labels.json；不得以旧分数作为答案。
    JingXuCalibration calibrate --directory <私有目录>  # 仅使用 calibration 分区，冻结参数
    JingXuCalibration evaluate --directory <私有目录>   # 独立 validation 分区，只评估一次
    """

    static func privateDirectory(_ url: URL) throws {
        var path = url.standardizedFileURL.resolvingSymlinksInPath()
        while path.path != "/" {
            if FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path) {
                throw LocalError(description: "拒绝将照片、路径或人工标签写入 Git 仓库")
            }
            path.deleteLastPathComponent()
        }
    }
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw LocalError(description: "目标已存在，未覆盖：\(url.lastPathComponent)") }
        try encoded(value).write(to: url, options: .atomic)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func prepare(catalog: URL, output: URL, count: Int) async throws {
        try privateDirectory(output)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw LocalError(description: "请使用新的私有目录，避免覆盖人工标签") }
        // Intentionally NOT CatalogStore: it would migrate an existing user's catalog.
        var configuration = Configuration(); configuration.readonly = true
        let reader = try DatabaseQueue(path: catalog.path, configuration: configuration)
        let (assets, sources, analysis) = try await reader.read { db in
            (try MediaAsset.filter(Column("kind") == "photo").fetchAll(db),
             try SourceRoot.fetchAll(db), try AnalysisResult.fetchAll(db, sql: "SELECT assetID, algorithmVersion, sharpnessScore, shadowClipping, highlightClipping, NULL AS featurePrint, issuesJSON, suggestionState, similarGroupID, analyzedAt FROM analysisResults"))
        }
        try reader.close()
        let analysisByID = Dictionary(uniqueKeysWithValues: analysis.map { ($0.assetID, $0) })
        let sourcesByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        let ordered = assets.sorted { ($0.capturedAt ?? $0.modifiedAt, $0.id) < ($1.capturedAt ?? $1.modifiedAt, $1.id) }
        // Union existing burst groups and adjacent same-camera captures. Connected groups never cross partitions.
        var parent = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.id) })
        func find(_ id: String) -> String {
            var current = id
            while parent[current] != current { current = parent[current]! }
            return current
        }
        func union(_ a: String, _ b: String) { let left = find(a), right = find(b); parent[max(left,right)] = min(left,right) }
        var firstInBurst: [String: String] = [:]
        var lastForCamera: [String: MediaAsset] = [:]
        for asset in ordered {
            if let group = analysisByID[asset.id]?.similarGroupID {
                if let first = firstInBurst[group] { union(first,asset.id) } else { firstInBurst[group] = asset.id }
            }
            let camera = asset.cameraModel ?? "unknown"
            if let previous = lastForCamera[camera], (asset.capturedAt ?? asset.modifiedAt).timeIntervalSince(previous.capturedAt ?? previous.modifiedAt) <= 2 { union(previous.id,asset.id) }
            lastForCamera[camera] = asset
        }
        let scores = analysis.map(\.sharpnessScore).sorted()
        let low = scores.isEmpty ? 0 : scores[scores.count/3], high = scores.isEmpty ? 0 : scores[scores.count*2/3]
        let dateFormat = DateFormatter(); dateFormat.dateFormat = "yyyy-MM-dd"; dateFormat.timeZone = TimeZone(secondsFromGMT: 0)
        func stratum(_ asset: MediaAsset) -> String {
            let old = analysisByID[asset.id]
            let score = old?.sharpnessScore ?? 0
            let band = old == nil ? "unanalysed" : (score <= low ? "low" : (score <= high ? "middle" : "high"))
            let brightness = (old?.shadowClipping ?? 0) > 0.3 ? "dark" : ((old?.highlightClipping ?? 0) > 0.18 ? "bright" : "middle")
            let format = URL(fileURLWithPath: asset.fileName).pathExtension.lowercased()
            return "\(band)/\(brightness)/\(format)/\(dateFormat.string(from: asset.capturedAt ?? asset.modifiedAt))"
        }
        var buckets = Dictionary(grouping: ordered, by: stratum).mapValues { $0.sorted { digest(Data($0.id.utf8)) < digest(Data($1.id.utf8)) } }
        let keys = buckets.keys.sorted()
        var chosen: [MediaAsset] = [], seen = Set<String>(), perGroup: [String: Int] = [:]
        for cap in [3, Int.max] {
            var madeProgress = true
            while chosen.count < count && madeProgress {
                madeProgress = false
                for key in keys where chosen.count < count {
                    guard let index = buckets[key]?.firstIndex(where: { !seen.contains($0.id) && perGroup[find($0.id), default: 0] < cap }) else { continue }
                    let asset = buckets[key]!.remove(at: index)
                    chosen.append(asset); seen.insert(asset.id); perGroup[find(asset.id), default: 0] += 1; madeProgress = true
                }
            }
        }
        let groups = Dictionary(grouping: chosen, by: { find($0.id) })
        var splits: [String: String] = [:], calibrationCount = 0
        for group in groups.keys.sorted(by: { digest(Data($0.utf8)) < digest(Data($1.utf8)) }) {
            let isCalibration = calibrationCount < chosen.count * 2 / 3
            splits[group] = isCalibration ? "calibration" : "validation"
            if isCalibration { calibrationCount += groups[group]!.count }
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let previews = output.appendingPathComponent("previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let started = Date(), analyzer = DefaultQualityAnalyzer(featureExtractor: { _ in nil })
        var samples: [Sample] = []
        for (index, asset) in chosen.enumerated() {
            try Task.checkCancellation()
            var sample = Sample(assetID: asset.id, groupID: find(asset.id), split: splits[find(asset.id)]!, stratum: stratum(asset), filePath: "")
            do {
                guard let source = sourcesByID[asset.sourceID] else { throw CocoaError(.fileReadNoSuchFile) }
                let root: URL
                do { root = try BookmarkStore.resolve(source).url }
                catch {
                    // A command-line tool cannot necessarily resolve another app's sandbox bookmark.
                    // The user explicitly authorized local read-only sampling; verify the indexed file below.
                    root = URL(fileURLWithPath: source.pathHint, isDirectory: true)
                    sample.accessNote = "命令行无法复用应用书签；通过已有本机读取权限与索引文件指纹复核"
                }
                let access = root.startAccessingSecurityScopedResource()
                defer { if access { root.stopAccessingSecurityScopedResource() } }
                let url = root.appendingPathComponent(asset.relativePath)
                guard url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.starts(with: root.standardizedFileURL.resolvingSymlinksInPath().pathComponents) else { throw QualityAnalysisError.unsafePath }
                sample.filePath = url.path
                guard AnalysisFingerprint(asset: asset).matches(try AnalysisFingerprint(url: url)) else { throw QualityAnalysisError.changedFile }
                let result = try await analyzer.analyze(assetID: asset.id, at: url)
                sample.fingerprint = result.fingerprint; sample.diagnostic = result.diagnostic
                let preview = try DecodedPreview.image(at: url)
                if let target = CGImageDestinationCreateWithURL(previews.appendingPathComponent("\(index+1).jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(target, preview, nil)
                    if !CGImageDestinationFinalize(target) { throw CocoaError(.fileWriteUnknown) }
                }
            } catch { sample.error = error.localizedDescription }
            samples.append(sample)
            print("私有抽样 \(index+1)/\(chosen.count)\(sample.error == nil ? "" : "（不可用，已记录）")")
            fflush(stdout)
        }
        let manifest = Manifest(parameterDigest: QualityParameters().digest, samples: samples)
        let data = try encoded(manifest)
        try data.write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        try write(digest(data), to: output.appendingPathComponent("manifest-digest.json"))
        try write(samples.map { LabelEntry(assetID: $0.assetID) }, to: output.appendingPathComponent("labels.json"))
        try reviewHTML(samples).write(to: output.appendingPathComponent("review.html"), atomically: true, encoding: .utf8)
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let reasons = samples.compactMap(\.diagnostic).map { $0.decision(using: QualityParameters()).0.rawValue }
        let report: [String: String] = [
            "status": "待人工确认；报警未启用；未执行参数选择或独立验证",
            "samples": "\(samples.count)", "calibration": "\(samples.filter { $0.split == "calibration" }.count)",
            "validation": "\(samples.filter { $0.split == "validation" }.count)", "groups": "\(groups.count)",
            "decodeFailures": "\(samples.filter { $0.error != nil }.count)",
            "unableToJudge": "\(reasons.filter { $0 == QualityAssessmentStatus.insufficientEvidence.rawValue }.count + samples.filter { $0.diagnostic == nil }.count)",
            "elapsedSeconds": String(format: "%.2f", Date().timeIntervalSince(started)),
            "peakMemoryMiB": String(format: "%.1f", Double(usage.ru_maxrss) / 1048576),
            "humanLabels": "0", "falsePositiveRate": "未测量", "recall": "未测量",
            "limitations": "旧分数仅用于分层，不是真值。代表性由人工检查；真实 RAW 100% 合焦及界面响应待人工验收。"
        ]
        try write(report, to: output.appendingPathComponent("calibration-report.json"))
        print("完成。清单与报告仅保存在指定私有目录；原图库未写入。")
    }

    static func evaluate(directory: URL, calibrate: Bool) throws {
        try privateDirectory(directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let hash = digest(data)
        let expected = try JSONDecoder().decode(String.self, from: Data(contentsOf: directory.appendingPathComponent("manifest-digest.json")))
        guard expected == hash else { throw LocalError(description: "抽样清单已改变，拒绝混用验证数据") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schema == 1, manifest.algorithmVersion == 2, manifest.parameterDigest == QualityParameters().digest else { throw LocalError(description: "指标算法或参数已变化，请重新抽样") }
        let groups = Dictionary(grouping: manifest.samples, by: \.groupID)
        guard groups.values.allSatisfy({ Set($0.map(\.split)).count == 1 }) else { throw LocalError(description: "同一拍摄组跨越分区，验证无效") }
        let labels = try JSONDecoder().decode([LabelEntry].self, from: Data(contentsOf: directory.appendingPathComponent("labels.json")))
        guard Set(labels.map(\.assetID)).count == labels.count else { throw LocalError(description: "人工标签 ID 重复") }
        let byID = Dictionary(uniqueKeysWithValues: labels.map { ($0.assetID, $0) })
        let split = calibrate ? "calibration" : "validation"
        let selected = manifest.samples.filter { $0.split == split }
        guard !selected.isEmpty, selected.allSatisfy({ byID[$0.assetID]?.label != nil && byID[$0.assetID]?.reviewedAt100Percent == true }) else {
            throw LocalError(description: "\(split) 分区尚未完成人工 100% 确认；不生成已验证参数，报警保持关闭")
        }
        for sample in selected {
            guard let fingerprint = sample.fingerprint,
                  fingerprint.matches(try AnalysisFingerprint(url: URL(fileURLWithPath: sample.filePath))) else {
                throw LocalError(description: "人工确认的原文件不可用或已变化，不能把当前标签套用到旧指标")
            }
        }
        let observations = selected.map { CalibrationObservation(label: byID[$0.assetID]!.label!, diagnostic: $0.diagnostic) }
        let frozenURL = directory.appendingPathComponent("frozen-parameters.json")
        let validationURL = directory.appendingPathComponent("validation-report.json")
        if calibrate {
            guard !FileManager.default.fileExists(atPath: validationURL.path) else { throw LocalError(description: "已查看独立验证结果，不能再用同一验证集调参") }
            guard let parameters = QualityCalibration.selectParameters(calibration: observations) else { throw LocalError(description: "校准样本不足或无满足低误报要求的参数；报警保持关闭") }
            let calibrationLabels = labels.filter { entry in selected.contains { $0.assetID == entry.assetID } }.sorted { $0.assetID < $1.assetID }
            try write(Frozen(manifestDigest: hash, calibrationLabelsDigest: digest(encoded(calibrationLabels)), parameters: parameters,
                calibrationCounts: QualityCalibration.measure(observations, parameters: parameters)), to: frozenURL)
            print("仅校准集参与选参，参数已冻结。下一步 evaluate；应用报警仍关闭。")
        } else {
            let frozen = try JSONDecoder().decode(Frozen.self, from: Data(contentsOf: frozenURL))
            guard frozen.manifestDigest == hash else { throw LocalError(description: "冻结参数不属于此清单") }
            let calibrationIDs = Set(manifest.samples.filter { $0.split == "calibration" }.map(\.assetID))
            let calibrationLabels = labels.filter { calibrationIDs.contains($0.assetID) }.sorted { $0.assetID < $1.assetID }
            guard frozen.calibrationLabelsDigest == digest(try encoded(calibrationLabels)) else { throw LocalError(description: "参数冻结后校准标签发生变化，验证无效") }
            let counts = QualityCalibration.measure(observations, parameters: frozen.parameters)
            try write(counts, to: validationURL)
            var parameters = frozen.parameters
            parameters.validation = QualityValidationEvidence(parameterDigest: parameters.digest, usableCount: counts.usable,
                falsePositives: counts.falsePositives, blurryCount: counts.blurry, truePositives: counts.truePositives,
                humanLabelsComplete: true, independentHoldout: true)
            try write(parameters, to: directory.appendingPathComponent("evaluated-parameters.json"))
            let scenarios = Dictionary(grouping: selected, by: \.stratum).mapValues { group in
                QualityCalibration.measure(group.map { CalibrationObservation(label: byID[$0.assetID]!.label!, diagnostic: $0.diagnostic) }, parameters: frozen.parameters)
            }
            try write(scenarios, to: directory.appendingPathComponent("validation-scenarios.json"))
            print(parameters.warningsEnabled ? "独立验证达到数值目标。仍需人工审查代表性；配置仅写入私有目录，未启用应用报警。" : "独立验证未达标或样本不足；报警保持关闭。")
        }
    }

    private static func reviewHTML(_ samples: [Sample]) -> String {
        func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
        let items = samples.enumerated().map { index, sample in
            """
            <article><h2>样本 \(index+1)</h2><img loading="lazy" src="previews/\(index+1).jpg" alt="解码预览"><p>\(escape(sample.filePath))</p><p>标签 ID：<code>\(escape(sample.assetID))</code></p><a href="\(escape(URL(fileURLWithPath: sample.filePath).absoluteString))">原文件（请在本机查看器中以 100% 确认）</a></article>
            """
        }.joined(separator: "\n")
        return """
        <!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>镜序私有质量校准</title>
        <style>body{font:16px -apple-system,sans-serif;background:#16191e;color:#eee;margin:32px;max-width:1000px}article{padding:24px 0;border-top:1px solid #444}img{max-width:100%;max-height:600px}p{overflow-wrap:anywhere}a{color:#8fc7ff}code{user-select:all}</style>
        <h1>私有对照清单</h1><p>下面仅是定向解码预览，不能代替原图 100% 查看。请在镜序／系统可解码的本机查看器中确认原文件：usable＝可用，blurry＝明显模糊，uncertain＝不确定。在 labels.json 中填写 label，并将 reviewedAt100Percent 设为 true。</p>
        <p>页面刻意不显示旧分数、新指标及分区，避免诱导人工答案。遇到系统无法解码的 RAW 不要猜测，保留未标注并记录原因。标注不必迎合算法，噪点、虚化背景和创作性曝光不自动等于不可用。不得上传此文件夹。</p>
        \(items)</html>
        """
    }
}
