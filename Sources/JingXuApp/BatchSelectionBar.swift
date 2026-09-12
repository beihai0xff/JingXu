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
            HStack {
                Toggle("批量选择", isOn: Binding(get: { model.isBatchSelecting }, set: { model.changeCheckboxMode($0) }))
                    .toggleStyle(.button).disabled(!model.canChangeBrowseScope)
                Button("全选本页照片") { model.selectVisiblePhotos() }.disabled(!model.canChangeBrowseScope)
                if !model.selectedPhotoIDs.isEmpty {
                    Button("清空选择") { model.clearPhotoSelection() }.disabled(!model.canChangeBrowseScope)
                }
                Spacer()
            }
            if !model.selectedPhotoIDs.isEmpty {
                HStack {
                    Text("作用于 \(model.selectedPhotoIDs.count) 张").font(.caption).bold()
                    Menu("标注") {
                        Menu("评分") { ForEach(0...5, id: \.self) { value in Button(value == 0 ? "无评分" : "\(value) 星") { model.updateRating(value) } } }
                        Button("标记淘汰") { model.updateFlag(.rejected) }
                        Button("取消淘汰标记") { model.updateFlag(.none) }
                        Button("修改关键词…") {
                            keywordIDs = model.selectedPhotoIDs; keywords = ""; keywordMode = 0
                            model.isShowingKeywords = true
                        }
                        Menu("添加到相册") { ForEach(model.albums) { album in Button(album.name) { model.addSelectedAsset(to: album) } } }
                        if let albumID = model.currentQuery().albumID {
                            Button("移出当前相册（保留原文件）") { model.applyAnnotation(.init(albumID: albumID, albumMember: false), title: "移出相册") }
                        }
                    }.disabled(model.operationBlockReason(.annotation) != nil).help(model.operationBlockReason(.annotation) ?? "批量标注支持撤销")
                    Button("比较") { model.compareSelected() }.disabled(model.selectedPhotoIDs.count != 2 || model.operationBlockReason(.browse) != nil)
                    Menu("整理与输出") {
                        Button("移动到目录…") { model.prepareBatchMove() }
                        Button("分享…") { model.showPhotoShare() }
                        Button("预设与调色…") { model.showColorPresets() }
                        Button("导出成片…") { model.showColorExport() }
                        Button("导出新 XMP…") { model.exportSelectedXMP() }
                        if model.colorUndoPlan != nil { Button("撤销批量调色") { model.undoColorBatch() } }
                    }.disabled(model.operationBlockReason(.files) != nil).help(model.operationBlockReason(.files) ?? "执行前确认固定清单")
                    Spacer()
                }
            }
        }.padding(8)
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
    private func apply() {
        let values = KeywordEdit.parse(keywords)
        let edit: KeywordEdit = keywordMode == 0 ? .append(values) : keywordMode == 1 ? .remove(values) : .replace(values)
        model.isShowingKeywords = false
        model.applyAnnotation(.init(keywords: edit), title: "批量关键词", ids: keywordIDs)
    }
}
