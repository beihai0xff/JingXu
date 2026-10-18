import SwiftUI
import JingXuCore

struct BatchSelectionBar: View {
    @EnvironmentObject private var model: AppModel
    @State private var keywordIDs: [String] = []
    @State private var keywords = ""
    @State private var keywordMode = 0
    @State private var confirmsReplace = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.selectedPhotoIDs.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { selectionSummary; Spacer(minLength: 8); actions }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { selectionSummary; Spacer() }
                        HStack(spacing: 10) { actions; Spacer(minLength: 0) }
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20).padding(.bottom, 14)
            }
        }
        .sheet(isPresented: $model.isShowingKeywords) {
            VStack(alignment: .leading, spacing: 14) {
                Text("修改 \(keywordIDs.count) 张照片的关键词").font(.title2)
                Picker("操作", selection: $keywordMode) {
                    Text("追加").tag(0); Text("移除").tag(1); Text("替换全部").tag(2)
                }.pickerStyle(.segmented)
                TextField("使用逗号、中文逗号或换行分隔", text: $keywords, axis: .vertical).lineLimit(3...6)
                if keywordMode == 2 { Text("替换会清除这些照片原有的关键词；可撤销。").foregroundStyle(.orange) }
                HStack {
                    Spacer()
                    Button("取消") { model.isShowingKeywords = false }.keyboardShortcut(.cancelAction)
                    Button("应用") {
                        if keywordMode == 2 { confirmsReplace = true } else { apply() }
                    }
                }
            }.padding(24).frame(width: 520)
            .confirmationDialog("替换 \(keywordIDs.count) 张照片的全部关键词？", isPresented: $confirmsReplace) {
                Button("确认替换") { apply() }
            }
        }
    }
    private var selectionSummary: some View {
        HStack(spacing: 12) {
            Text("已选 \(model.selectedPhotoIDs.count) 张").font(.callout.weight(.medium)).monospacedDigit()
            Button("取消选择") { model.clearPhotoSelection(); model.changeCheckboxMode(false) }
                .buttonStyle(.borderless).disabled(!model.canChangeBrowseScope)
        }.fixedSize()
    }

    private var actions: some View {
        Group {
            if model.selectedPhotoIDs.count == 1, let item = model.selectedAsset {
                Button("查看", systemImage: "arrow.up.left.and.arrow.down.right") { model.openPreview(item) }
                    .disabled(!model.canChangeBrowseScope)
            }
            Menu("评分", systemImage: "star") {
                ForEach(0...5, id: \.self) { value in
                    Button(value == 0 ? "无评分" : "\(value) 星") { model.updateRating(value) }
                }
            }.disabled(model.operationBlockReason(.annotation) != nil)
            Button("淘汰", systemImage: "xmark.circle") { model.updateFlag(.rejected) }
                .help("标记淘汰，保留原文件；可撤销")
                .disabled(model.operationBlockReason(.annotation) != nil)
            if model.selectedPhotoIDs.count == 2 {
                Button("比较", systemImage: "rectangle.split.2x1") { model.compareSelected() }
                    .disabled(model.operationBlockReason(.browse) != nil)
            }
            Menu("加入相册", systemImage: "folder.badge.plus") {
                ForEach(model.albums) { album in Button(album.name) { model.addSelectedAsset(to: album) } }
                if model.albums.isEmpty { Text("请先在侧边栏新建相册") }
            }.disabled(model.operationBlockReason(.annotation) != nil)
            Button("导出", systemImage: "square.and.arrow.down") { model.showColorExport() }
                .disabled(!model.canStartColorAction)
            Menu {
                Button("取消淘汰标记") { model.updateFlag(.none) }.disabled(model.operationBlockReason(.annotation) != nil)
                Button("修改关键词…") {
                    keywordIDs = model.selectedPhotoIDs; keywords = ""; keywordMode = 0
                    model.isShowingKeywords = true
                }.disabled(model.operationBlockReason(.annotation) != nil)
                if let albumID = model.appliedQuery.albumID {
                    Button("移出当前相册（保留原文件）") {
                        model.applyAnnotation(.init(albumID: albumID, albumMember: false), title: "移出相册")
                    }.disabled(model.operationBlockReason(.annotation) != nil)
                }
                Divider()
                Button("移动到文件夹…") { model.prepareBatchMove() }.disabled(model.operationBlockReason(.files) != nil)
                Button("分享照片…") { model.showPhotoShare() }.disabled(!model.canShowPhotoShare)
                Button("批量应用预设…") { model.showColorPresets() }.disabled(!model.canStartColorAction)
                Button("加入系统照片…") { model.showSystemPhotoUpload() }.disabled(!model.canStartColorAction)
                Button("导出新 XMP…") { model.exportSelectedXMP() }.disabled(model.operationBlockReason(.files) != nil)
                if model.colorUndoPlan != nil {
                    Button("撤销批量调色") { model.undoColorBatch() }.disabled(!model.canStartColorAction)
                }
            } label: { Image(systemName: "ellipsis").accessibilityLabel("更多所选照片操作") }
                .menuIndicator(.hidden).fixedSize()
        }.controlSize(.small)
    }

    private func apply() {
        let values = KeywordEdit.parse(keywords)
        let edit: KeywordEdit = keywordMode == 0 ? .append(values) : keywordMode == 1 ? .remove(values) : .replace(values)
        model.isShowingKeywords = false
        model.applyAnnotation(.init(keywords: edit), title: "批量关键词", ids: keywordIDs)
    }
}
