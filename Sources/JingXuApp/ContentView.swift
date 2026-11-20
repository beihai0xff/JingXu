import JingXuCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCreateSystemAlbum = false
    @State private var newSystemAlbumName = ""
    @State private var renameSystemAlbumTarget: SystemPhotoAlbum?
    @State private var renameSystemAlbumName = ""
    @State private var showsSystemShare = false
    @State private var systemShareImage: CGImage?

    private var keyboardEnabled: Bool {
        if model.showsSystemPhotos {
            guard let photos = model.systemPhotos else { return false }
            return photos.connected && !photos.isBusy && photos.mutationPlan == nil &&
                photos.analysisPlan == nil && !photos.showsPresets && !showsSystemShare
        }
        return !model.isShowingKeywords &&
            model.operationBlockReason(model.colorEditor?.isComposing == true ? .browse : .annotation) == nil
    }

    var body: some View {
        StudioShell(
            requestCreateSystemAlbum: { showCreateSystemAlbum = true },
            requestRenameSystemAlbum: { album in
                renameSystemAlbumTarget = album
                renameSystemAlbumName = album.name
            },
            shareSystemPhoto: {
                model.systemPhotos?.prepareFullImage { image in
                    systemShareImage = image
                    showsSystemShare = true
                }
            }
        )
        .background(
            LibraryKeyboardHandler(
                enabled: keyboardEnabled,
                onFocusLost: { model.endActiveOriginalComparison() }
            ) { code, text, shift, command, isRepeat, isKeyUp in
                model.handleStudioKey(
                    code: code,
                    text: text,
                    shift: shift,
                    command: command,
                    isRepeat: isRepeat,
                    isKeyUp: isKeyUp
                )
            }
        )
        .modifier(PhotoSharePresentation(model: model, session: model.photoShareSession))
        .modifier(ColorWorkflowPresentation())
        .modifier(
            SystemPhotosPresentation(
                photos: model.systemPhotos,
                showCreateAlbum: $showCreateSystemAlbum,
                newAlbumName: $newSystemAlbumName,
                renameTarget: $renameSystemAlbumTarget,
                renameText: $renameSystemAlbumName,
                showsShare: $showsSystemShare,
                shareImage: $systemShareImage
            )
        )
        .sheet(item: $model.xmpPlan) { plan in
            XMPExportPlanSheet(plan: plan).environmentObject(model)
        }
        .sheet(item: $model.importPlan) { plan in
            ImportPlanView(plan: plan).environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingImportReport) {
            if let report = model.lastImportReport {
                ImportResultView(report: report).environmentObject(model)
            }
        }
        .sheet(item: $model.archivePlan) { plan in
            ArchivePlanSheet(plan: plan).environmentObject(model)
        }
        .sheet(item: $model.missingAssetPlan) { plan in
            MissingAssetCleanupSheet(plan: plan).environmentObject(model)
        }
        .sheet(item: $model.qualityReanalysisPlan) { plan in
            QualityReanalysisSheet(plan: plan).environmentObject(model)
        }
        .sheet(item: $model.sourceMergePlan) { plan in
            SourceMergePlanSheet(plan: plan).environmentObject(model)
        }
        .sheet(item: $model.deletionPlan) { plan in
            DeletionPlanSheet(plan: plan).environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingImport) {
            ImportSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingAlbumCreator) {
            AlbumCreatorSheet().environmentObject(model)
        }
        .alert(
            "镜序",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.minimumRating) { _, _ in model.requestFilters() }
        .onChange(of: model.sortOrder) { _, _ in model.requestFilters() }
        .onChange(of: model.flagFilter) { _, _ in model.requestFilters() }
    }
}
