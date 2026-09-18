import Foundation
import CoreGraphics

public enum SystemPhotoAuthorization: Sendable {
    case notDetermined, authorized, limited, denied, restricted
    public var canRead: Bool { self == .authorized || self == .limited }
}

public struct SystemPhoto: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let modifiedAt: Date?
    public let capturedAt: Date?
    public let width: Int
    public let height: Int
    public let isLivePhoto: Bool
    public let canEdit: Bool
    public let canDelete: Bool
    public init(id: String, name: String, modifiedAt: Date? = nil, capturedAt: Date? = nil,
                width: Int = 0, height: Int = 0, isLivePhoto: Bool = false, canEdit: Bool = true, canDelete: Bool = true) {
        self.id = id; self.name = name; self.modifiedAt = modifiedAt; self.capturedAt = capturedAt
        self.width = width; self.height = height; self.isLivePhoto = isLivePhoto
        self.canEdit = canEdit && !isLivePhoto; self.canDelete = canDelete
    }
}

public struct SystemPhotoAlbum: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let count: Int
    public let canAdd: Bool
    public let canRemove: Bool
    public let canRename: Bool
    public let canDelete: Bool
    public init(id: String, name: String, count: Int, canAdd: Bool = true, canRemove: Bool = true,
                canRename: Bool = true, canDelete: Bool = true) {
        self.id = id; self.name = name; self.count = count; self.canAdd = canAdd
        self.canRemove = canRemove; self.canRename = canRename; self.canDelete = canDelete
    }
}

public struct SystemPhotoPage: Sendable {
    public let items: [SystemPhoto]
    public let total: Int
    public init(items: [SystemPhoto], total: Int) { self.items = items; self.total = total }
}

public struct SystemPhotoEditInput: Sendable {
    public let photo: SystemPhoto
    public let renderInput: ColorRenderInput
    /// Hash of the actual editing base and Photos adjustment recipe, independent of temporary file identity.
    public let contentVersion: String
    public let adjustments: ColorAdjustments
    public let usesRenderedBase: Bool
    public let token: UUID
    public init(photo: SystemPhoto, renderInput: ColorRenderInput, contentVersion: String,
                adjustments: ColorAdjustments = ColorAdjustments(), usesRenderedBase: Bool = false, token: UUID = UUID()) {
        self.photo = photo; self.renderInput = renderInput; self.contentVersion = contentVersion
        self.adjustments = adjustments; self.usesRenderedBase = usesRenderedBase; self.token = token
    }
}

public enum SystemPhotoChange: Sendable { case changed, unavailable(String) }
public enum SystemPhotoMutation: Codable, Sendable {
    case createAlbum(String)
    case renameAlbum(id: String, name: String)
    case deleteAlbum(id: String)
    case addToAlbum(id: String)
    case removeFromAlbum(id: String)
    case deletePhotos
    public var title: String {
        switch self {
        case .createAlbum(let name): "创建相册“\(name)”"
        case .renameAlbum(_, let name): "重命名相册为“\(name)”"
        case .deleteAlbum: "删除相册（保留照片）"
        case .addToAlbum: "添加照片到相册"
        case .removeFromAlbum: "移出相册（保留照片）"
        case .deletePhotos: "从系统图库删除照片"
        }
    }
}

public struct SystemPhotoMutationPlan: Codable, Identifiable, Sendable {
    public let id: UUID
    public let operation: SystemPhotoMutation
    public let photos: [SystemPhoto]
    public let albumName: String?
    public let albumCount: Int?
    public init(operation: SystemPhotoMutation, photos: [SystemPhoto] = [], album: SystemPhotoAlbum? = nil) {
        id = UUID(); self.operation = operation; self.photos = photos
        albumName = album?.name; albumCount = album?.count
    }
}

public struct SystemPhotoUploadFile: Sendable {
    public let url: URL
    public let name: String
    public let fingerprint: AnalysisFingerprint
    public init(url: URL, name: String) throws { self.url = url; self.name = name; fingerprint = try AnalysisFingerprint(url: url) }
    public func validate() throws { try ColorSourceAccess.requireSame(fingerprint, AnalysisFingerprint(url: url)) }
}

public struct SystemPhotoUpload: Identifiable, Sendable {
    public let id: UUID
    public let files: [SystemPhotoUploadFile]
    public let album: SystemPhotoAlbum?
    public let workspace: PhotoWorkspace
    public let sources: [ColorEditSnapshot]
    public let mode: PhotoShareMode
    public init(id: UUID = UUID(), files: [SystemPhotoUploadFile], album: SystemPhotoAlbum?, workspace: PhotoWorkspace,
                sources: [ColorEditSnapshot], mode: PhotoShareMode) {
        self.id = id; self.files = files; self.album = album; self.workspace = workspace
        self.sources = sources; self.mode = mode
    }
}

/// Only the real implementation imports Photos. Checks and isolated UI sessions inject a fake.
public protocol PhotoLibraryClient: Sendable {
    func authorization(request: Bool) async -> SystemPhotoAuthorization
    func albums() async throws -> [SystemPhotoAlbum]
    func page(albumID: String?, offset: Int, limit: Int) async throws -> SystemPhotoPage
    func photos(ids: [String], albumID: String?) async throws -> [SystemPhoto]
    func index(id: String, albumID: String?) async throws -> Int?
    func image(id: String, pixelSize: Int) async throws -> PreviewImage
    func editingInput(photo: SystemPhoto) async throws -> SystemPhotoEditInput
    func releaseEditingInput(token: UUID) async
    func original(photo: SystemPhoto) async throws -> ColorRenderInput
    func validate(photo: SystemPhoto) async throws
    func saveEdit(input: SystemPhotoEditInput, adjustments: ColorAdjustments, renderedURL: URL) async throws
    func mutate(_ plan: SystemPhotoMutationPlan) async throws
    func upload(_ upload: SystemPhotoUpload, created: @escaping @Sendable ([String]) throws -> Void) async throws -> [String]
    func observe(_ handler: (@Sendable (SystemPhotoChange) -> Void)?) async
}

public struct SystemPhotoAnalysisJob: Codable, Identifiable, Sendable {
    public let id: String
    public let photos: [SystemPhoto]
    public var completed: Set<String>
    public var failures: [String: String]
    public var cancelled: Bool
    public var cameras: [String: String]
    public var ended = false
    public var groupingComplete = false
    public init(photos: [SystemPhoto]) {
        id = UUID().uuidString; self.photos = photos; completed = []; failures = [:]; cancelled = false; cameras = [:]
    }
    public var remaining: [SystemPhoto] { photos.filter { !completed.contains($0.id) } }
    public var isResumable: Bool { !ended && (!remaining.isEmpty || !groupingComplete) }
}

public enum SystemPhotosError: LocalizedError {
    case message(String)
    case commitUnknown(String)
    public var errorDescription: String? {
        switch self { case .message(let message), .commitUnknown(let message): return message }
    }
}
