import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A complete in-process test library. It never initializes or calls PhotoKit.
public actor IsolatedPhotoLibraryClient: PhotoLibraryClient {
    private struct Entry {
        var photo: SystemPhoto
        let original: URL
        var displayed: URL
        var adjustments = ColorAdjustments()
        var editingBase: URL?
        var usesRenderedBase = false
    }
    private let root: URL
    private var entries: [String: Entry] = [:]
    private var collections: [String: (String, Set<String>)] = [:]
    private var handler: (@Sendable (SystemPhotoChange) -> Void)?
    private var status: SystemPhotoAuthorization = .authorized
    private var nextFailure: Error?
    private var commitFailure: String?
    private var downloadFailures: [String: String] = [:]
    private var tokens = Set<UUID>()
    private var available = true
    private var downloadDelay: Duration = .zero
    public private(set) var mutations = 0
    public private(set) var requestedOriginals: [String] = []
    public init(root: URL, photos: [(SystemPhoto, URL)]) {
        self.root = root
        for (photo, url) in photos { entries[photo.id] = Entry(photo: photo, original: url, displayed: url) }
    }
    public static func fixtures(root: URL) throws -> IsolatedPhotoLibraryClient {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var photos: [(SystemPhoto, URL)] = []
        for index in 0..<9 {
            let url = root.appendingPathComponent("样片-\(index + 1).png")
            let width = 640, height = 420
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
            context.setFillColor(CGColor(red: CGFloat(index % 3) / 3 + 0.12, green: CGFloat(index / 3) / 3 + 0.12, blue: 0.35, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 0.9, alpha: 1))
            context.fillEllipse(in: CGRect(x: 90 + index * 27, y: 100, width: 170, height: 170))
            guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            photos.append((SystemPhoto(id: "fixture-\(index)", name: url.lastPathComponent,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                width: width, height: height, isLivePhoto: index == 8), url))
        }
        return IsolatedPhotoLibraryClient(root: root, photos: photos)
    }
    public func setAuthorization(_ status: SystemPhotoAuthorization) { self.status = status; handler?(.changed) }
    public func failNext(_ error: Error) { nextFailure = error }
    public func failAfterNextCommit(_ message: String) { commitFailure = message }
    public func failDownload(id: String, message: String?) { downloadFailures[id] = message }
    public func delayDownloads(_ delay: Duration) { downloadDelay = delay }
    public func simulateUnavailable() { available = false; tokens.removeAll(); handler?(.unavailable("隔离图库已切换")) }
    public func changeExternally(id: String) throws {
        guard var entry = entries[id] else { throw ColorEditError("照片不存在") }
        entry.photo = changed(entry.photo); entry.adjustments.exposure += 0.1
        entries[id] = entry; handler?(.changed)
    }
    public func editInAnotherApp(id: String, renderedURL: URL) throws {
        guard var entry = entries[id] else { throw ColorEditError("照片不存在") }
        let base = root.appendingPathComponent(UUID().uuidString).appendingPathExtension(renderedURL.pathExtension)
        try FileManager.default.copyItem(at: renderedURL, to: base)
        entry.editingBase = base; entry.displayed = base; entry.adjustments = ColorAdjustments(); entry.usesRenderedBase = true
        entry.photo = changed(entry.photo); entries[id] = entry; handler?(.changed)
    }
    private func check() throws {
        guard status.canRead else { throw ColorEditError("未获得照片权限") }
        guard available else { throw ColorEditError("隔离图库不可用") }
        if let error = nextFailure { nextFailure = nil; throw error }
    }
    public func authorization(request: Bool) -> SystemPhotoAuthorization { status }
    public func albums() throws -> [SystemPhotoAlbum] {
        try check()
        return collections.map { SystemPhotoAlbum(id: $0.key, name: $0.value.0, count: $0.value.1.count) }.sorted { $0.name < $1.name }
    }
    public func page(albumID: String?, offset: Int, limit: Int) throws -> SystemPhotoPage {
        try check()
        let list = list(albumID: albumID)
        let start = min(max(offset, 0), list.count), end = min(start + max(0, min(limit, 200)), list.count)
        return SystemPhotoPage(items: Array(list[start..<end]), total: list.count)
    }
    private func list(albumID: String?) -> [SystemPhoto] {
        entries.values.map(\.photo).filter { albumID == nil || collections[albumID!]?.1.contains($0.id) == true }
            .sorted { ($0.capturedAt ?? .distantPast, $0.id) > ($1.capturedAt ?? .distantPast, $1.id) }
    }
    public func index(id: String, albumID: String?) throws -> Int? { try check(); return list(albumID: albumID).firstIndex { $0.id == id } }
    public func photos(ids: [String], albumID: String?) throws -> [SystemPhoto] {
        try check()
        return ids.filter { albumID == nil || collections[albumID!]?.1.contains($0) == true }.compactMap { entries[$0]?.photo }
    }
    public func image(id: String, pixelSize: Int) async throws -> PreviewImage {
        try check()
        guard let entry = entries[id] else { throw ColorEditError("照片不存在") }
        return try await ImagePreviewLoader().load(url: entry.displayed)
    }
    public func validate(photo: SystemPhoto) throws {
        try check()
        guard entries[photo.id]?.photo == photo else { throw ColorEditError("照片已变化或删除") }
    }
    public func editingInput(photo: SystemPhoto) async throws -> SystemPhotoEditInput {
        try validate(photo: photo)
        guard photo.canEdit, !photo.isLivePhoto, let entry = entries[photo.id] else { throw ColorEditError("不支持静态编辑") }
        let base = entry.editingBase ?? entry.original
        let (input, digest) = try await PhotoFileWorker.shared.copy(id: photo.id, from: base, parent: root,
            fileExtension: base.pathExtension, orientation: nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let version = digest + ":" + String(decoding: try encoder.encode(entry.adjustments), as: UTF8.self)
        let result = SystemPhotoEditInput(photo: photo, renderInput: input, contentVersion: version,
            adjustments: entry.adjustments, usesRenderedBase: entry.usesRenderedBase)
        tokens.insert(result.token); return result
    }
    public func releaseEditingInput(token: UUID) { tokens.remove(token) }
    public func original(photo: SystemPhoto) async throws -> ColorRenderInput {
        try validate(photo: photo)
        requestedOriginals.append(photo.id)
        if downloadDelay != .zero { try await Task.sleep(for: downloadDelay) }
        try Task.checkCancellation()
        if let message = downloadFailures[photo.id] { throw ColorEditError(message) }
        guard let entry = entries[photo.id] else { throw ColorEditError("原片不存在") }
        return try await PhotoFileWorker.shared.copy(id: photo.id, from: entry.original, parent: root,
            fileExtension: entry.original.pathExtension, orientation: nil).0
    }
    public func saveEdit(input: SystemPhotoEditInput, adjustments: ColorAdjustments, renderedURL: URL) async throws {
        try validate(photo: input.photo)
        guard tokens.contains(input.token), !input.photo.isLivePhoto else { throw ColorEditError("编辑会话已失效") }
        guard var entry = entries[input.photo.id] else { throw ColorEditError("照片不存在") }
        let current = try await editingInput(photo: input.photo)
        tokens.remove(current.token)
        guard current.contentVersion == input.contentVersion else { throw ColorEditError("照片底图变化") }
        let output = root.appendingPathComponent(UUID().uuidString + ".jpg")
        try FileManager.default.copyItem(at: renderedURL, to: output)
        entry.adjustments = adjustments; entry.displayed = output; entry.photo = changed(entry.photo)
        entries[entry.photo.id] = entry; mutations += 1; handler?(.changed)
        tokens.remove(input.token); try afterCommit()
    }
    public func mutate(_ plan: SystemPhotoMutationPlan) throws {
        try check()
        for photo in plan.photos { try validate(photo: photo) }
        let ids = Set(plan.photos.map(\.id))
        switch plan.operation {
        case .renameAlbum(let id, _), .deleteAlbum(let id), .addToAlbum(let id), .removeFromAlbum(let id):
            guard let album = collections[id], album.0 == plan.albumName, album.1.count == plan.albumCount else {
                throw ColorEditError("相册已变化，请重新确认")
            }
        default: break
        }
        switch plan.operation {
        case .createAlbum(let name):
            try ApplePhotoLibraryClient.validateName(name); collections[UUID().uuidString] = (name, [])
        case .renameAlbum(let id, let name):
            try ApplePhotoLibraryClient.validateName(name); guard let value = collections[id] else { throw ColorEditError("相册不存在") }
            collections[id] = (name, value.1)
        case .deleteAlbum(let id): collections.removeValue(forKey: id)
        case .addToAlbum(let id):
            guard let value = collections[id] else { throw ColorEditError("相册不存在") }; collections[id] = (value.0, value.1.union(ids))
        case .removeFromAlbum(let id):
            guard let value = collections[id] else { throw ColorEditError("相册不存在") }; collections[id] = (value.0, value.1.subtracting(ids))
        case .deletePhotos:
            guard plan.photos.allSatisfy(\.canDelete) else { throw ColorEditError("不允许删除") }
            for id in ids { entries.removeValue(forKey: id) }
            for (id, value) in collections { collections[id] = (value.0, value.1.subtracting(ids)) }
        }
        mutations += 1; handler?(.changed); try afterCommit()
    }
    public func upload(_ upload: SystemPhotoUpload, created: @escaping @Sendable ([String]) throws -> Void) throws -> [String] {
        try check()
        if let album = upload.album {
            guard let value = collections[album.id], value.0 == album.name else { throw ColorEditError("上传相册已变化") }
        }
        var added: [Entry] = []
        for file in upload.files {
            try file.validate()
            let url = root.appendingPathComponent(UUID().uuidString).appendingPathExtension(file.url.pathExtension)
            try FileManager.default.copyItem(at: file.url, to: url)
            added.append(Entry(photo: SystemPhoto(id: UUID().uuidString, name: file.name, modifiedAt: Date(), capturedAt: Date()),
                               original: url, displayed: url))
        }
        let ids = added.map(\.photo.id); try created(ids)
        for entry in added { entries[entry.photo.id] = entry }
        if let album = upload.album, let value = collections[album.id] { collections[album.id] = (value.0, value.1.union(ids)) }
        mutations += 1; handler?(.changed); try afterCommit(); return ids
    }
    private func afterCommit() throws {
        if let message = commitFailure { commitFailure = nil; throw SystemPhotosError.commitUnknown(message) }
    }
    public func observe(_ handler: (@Sendable (SystemPhotoChange) -> Void)?) { self.handler = handler }
    private func changed(_ photo: SystemPhoto) -> SystemPhoto {
        SystemPhoto(id: photo.id, name: photo.name, modifiedAt: Date(), capturedAt: photo.capturedAt,
            width: photo.width, height: photo.height, isLivePhoto: photo.isLivePhoto, canEdit: photo.canEdit, canDelete: photo.canDelete)
    }
}
