import JingXuCore
import SwiftUI

struct LocalFloatingSelectionDock: View {
    @EnvironmentObject private var model: AppModel
    @State private var keywordIDs: [String] = []
    @State private var keywords = ""
    @State private var keywordMode = 0
    @State private var confirmsReplace = false

    private var selectedCount: Int { model.photoSelection.selectedIDs.count }

    private var offWindowCount: Int {
        let selected = model.photoSelection.selectedIDs
        let inWindow = model.loadedAssets.photoIDs.reduce(0) { $0 + (selected.contains($1) ? 1 : 0) }
        return max(0, selected.count - inWindow)
    }

    var body: some View {
        Group {
            if selectedCount > 0 {
                HStack(spacing: 10) {
                    selectionCluster
                    Divider().frame(height: 18).overlay(DarkroomPalette.subtleDivider)
                    actionCluster
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule(style: .continuous).fill(DarkroomPalette.floatingHUDFill))
                        .overlay(Capsule(style: .continuous).strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1))
                }
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.42), radius: 14, y: 6)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: selectedCount > 0)
        .sheet(isPresented: $model.isShowingKeywords) {
            batchKeywordSheet
        }
    }

    private var selectionCluster: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text("已选 \(selectedCount) 张")
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(DarkroomPalette.textPrimary)
                if offWindowCount > 0 {
                    Text("（窗口外 \(offWindowCount) 张）")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DarkroomPalette.textSecondary)
                }
            }
            Button("全选范围") { model.selectAllMatchingPhotos() }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(!model.canChangeBrowseScope)
            Button("取消") { model.clearPhotoSelection() }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(DarkroomPalette.textSecondary)
                .disabled(!model.canChangeBrowseScope)
        }
        .fixedSize()
    }

    private var actionCluster: some View {
        HStack(spacing: 8) {
            if selectedCount == 1,
               let item = model.selectedAsset,
               model.photoSelection.selectedIDs.contains(item.id) {
                Button("单图", systemImage: "arrow.up.left.and.arrow.down.right") { model.openPreview(item) }
                    .disabled(!model.canChangeBrowseScope)
            }
            if selectedCount == 2 {
                Button("双图对比", systemImage: "rectangle.split.2x1") { model.compareSelected() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.operationBlockReason(.browse) != nil)
            }
            Menu("评分", systemImage: "star") {
                ForEach(0...5, id: \.self) { value in
                    Button(value == 0 ? "无评分" : "\(value) 星") { model.updateRating(value) }
                }
            }
            .disabled(model.operationBlockReason(.annotation) != nil)

            Button("淘汰", systemImage: "xmark.circle") { model.updateFlag(.rejected) }
                .help("标记淘汰（X / Delete），保留原文件且可撤销")
                .disabled(model.operationBlockReason(.annotation) != nil)

            Menu("加入相册", systemImage: "folder.badge.plus") {
                ForEach(model.albums) { album in
                    Button(album.name) { model.addSelectedAsset(to: album) }
                }
                if model.albums.isEmpty { Text("请先在左侧边栏新建相册") }
            }
            .disabled(model.operationBlockReason(.annotation) != nil)

            Button("导出", systemImage: "square.and.arrow.down") { model.showColorExport() }
                .disabled(!model.canExportColor)

            Menu {
                Button("取消淘汰标记（U）") { model.updateFlag(.none) }
                    .disabled(model.operationBlockReason(.annotation) != nil)
                Button("修改关键词…") {
                    keywordIDs = model.selectedPhotoIDs
                    keywords = ""
                    keywordMode = 0
                    model.isShowingKeywords = true
                }
                .disabled(model.operationBlockReason(.annotation) != nil)
                if let albumID = model.appliedQuery.albumID {
                    Button("移出当前相册（保留原文件）") {
                        model.applyAnnotation(.init(albumID: albumID, albumMember: false), title: "移出相册")
                    }
                    .disabled(model.operationBlockReason(.annotation) != nil)
                }
                Divider()
                Button("移动到文件夹…") { model.prepareBatchMove() }
                    .disabled(model.operationBlockReason(.files) != nil)
                Button("分享照片…") { model.showPhotoShare() }
                    .disabled(!model.canShowPhotoShare)
                Button("批量应用预设…") { model.showColorPresets() }
                    .disabled(!model.canStartColorAction)
                Button("加入系统照片…") { model.showSystemPhotoUpload() }
                    .disabled(!model.canStartColorAction)
                Button("导出新 XMP…") { model.exportSelectedXMP() }
                    .disabled(model.operationBlockReason(.files) != nil)
                if model.colorUndoPlan != nil {
                    Divider()
                    Button("撤销批量调色") { model.undoColorBatch() }
                        .disabled(!model.canStartColorAction)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .accessibilityLabel("更多所选照片操作")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .controlSize(.small)
    }

    private var batchKeywordSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("修改 \(keywordIDs.count) 张照片的关键词")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Picker("操作", selection: $keywordMode) {
                Text("追加").tag(0)
                Text("移除").tag(1)
                Text("替换全部").tag(2)
            }
            .pickerStyle(.segmented)
            TextField("使用逗号、中文逗号或换行分隔", text: $keywords, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            if keywordMode == 2 {
                Label("替换会清除这些照片原有的关键词；支持撤销。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DarkroomPalette.warningAmber)
            }
            HStack {
                Spacer()
                Button("取消") { model.isShowingKeywords = false }
                    .keyboardShortcut(.cancelAction)
                Button("应用") {
                    if keywordMode == 2 { confirmsReplace = true } else { applyKeywords() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500)
        .confirmationDialog("替换 \(keywordIDs.count) 张照片的全部关键词？", isPresented: $confirmsReplace) {
            Button("确认替换") { applyKeywords() }
        }
    }

    private func applyKeywords() {
        let values = KeywordEdit.parse(keywords)
        let edit: KeywordEdit = keywordMode == 0 ? .append(values) : keywordMode == 1 ? .remove(values) : .replace(values)
        model.isShowingKeywords = false
        model.applyAnnotation(.init(keywords: edit), title: "批量关键词", ids: keywordIDs)
    }
}

struct SystemPhotosFloatingDock: View {
    @ObservedObject var photos: SystemPhotosModel

    private var selectedCount: Int { photos.selection.selectedIDs.count }

    var body: some View {
        if selectedCount > 0 {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text("已选 \(selectedCount) 张")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(DarkroomPalette.textPrimary)
                    Button("全选范围") { photos.selectAllPhotos() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(!photos.canAct)
                    Button("取消") { photos.selection.clear() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .foregroundStyle(DarkroomPalette.textSecondary)
                        .disabled(!photos.canAct)
                }
                .fixedSize()

                Divider().frame(height: 18).overlay(DarkroomPalette.subtleDivider)

                HStack(spacing: 8) {
                    Menu("加入相册", systemImage: "folder.badge.plus") {
                        ForEach(photos.albums.filter(\.canAdd)) { album in
                            Button(album.name) { photos.prepareMutation(.addToAlbum(id: album.id), album: album) }
                        }
                        if photos.albums.allSatisfy({ !$0.canAdd }) {
                            Text("请先新建可写入的相册")
                        }
                    }
                    Button("质量分析", systemImage: "viewfinder") { photos.prepareAnalysis() }
                    Menu {
                        if let album = photos.selectedAlbum {
                            Button("移出此相册（保留照片）…") {
                                photos.prepareMutation(.removeFromAlbum(id: album.id), album: album)
                            }
                            .disabled(!album.canRemove)
                        }
                        Button("从系统图库删除…", role: .destructive) {
                            photos.prepareMutation(.deletePhotos)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .accessibilityLabel("更多系统照片操作")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .controlSize(.small)
                .disabled(!photos.canAct || !photos.hasTargets || photos.editor?.isComposing == true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule(style: .continuous).fill(DarkroomPalette.floatingHUDFill))
                    .overlay(Capsule(style: .continuous).strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1))
            }
            .environment(\.colorScheme, .dark)
            .shadow(color: .black.opacity(0.42), radius: 14, y: 6)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(response: 0.24, dampingFraction: 0.86), value: selectedCount > 0)
        }
    }
}
