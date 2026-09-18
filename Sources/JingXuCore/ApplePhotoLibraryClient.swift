@preconcurrency import AppKit
@preconcurrency import Photos
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Bridges Photos' multiple callbacks and cancellation into exactly one async result.
final class PhotoRequest<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    private var cancellation: (@Sendable () -> Void)?
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ value: Result<Value, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value; let continuation = continuation; self.continuation = nil; cancellation = nil
        lock.unlock(); continuation?.resume(with: value)
    }
    func onCancel(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        if case .failure(let error) = result, error is CancellationError { lock.unlock(); action() }
        else { cancellation = result == nil ? action : nil; lock.unlock() }
    }
    func cancel() {
        lock.lock(); let action = cancellation; lock.unlock()
        finish(.failure(CancellationError())); action?()
    }
}

private final class PhotosObserver: NSObject, PHPhotoLibraryChangeObserver, PHPhotoLibraryAvailabilityObserver, @unchecked Sendable {
    let changed: @Sendable (SystemPhotoChange) -> Void
    init(_ changed: @escaping @Sendable (SystemPhotoChange) -> Void) { self.changed = changed }
    func photoLibraryDidChange(_ changeInstance: PHChange) { changed(.changed) }
    func photoLibraryDidBecomeUnavailable(_ photoLibrary: PHPhotoLibrary) {
        changed(.unavailable("系统照片图库不可用或已切换，请重新连接；草稿和任务已保留"))
    }
}

private struct PhotosInput: @unchecked Sendable { let value: PHContentEditingInput }
private final class PhotoValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); self.value = value; lock.unlock() }
}

struct PhotosAdjustmentRecipe: Codable {
    static let identifier = "app.jingxu.desktop.color"
    static let version = "1"
    let adjustments: ColorAdjustments
    let usesRenderedBase: Bool
    static func decode(_ data: PHAdjustmentData) -> PhotosAdjustmentRecipe? {
        guard data.formatIdentifier == identifier, data.formatVersion == version else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data.data)
    }
}

/// File I/O stays off the UI and PhotoKit callback queues.
actor PhotoFileWorker {
    static let shared = PhotoFileWorker()
    func copy(id: String, from source: URL, parent: URL, fileExtension: String, orientation: Int?) throws -> (ColorRenderInput, String) {
        let workspace = try PhotoWorkspace(parent: parent)
        let target = workspace.directory.appendingPathComponent("input").appendingPathExtension(fileExtension)
        let before = try AnalysisFingerprint(url: source)
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: source, to: target)
        try ColorSourceAccess.requireSame(before, AnalysisFingerprint(url: source))
        let digest = try FileHasher.sha256(of: target)
        try Task.checkCancellation()
        return (try ColorRenderInput(id: id, url: target, workspace: workspace, orientation: orientation), digest)
    }
    func copyOutput(_ source: URL, to target: URL) throws {
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: source, to: target)
    }
    func digest(_ url: URL) throws -> String { try FileHasher.sha256(of: url) }
}

