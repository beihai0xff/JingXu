import AppKit
import JingXuCore

extension AppModel {
    var canRunSystemPhotos: Bool {
        !isStarting && startupFailure == nil && !isWorking && !automationOwnsOperation &&
        !isSavingAnnotation && !isPreparingSelection && !isPreviewTransitioning &&
        !isShowingPhotoShare && !photoShareSession.blocksFileChanges
    }
    func makeSystemPhotos() throws -> SystemPhotosModel {
        if let systemPhotos { return systemPhotos }
        guard let store else { throw ColorEditError("本地图库尚未打开") }
        let value = try SystemPhotosModel(localStore: store) { [weak self] in self?.canRunSystemPhotos == true }
        systemPhotos = value
        systemPhotosObservation = value.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        return value
    }
    func openSystemPhotos() {
        guard !isWorking, canChangeBrowseScope else { return }
        transitionPreview {
            Task {
                do {
                    try await self.checkDeletionRecovery()
                    let photos = try self.makeSystemPhotos()
                    self.showsSystemPhotos = true
                    if !photos.connected { photos.connect() } else { photos.refresh() }
                } catch { self.errorMessage = error.localizedDescription }
            }
        }
    }
    func leaveSystemPhotos() {
        guard let photos = systemPhotos else { return }
        Task {
            guard await photos.prepareForExit() else { return }
            showsSystemPhotos = false
        }
    }
    func showSystemPhotoUpload() {
        guard canStartColorAction, !colorTargetIDs.isEmpty, let store else { return }
        let ids = colorTargetIDs
        transitionPreview {
            self.isPreparingSelection = true
            Task {
                defer { self.isPreparingSelection = false }
                do {
                    try await self.checkDeletionRecovery()
                    let photos = try self.makeSystemPhotos()
                    var snapshots: [ColorEditSnapshot] = []
                    for id in ids { snapshots.append(try await store.colorSnapshot(assetID: id)) }
                    photos.preparedUpload = nil; photos.uploadSnapshots = snapshots
                } catch { self.errorMessage = error.localizedDescription }
            }
        }
    }
}
