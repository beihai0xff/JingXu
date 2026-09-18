import Foundation

/// Owns only an application-created temporary directory, never a Photos library URL.
public final class PhotoWorkspace: Sendable {
    public let directory: URL
    public init(parent: URL) throws {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    /// Called once after the app has acquired its catalog lock. Drafts and journals are outside this directory.
    public static func removeAbandoned(in parent: URL) throws {
        guard FileManager.default.fileExists(atPath: parent.path) else { return }
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw ColorEditError("系统照片工作目录身份无法确认，已停止清理")
        }
        for url in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard UUID(uuidString: url.lastPathComponent) != nil, values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// Validated, lifetime-bound input shared by file and PhotoKit editing.
public struct ColorRenderInput: Sendable {
    public let id: String
    public let url: URL
    public let fingerprint: AnalysisFingerprint
    public let isRAW: Bool
    public let orientation: Int?
    private let fileAccess: ColorSourceAccess?
    public let workspace: PhotoWorkspace?

    public init(local snapshot: ColorEditSnapshot) throws {
        let access = try ColorSourceAccess(snapshot)
        id = snapshot.asset.id; url = access.url; fingerprint = access.fingerprint
        isRAW = snapshot.isRAW; orientation = nil; fileAccess = access; workspace = nil
    }
    public init(id: String, url: URL, workspace: PhotoWorkspace, orientation: Int? = nil) throws {
        if let orientation, !(1...8).contains(orientation) { throw ColorEditError("照片方向信息无效") }
        guard url.deletingLastPathComponent().standardizedFileURL == workspace.directory.standardizedFileURL else {
            throw ColorEditError("照片工作文件不在当前会话目录")
        }
        self.id = id; self.url = url; self.workspace = workspace; self.orientation = orientation
        fingerprint = try AnalysisFingerprint(url: url); isRAW = MediaSupport.isRaw(url); fileAccess = nil
    }
    public func revalidate() throws {
        try ColorSourceAccess.requireSame(fingerprint, AnalysisFingerprint(url: url))
        try fileAccess?.revalidate()
    }
}

public struct ColorEditingSnapshot: Sendable {
    public enum Origin: Sendable {
        case local(ColorEditSnapshot)
        case systemPhoto(SystemPhotoEditInput)
    }
    public let origin: Origin
    public let input: ColorRenderInput
    public let adjustments: ColorAdjustments
    public let revision: Int
    public var id: String { input.id }
    public var isRAW: Bool { input.isRAW }
    public var isSystemPhoto: Bool { if case .systemPhoto = origin { return true }; return false }
    public var usesRenderedBase: Bool { if case .systemPhoto(let input) = origin { return input.usesRenderedBase }; return false }
    public init(local: ColorEditSnapshot) throws {
        origin = .local(local); input = try ColorRenderInput(local: local)
        adjustments = try local.adjustments; revision = local.revision
    }
    public init(systemPhoto: SystemPhotoEditInput, adjustments: ColorAdjustments, revision: Int) {
        origin = .systemPhoto(systemPhoto); input = systemPhoto.renderInput
        self.adjustments = adjustments; self.revision = revision
    }
    public func localSnapshot() throws -> ColorEditSnapshot {
        guard case .local(let value) = origin else { throw ColorEditError("系统照片不能交给本地文件操作") }
        return value
    }
}

public protocol ColorEditingRepository: Sendable {
    func saveColorAdjustments(_ adjustments: ColorAdjustments, snapshot: ColorEditingSnapshot) async throws -> ColorEditingSnapshot
    func validateEditingSnapshot(_ snapshot: ColorEditingSnapshot) async throws
}

extension CatalogStore: ColorEditingRepository {
    public func saveColorAdjustments(_ adjustments: ColorAdjustments, snapshot: ColorEditingSnapshot) throws -> ColorEditingSnapshot {
        try ColorEditingSnapshot(local: saveColorAdjustments(adjustments, snapshot: snapshot.localSnapshot()))
    }
    public func validateEditingSnapshot(_ snapshot: ColorEditingSnapshot) throws {
        try validateColorSnapshot(snapshot.localSnapshot())
    }
}
