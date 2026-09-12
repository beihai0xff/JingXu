import Foundation

public struct ImportIssue: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable { case directory = "读取目录", grouping = "确认配对", copy = "复制文件", index = "建立索引" }
    public let path: String
    public let stage: Stage
    public let reason: String
}
public struct ImportFile: Codable, Sendable, Equatable {
    public let relativePath: String
    public let destinationName: String
    public let fingerprint: AnalysisFingerprint
    public let hash: String
    public let existingFingerprint: AnalysisFingerprint?
    public var isDuplicate: Bool { existingFingerprint != nil }
}
public struct ImportGroup: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let files: [ImportFile]
}
public struct ImportPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sourceRoot: SourceRoot
    public let targetRoot: SourceRoot
    public let sourceIdentity: SourceIdentity
    public let targetIdentity: SourceIdentity
    public let relativeFolder: String
    public let existingDirectories: [String: SourceIdentity]
    public let batchName: String
    public let groups: [ImportGroup]
    public let issues: [ImportIssue]
    public var destination: URL { URL(fileURLWithPath: targetRoot.pathHint).appendingPathComponent(relativeFolder) }
    public var totalFiles: Int { groups.reduce(0) { $0 + $1.files.count } }
    public var duplicateFiles: Int { groups.reduce(0) { $0 + $1.files.filter(\.isDuplicate).count } }
    public var bytesToCopy: Int64 { groups.flatMap(\.files).filter { !$0.isDuplicate }.reduce(0) { $0 + $1.fingerprint.size } }
}
public struct ImportProgress: Sendable, Equatable {
    public var totalFiles: Int
    public var completedFiles: Int
    public var skippedFiles: Int
    public var failedFiles: Int
    public var currentFile: String
}
public struct ImportReport: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable { case running = "正在导入", completed = "导入完成", partial = "部分完成", cancelled = "已取消", failed = "导入失败", interrupted = "未完成" }
    public var id: String { plan.id }
    public let plan: ImportPlan
    public var session: ImportSession
    public var outcome: Outcome = .running
    public var issues: [ImportIssue]
    public var source: SourceRoot?
    public var scanReport: ScanReport?
    public var destination: URL { plan.destination }
    public var progress: ImportProgress {
        .init(totalFiles: session.totalFiles, completedFiles: session.completedFiles, skippedFiles: session.skippedFiles, failedFiles: session.failedFiles, currentFile: "")
    }
}
public typealias ImportProgressHandler = @Sendable (ImportProgress) async -> Void
public protocol Importing: Sendable {
    func prepare(from source: URL, to target: URL, batchName: String) async throws -> ImportPlan
    func prepareRetry(_ report: ImportReport) async throws -> ImportPlan
    func execute(_ plan: ImportPlan, progress: ImportProgressHandler?) async throws -> ImportReport
}
