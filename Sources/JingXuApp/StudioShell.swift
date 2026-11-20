import JingXuCore
import SwiftUI

struct StudioShell: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    let requestCreateSystemAlbum: () -> Void
    let requestRenameSystemAlbum: (SystemPhotoAlbum) -> Void
    let shareSystemPhoto: () -> Void

    @State private var sidebarMemory = StudioSidebarMemory(userPreferredVisible: true)

    private var stage: StudioStageMode { model.stageMode }

    private var splitVisibilityBinding: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { sidebarMemory.isSidebarVisible ? .all : .detailOnly },
            set: { newValue in
                let visible = (newValue != .detailOnly)
                if visible != sidebarMemory.isSidebarVisible {
                    sidebarMemory.setManualVisibility(visible, in: stage)
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: splitVisibilityBinding) {
            StudioSidebar(
                requestCreateSystemAlbum: requestCreateSystemAlbum,
                requestRenameSystemAlbum: requestRenameSystemAlbum
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 226, max: 280)
        } detail: {
            VStack(spacing: 0) {
                StudioToolbar(
                    isSidebarVisible: sidebarMemory.isSidebarVisible,
                    toggleSidebar: {
                        sidebarMemory.setManualVisibility(!sidebarMemory.isSidebarVisible, in: stage)
                    },
                    shareSystemPhoto: shareSystemPhoto
                )

                Divider()
                    .overlay(DarkroomPalette.hairline(colorScheme: colorScheme, appearance: model.appearanceMode, stage: stage))

                HStack(spacing: 0) {
                    centerStage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    rightPanel
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .onChange(of: model.stageMode) { oldStage, newStage in
            sidebarMemory.transition(from: oldStage, to: newStage)
        }
    }

    // MARK: - Center Stage

    @ViewBuilder
    private var centerStage: some View {
        if model.showsSystemPhotos, let photos = model.systemPhotos {
            if let photo = photos.preview {
                VStack(spacing: 0) {
                    SystemPhotoLoupeStage(photos: photos, photo: photo)
                        .id(photo.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if model.showsFilmstrip {
                        SystemPhotoFilmstrip(photos: photos, current: photo)
                    }
                }
            } else {
                SystemPhotoGridStage(photos: photos)
            }
        } else if let item = model.previewAsset {
            VStack(spacing: 0) {
                if model.comparisonReference != nil {
                    ComparisonView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LocalLoupeStage(item: item)
                        .id(item.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.showsFilmstrip {
                    PreviewFilmstrip(items: model.previewItems, currentID: item.id)
                }
            }
        } else {
            LocalPhotoGridStage()
        }
    }

    // MARK: - Right Panel (296pt)

    @ViewBuilder
    private var rightPanel: some View {
        if model.showsSystemPhotos, let photos = model.systemPhotos, let editor = photos.editor {
            Divider().overlay(DarkroomPalette.subtleDivider)
            SystemPhotoEditingHost(photos: photos, editor: editor)
        } else if !model.showsSystemPhotos, let editor = model.colorEditor {
            Divider().overlay(DarkroomPalette.subtleDivider)
            PhotoEditingSidebar(
                session: editor,
                presetPreview: $model.colorPresetPreview,
                presets: model.colorPresets,
                isWorking: model.isWorking,
                isTransitioning: model.isPreviewTransitioning,
                externallyControlled: model.automationOwnsOperation,
                beginComposition: model.beginComposition,
                applyComposition: model.applyComposition,
                copyAdjustments: model.copyColorAdjustments,
                managePresets: model.showColorPresets,
                discardStale: model.discardStaleColor
            )
            .id(editor.snapshot.id)
            .frame(width: 296)
        } else if model.showsInspector {
            Divider().overlay(DarkroomPalette.hairline(colorScheme: colorScheme, appearance: model.appearanceMode, stage: stage))
            PhotoInfoInspector()
        }
    }
}

private struct SystemPhotoEditingHost: View {
    @ObservedObject var photos: SystemPhotosModel
    @ObservedObject var editor: ColorEditSession

    var body: some View {
        PhotoEditingSidebar(
            session: editor,
            presetPreview: $photos.presetPreview,
            presets: photos.presets,
            isWorking: photos.isBusy,
            isTransitioning: photos.isNavigating,
            externallyControlled: false,
            beginComposition: photos.beginComposition,
            applyComposition: photos.applyComposition,
            copyAdjustments: { photos.copiedPatch = ColorPatch(editor.adjustments) },
            managePresets: photos.showPresets,
            discardStale: photos.discardDraft
        )
        .id(editor.snapshot.id)
        .frame(width: 296)
    }
}
