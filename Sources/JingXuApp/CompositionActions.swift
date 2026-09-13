import JingXuCore

extension AppModel {
    func beginComposition() {
        guard canStartColorAction, comparisonReference == nil, let item = previewAsset, let store else { return }
        isPreviewTransitioning = true
        Task {
            defer { isPreviewTransitioning = false }
            do {
                if colorEditor == nil {
                    let snapshot = try await store.colorSnapshot(assetID: item.id)
                    guard previewAsset?.id == item.id else { return }
                    attachColorSession(try makeColorSession(snapshot))
                }
                try await colorEditor?.beginComposition()
            } catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }
    func applyComposition() {
        guard !isPreviewTransitioning, let editor = colorEditor, editor.composition?.canApply == true else { return }
        isPreviewTransitioning = true
        Task {
            defer { isPreviewTransitioning = false }
            _ = await editor.applyComposition()
        }
    }
}