/// PH objects stay confined to this actor. Nothing reads the private Photos database.
public actor ApplePhotoLibraryClient: PhotoLibraryClient {
    private let library: PHPhotoLibrary
    private let manager: PHCachingImageManager
    private let temporaryRoot: URL
    private var observer: PhotosObserver?
    private var handler: (@Sendable (SystemPhotoChange) -> Void)?
    private var generation = UUID()
    private var inputs: [UUID: (PhotosInput, UUID)] = [:]
    public init(temporaryRoot: URL) throws {
        guard ProcessInfo.processInfo.environment["JINGXU_UI_TEST_ROOT"] == nil else {
            throw ColorEditError("隔离测试必须注入假图库，禁止访问真实 PhotoKit")
        }
        library = PHPhotoLibrary.shared(); manager = PHCachingImageManager(); self.temporaryRoot = temporaryRoot
    }
    private func requireAccess() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw ColorEditError("未获得照片读写权限，请在系统设置的隐私与安全性中允许镜序访问照片")
        }
        if let reason = library.unavailabilityReason { throw reason }
    }
    public func authorization(request: Bool) async -> SystemPhotoAuthorization {
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if request && status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        switch status {
        case .authorized: return .authorized
        case .limited: return .limited
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        default: return .denied
        }
    }
    private func asset(_ id: String) throws -> PHAsset {
        try requireAccess()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              asset.mediaType == .image, asset.sourceType.contains(.typeUserLibrary) else {
            throw ColorEditError("系统照片已不存在或不在支持范围")
        }
        return asset
    }
    private func photo(_ asset: PHAsset) -> SystemPhoto {
        let name = PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo })?.originalFilename ?? "照片"
        return SystemPhoto(id: asset.localIdentifier, name: name, modifiedAt: asset.modificationDate,
                           capturedAt: asset.creationDate, width: asset.pixelWidth, height: asset.pixelHeight,
                           isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                           canEdit: asset.canPerform(.content), canDelete: asset.canPerform(.delete))
    }
    private func album(_ id: String) throws -> PHAssetCollection {
        try requireAccess()
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject,
              collection.assetCollectionType == .album, collection.assetCollectionSubtype == .albumRegular else {
            throw ColorEditError("普通相册已不存在")
        }
        return collection
    }
    public func albums() throws -> [SystemPhotoAlbum] {
        try requireAccess()
        let result = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        return (0..<result.count).map { index in
            let value = result.object(at: index)
            return SystemPhotoAlbum(id: value.localIdentifier, name: value.localizedTitle ?? "未命名相册",
                count: PHAsset.fetchAssets(in: value, options: nil).count, canAdd: value.canPerform(.addContent),
                canRemove: value.canPerform(.removeContent), canRename: value.canPerform(.rename), canDelete: value.canPerform(.delete))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public func page(albumID: String?, offset: Int, limit: Int) throws -> SystemPhotoPage {
        let result = try fetch(albumID: albumID)
        let lower = min(max(offset, 0), result.count), upper = min(lower + max(0, min(limit, 200)), result.count)
        return SystemPhotoPage(items: (lower..<upper).map { photo(result.object(at: $0)) }, total: result.count)
    }
    private func fetch(albumID: String?) throws -> PHFetchResult<PHAsset> {
        try requireAccess()
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeAssetSourceTypes = [.typeUserLibrary]
        return try albumID.map { PHAsset.fetchAssets(in: try album($0), options: options) }
            ?? PHAsset.fetchAssets(with: options)
    }
    public func index(id: String, albumID: String?) throws -> Int? {
        let result = try fetch(albumID: albumID)
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let index = result.index(of: asset)
        return index == NSNotFound ? nil : index
    }
    public func photos(ids: [String], albumID: String?) throws -> [SystemPhoto] {
        try requireAccess()
        let members = try albumID.map { PHAsset.fetchAssets(in: try album($0), options: nil) }
        let found = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var values: [String: SystemPhoto] = [:]
        for index in 0..<found.count {
            let item = found.object(at: index)
            if item.mediaType == .image && item.sourceType.contains(.typeUserLibrary),
               members == nil || members?.index(of: item) != NSNotFound { values[item.localIdentifier] = photo(item) }
        }
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.compactMap { values[$0] }
    }
    public func validate(photo expected: SystemPhoto) throws {
        let current = photo(try asset(expected.id))
        guard current.modifiedAt == expected.modifiedAt, current.width == expected.width, current.height == expected.height,
              current.isLivePhoto == expected.isLivePhoto else { throw ColorEditError("照片已在其他设备或应用中变化，请重新载入") }
    }
    public func image(id: String, pixelSize: Int) async throws -> PreviewImage {
        let value = try asset(id), request = PhotoRequest<PreviewImage>()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true; options.deliveryMode = .highQualityFormat; options.resizeMode = .fast
        let size = pixelSize == Int.max ? PHImageManagerMaximumSize : CGSize(width: pixelSize, height: pixelSize)
        let manager = manager
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                let identifier = manager.requestImage(for: value, targetSize: size, contentMode: .aspectFit, options: options) { image, info in
                    if let error = info?[PHImageErrorKey] as? Error { request.finish(.failure(error)); return }
                    if info?[PHImageCancelledKey] as? Bool == true { request.cancel(); return }
                    if info?[PHImageResultIsDegradedKey] as? Bool == true { return }
                    guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        request.finish(.failure(ColorEditError("无法获取照片，可能尚未从 iCloud 下载"))); return
                    }
                    request.finish(.success(PreviewImage(image: cg, nativeSize: CGSize(width: cg.width, height: cg.height), isEmbedded: false, access: nil)))
                }
                request.onCancel { manager.cancelImageRequest(identifier) }
            }
        } onCancel: { request.cancel() }
    }
    public func editingInput(photo expected: SystemPhoto) async throws -> SystemPhotoEditInput {
        try validate(photo: expected)
        let value = try asset(expected.id)
        guard expected.canEdit, !expected.isLivePhoto, value.canPerform(.content) else { throw ColorEditError("此照片不支持静态调色回写") }
        let epoch = generation, request = PhotoRequest<PhotosInput>(), renderedBase = PhotoValue(false)
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        options.canHandleAdjustmentData = { data in
            let supported = PhotosAdjustmentRecipe.decode(data) != nil
            renderedBase.set(!supported); return supported
        }
        let input = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PhotosInput, Error>) in
                request.install(continuation)
                let identifier = value.requestContentEditingInput(with: options) { input, info in
                    if let error = info[PHContentEditingInputErrorKey] as? Error { request.finish(.failure(error)); return }
                    guard let input else { request.finish(.failure(ColorEditError("编辑底图下载失败或已取消"))); return }
                    request.finish(.success(PhotosInput(value: input)))
                }
                request.onCancel { value.cancelContentEditingInputRequest(identifier) }
            }
        } onCancel: { request.cancel() }
        guard let url = input.value.fullSizeImageURL else { throw ColorEditError("系统未提供可编辑的静态底图") }
        let ext = input.value.uniformTypeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? url.pathExtension
        let (render, digest) = try await PhotoFileWorker.shared.copy(id: expected.id, from: url, parent: temporaryRoot,
            fileExtension: ext, orientation: Int(input.value.fullSizeImageOrientation))
        try validate(photo: expected)
        guard generation == epoch else { throw ColorEditError("系统图库已切换，请重新连接") }
        let recipe = input.value.adjustmentData.flatMap(PhotosAdjustmentRecipe.decode)
        let adjustmentDigest = input.value.adjustmentData.map {
            SHA256.hash(data: Data(($0.formatIdentifier + ":" + $0.formatVersion).utf8) + $0.data).map { String(format: "%02x", $0) }.joined()
        } ?? "none"
        let result = SystemPhotoEditInput(photo: expected, renderInput: render,
            contentVersion: digest + ":" + String(input.value.fullSizeImageOrientation) + ":" + adjustmentDigest,
            adjustments: recipe?.adjustments ?? ColorAdjustments(), usesRenderedBase: recipe?.usesRenderedBase ?? renderedBase.read())
        try result.adjustments.validate(isRAW: render.isRAW)
        inputs[result.token] = (input, epoch)
        return result
    }
    public func releaseEditingInput(token: UUID) { inputs.removeValue(forKey: token) }

    public func original(photo expected: SystemPhoto) async throws -> ColorRenderInput {
        try validate(photo: expected)
        let value = try asset(expected.id), epoch = generation
        let resources = PHAssetResource.assetResources(for: value)
        // The primary original still resource is also the static member of a Live Photo.
        guard let resource = resources.first(where: { $0.type == .photo }) else { throw ColorEditError("未找到原片静态资源") }
        let workspace = try PhotoWorkspace(parent: temporaryRoot)
        let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? URL(fileURLWithPath: resource.originalFilename).pathExtension
        let url = workspace.directory.appendingPathComponent("original").appendingPathExtension(ext)
        let request = PhotoRequest<Bool>(), manager = PHAssetResourceManager.default()
        let writer = try PhotoResourceWriter(url: url)
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        _ = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                request.install(continuation)
                let id = manager.requestData(for: resource, options: options, dataReceivedHandler: { writer.append($0) }) { error in
                    do { try writer.finish(); if let error { throw error }; request.finish(.success(true)) }
                    catch { request.finish(.failure(error)) }
                }
                request.onCancel { manager.cancelDataRequest(id); writer.cancel() }
            }
        } onCancel: { request.cancel() }
        try Task.checkCancellation(); try validate(photo: expected)
        guard generation == epoch else { throw ColorEditError("系统图库已切换") }
        return try ColorRenderInput(id: expected.id, url: url, workspace: workspace)
    }

    public func saveEdit(input: SystemPhotoEditInput, adjustments: ColorAdjustments, renderedURL: URL) async throws {
        try validate(photo: input.photo)
        guard let (context, epoch) = inputs[input.token], epoch == generation else { throw ColorEditError("编辑会话已失效，请重新载入") }
        let fresh = try await editingInput(photo: input.photo)
        inputs.removeValue(forKey: fresh.token)
        guard fresh.contentVersion == input.contentVersion else { throw ColorEditError("编辑底图已变化，草稿已保留") }
        try input.renderInput.revalidate()
        try adjustments.validate(isRAW: input.renderInput.isRAW)
        let output = PHContentEditingOutput(contentEditingInput: context.value)
        let url = try output.renderedContentURL(for: .jpeg)
        try await PhotoFileWorker.shared.copyOutput(renderedURL, to: url)
        let data = try JSONEncoder().encode(PhotosAdjustmentRecipe(adjustments: adjustments, usesRenderedBase: input.usesRenderedBase))
        output.adjustmentData = PHAdjustmentData(formatIdentifier: PhotosAdjustmentRecipe.identifier, formatVersion: PhotosAdjustmentRecipe.version, data: data)
        let value = try asset(input.photo.id)
        try validate(photo: input.photo); try Task.checkCancellation()
        guard value.canPerform(.content), !value.mediaSubtypes.contains(.photoLive), epoch == generation else {
            throw ColorEditError("照片当前不允许调色回写")
        }
        try await library.performChanges { PHAssetChangeRequest(for: value).contentEditingOutput = output }
        inputs.removeValue(forKey: input.token)
    }

    public func mutate(_ plan: SystemPhotoMutationPlan) async throws {
        try requireAccess(); try Task.checkCancellation()
        let values = try plan.photos.map { expected -> PHAsset in try validate(photo: expected); return try asset(expected.id) }
        let createdAlbumID = PhotoValue<String?>(nil)
        switch plan.operation {
        case .createAlbum(let name):
            try Self.validateName(name)
            try await library.performChanges {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                createdAlbumID.set(request.placeholderForCreatedAssetCollection.localIdentifier)
            }
        case .renameAlbum(let id, let name):
            try Self.validateName(name); let value = try album(id); try validateAlbum(value, plan: plan, operation: .rename)
            try await library.performChanges { PHAssetCollectionChangeRequest(for: value)?.title = name }
        case .deleteAlbum(let id):
            let value = try album(id); try validateAlbum(value, plan: plan, operation: .delete)
            try await library.performChanges { PHAssetCollectionChangeRequest.deleteAssetCollections([value] as NSArray) }
        case .addToAlbum(let id):
            let value = try album(id); try validateAlbum(value, plan: plan, operation: .addContent)
            try await library.performChanges { PHAssetCollectionChangeRequest(for: value)?.addAssets(values as NSArray) }
        case .removeFromAlbum(let id):
            let value = try album(id); try validateAlbum(value, plan: plan, operation: .removeContent)
            try await library.performChanges { PHAssetCollectionChangeRequest(for: value)?.removeAssets(values as NSArray) }
        case .deletePhotos:
            guard !values.isEmpty, values.allSatisfy({ $0.canPerform(.delete) }) else { throw ColorEditError("选择中存在不允许删除的照片") }
            try await library.performChanges { PHAssetChangeRequest.deleteAssets(values as NSArray) }
        }
        do {
            try requireAccess()
            switch plan.operation {
            case .createAlbum(let name):
                guard let id = createdAlbumID.read(), try album(id).localizedTitle == name else { throw ColorEditError("创建的相册暂不可读取") }
            case .renameAlbum(let id, let name):
                guard try album(id).localizedTitle == name else { throw ColorEditError("相册名称未核对一致") }
            case .deleteAlbum(let id):
                guard PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).count == 0 else { throw ColorEditError("相册删除结果尚未确认") }
            case .addToAlbum(let id):
                guard try photos(ids: plan.photos.map(\.id), albumID: id).count == plan.photos.count else { throw ColorEditError("相册成员尚未核对一致") }
            case .removeFromAlbum(let id):
                guard try photos(ids: plan.photos.map(\.id), albumID: id).isEmpty else { throw ColorEditError("移出相册结果尚未确认") }
            case .deletePhotos:
                guard PHAsset.fetchAssets(withLocalIdentifiers: plan.photos.map(\.id), options: nil).count == 0 else { throw ColorEditError("照片删除结果尚未确认") }
            }
        } catch { throw SystemPhotosError.commitUnknown("系统已处理操作，但回读未确认：\(error.localizedDescription)") }
    }
    private func validateAlbum(_ value: PHAssetCollection, plan: SystemPhotoMutationPlan, operation: PHCollectionEditOperation) throws {
        guard value.canPerform(operation), value.localizedTitle == plan.albumName,
              PHAsset.fetchAssets(in: value, options: nil).count == plan.albumCount else { throw ColorEditError("相册已变化或操作不被允许，请重新确认") }
    }
    static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100 else { throw ColorEditError("相册名称需为 1–100 个字符") }
    }
    public func upload(_ upload: SystemPhotoUpload, created: @escaping @Sendable ([String]) throws -> Void) async throws -> [String] {
        try requireAccess(); try Task.checkCancellation()
        guard !upload.files.isEmpty else { throw ColorEditError("没有可上传的照片") }
        for file in upload.files { try file.validate() }
        let destination = try upload.album.map { expected -> PHAssetCollection in
            let value = try album(expected.id)
            guard value.canPerform(.addContent), value.localizedTitle == expected.name else { throw ColorEditError("目标相册已变化或不允许添加") }
            return value
        }
        let identifiers = PhotoValue<[String]>([]), receiptError = PhotoValue<String?>(nil)
        try await library.performChanges {
            var placeholders: [PHObjectPlaceholder] = []
            for file in upload.files {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions(); options.shouldMoveFile = false; options.originalFilename = file.name
                request.addResource(with: .photo, fileURL: file.url, options: options)
                if let placeholder = request.placeholderForCreatedAsset { placeholders.append(placeholder) }
            }
            let ids = placeholders.map(\.localIdentifier); identifiers.set(ids)
            do { try created(ids) } catch { receiptError.set(error.localizedDescription) }
            if let destination { PHAssetCollectionChangeRequest(for: destination)?.addAssets(placeholders as NSArray) }
        }
        let ids = identifiers.read()
        if let error = receiptError.read() { throw SystemPhotosError.commitUnknown("照片已提交，但本地记录失败：\(error)。请在系统照片中核对，勿重复上传") }
        guard ids.count == upload.files.count, (try? photos(ids: ids, albumID: upload.album?.id).count) == ids.count else {
            throw SystemPhotosError.commitUnknown("系统已处理提交，但暂时无法核对全部照片，请在系统照片中确认")
        }
        return ids
    }
    public func observe(_ handler: (@Sendable (SystemPhotoChange) -> Void)?) {
        if let observer { library.unregisterChangeObserver(observer); library.unregisterAvailabilityObserver(observer) }
        observer = nil; self.handler = handler
        guard handler != nil else { return }
        let observer = PhotosObserver { [weak self] event in Task { await self?.receive(event) } }
        self.observer = observer; library.register(observer as PHPhotoLibraryChangeObserver); library.register(observer as PHPhotoLibraryAvailabilityObserver)
    }
    private func receive(_ event: SystemPhotoChange) {
        if case .unavailable = event { generation = UUID(); inputs.removeAll(); manager.stopCachingImagesForAllAssets() }
        handler?(event)
    }
}

private final class PhotoResourceWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var error: Error?
    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission) }
        handle = try FileHandle(forWritingTo: url)
    }
    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard error == nil, let handle else { return }
        do { try handle.write(contentsOf: data) } catch { self.error = error }
    }
    func finish() throws {
        lock.lock(); defer { lock.unlock() }
        try handle?.close(); handle = nil
        if let error { throw error }
    }
    func cancel() { lock.lock(); defer { lock.unlock() }; try? handle?.close(); handle = nil; error = CancellationError() }
    deinit { try? handle?.close() }
}
