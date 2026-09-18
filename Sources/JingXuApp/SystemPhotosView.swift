import SwiftUI
import JingXuCore

struct SystemPhotosView: View {
    @ObservedObject var photos: SystemPhotosModel
    let leave: () -> Void
    @State private var newAlbum = ""
    @State private var rename = ""
    @State private var showCreate = false
    @State private var renameTarget: SystemPhotoAlbum?
    @State private var canvasCommand = 0
    @State private var canvasAction = "fit"

    var body: some View {
        NavigationSplitView {
            List {
                Button("返回本地图库", systemImage: "folder") { leave() }.disabled(photos.isBusy || photos.isNavigating)
                Section(photos.isIsolated ? "系统照片 · 隔离测试" : "系统照片") {
                    Button("所有照片", systemImage: "photo.on.rectangle") { photos.browse(albumID: nil) }
                    ForEach(photos.albums) { album in
                        Button { photos.browse(albumID: album.id) } label: {
                            HStack { Label(album.name, systemImage: "rectangle.stack"); Spacer(); Text("\(album.count)").foregroundStyle(.secondary) }
                        }.contextMenu {
                            Button("重命名…") { renameTarget = album; rename = album.name }.disabled(!album.canRename)
                            Button("删除相册…", role: .destructive) { photos.prepareMutation(.deleteAlbum(id: album.id), album: album) }.disabled(!album.canDelete)
                        }
                    }
                    Button("新建相册…", systemImage: "plus") { showCreate = true }.disabled(!photos.canAct)
                }.disabled(photos.isBusy || photos.isNavigating)
            }.navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            VStack(spacing: 0) {
                if !photos.connected {
                    ContentUnavailableView {
                        Label("系统照片", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("授权后查看和管理系统图库。开启 iCloud 照片后，更改由系统同步到其他设备。")
                    } actions: {
                        Button("连接系统照片") { photos.connect() }.disabled(photos.isBusy)
                        Button("打开系统设置") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!) }
                    }
                } else if let preview = photos.preview { singlePhoto(preview) }
                else { grid }
                if let conflict = photos.conflict {
                    HStack {
                        Text(conflict).font(.callout).foregroundStyle(.orange)
                        if photos.preview != nil { Button("放弃草稿并重载…") { photos.discardDraft() }.disabled(!photos.canAct) }
                    }.padding(8)
                }
                if !photos.unresolved.isEmpty {
                    ForEach(photos.unresolved) { record in
                        HStack {
                            Text("待核对：\(record.title) · \(record.names.count) 项").foregroundStyle(.orange)
                            Button("查看记录…") { photos.inspectedWrite = record }
                        }.padding(6)
                    }
                }
                HStack {
                    if photos.isBusy || photos.isNavigating { ProgressView().controlSize(.small) }
                    Text(photos.status).font(.caption).lineLimit(3).textSelection(.enabled)
                    Spacer()
                    if photos.isBusy || photos.isNavigating {
                        Button(photos.isSubmitting ? "正在提交" : "取消／暂停") { photos.cancel() }.disabled(photos.isSubmitting)
                    } else if let job = photos.job, job.isResumable {
                        Button("继续所选分析（\(job.remaining.count)）") { photos.analyze(job) }.disabled(!photos.canAct)
                        Button("结束任务…") { photos.endAnalysis() }
                    }
                }.padding(10).background(.bar)
                if let job = photos.job, !job.failures.isEmpty {
                    DisclosureGroup("未完成 \(job.failures.count) 项 · 展开查看原因") {
                        ScrollView { LazyVStack(alignment: .leading) {
                            ForEach(job.photos.filter { job.failures[$0.id] != nil }) { photo in
                                Text("\(photo.name)：\(job.failures[photo.id] ?? "")").font(.caption).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
                    }.padding(.horizontal, 12).padding(.bottom, 6)
                }
            }
            .navigationTitle(photos.selectedAlbum?.name ?? "系统照片")
        }
        .alert("新建系统相册", isPresented: $showCreate) {
            TextField("相册名称", text: $newAlbum)
            Button("取消", role: .cancel) {}
            Button("创建") { photos.prepareMutation(.createAlbum(newAlbum.trimmingCharacters(in: .whitespacesAndNewlines))); newAlbum = "" }
        }
        .alert("重命名系统相册", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("相册名称", text: $rename)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("继续") {
                if let album = renameTarget { photos.prepareMutation(.renameAlbum(id: album.id, name: rename.trimmingCharacters(in: .whitespacesAndNewlines)), album: album) }
                renameTarget = nil
            }
        }
        .sheet(item: $photos.mutationPlan) { plan in SystemPhotoMutationSheet(photos: photos, plan: plan) }
        .sheet(item: $photos.analysisPlan) { plan in
            VStack(alignment: .leading, spacing: 16) {
                Text("分析所选照片").font(.title2)
                Text("固定范围：\(plan.photos.count) 张照片。原片按需下载，只在本机分析，不修改系统照片。")
                ScrollView { LazyVStack(alignment: .leading) { ForEach(plan.photos) { Text($0.name) } } }.frame(height: 240)
                HStack { Button("取消") { photos.analysisPlan = nil }; Spacer(); Button("开始分析") { photos.analyze(plan) }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(width: 580)
        }
        .sheet(isPresented: $photos.showsPresets) { SystemPhotoPresetsSheet(photos: photos) }
        .sheet(item: $photos.inspectedWrite) { record in SystemPhotoWriteSheet(photos: photos, record: record) }
        .modifier(SystemPhotosErrorPresentation(photos: photos))
        .background(LibraryKeyboardHandler(enabled: photos.preview != nil && !photos.isBusy && !photos.isNavigating && photos.mutationPlan == nil && photos.analysisPlan == nil && !photos.showsPresets) { code, _, shift, command in
            if command && code == 6 { if shift { photos.editor?.redo() } else { photos.editor?.undo() }; return true }
            if photos.editor?.isComposing == true { if code == 53 { photos.editor?.cancelComposition(); return true }; return false }
            if code == 53 { photos.closePreview(); return true }
            if code == 123 { photos.navigate(-1); return true }
            if code == 124 { photos.navigate(1); return true }
            return false
        })
    }
    private var operations: some View {
        HStack {
            Menu("添加到相册") {
                ForEach(photos.albums.filter(\.canAdd)) { album in
                    Button(album.name) { photos.prepareMutation(.addToAlbum(id: album.id), album: album) }
                }
            }.fixedSize().disabled(photos.albums.allSatisfy { !$0.canAdd })
            if let album = photos.selectedAlbum {
                Button("移出此相册…") { photos.prepareMutation(.removeFromAlbum(id: album.id), album: album) }.disabled(!album.canRemove)
            }
            Button("分析所选…") { photos.prepareAnalysis() }
            Button("从系统图库删除…", role: .destructive) { photos.prepareMutation(.deletePhotos) }
        }.disabled(!photos.canAct || photos.targetIDs.isEmpty || photos.editor?.isComposing == true)
    }
    private var grid: some View {
        VStack(spacing: 0) {
            HStack {
                Button("选择本页") { photos.selection.selectAll(photos.items.map(\.id)) }
                Button("清除选择") { photos.selection.clear() }
                Text("已选 \(photos.selection.selectedIDs.count)").font(.caption)
                Spacer(); Button("刷新", systemImage: "arrow.clockwise") { photos.refresh() }
            }.padding(10).disabled(!photos.canAct)
            operations.padding(.horizontal, 10).padding(.bottom, 8)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165, maximum: 230))], spacing: 14) {
                    ForEach(photos.items) { photo in
                        SystemPhotoCell(photo: photo, client: photos.client, selected: photos.selection.selectedIDs.contains(photo.id))
                            .onTapGesture(count: 2) { photos.click(photo, count: 2) }
                            .onTapGesture { photos.click(photo) }
                            .accessibilityElement(children: .ignore).accessibilityLabel(photo.name)
                            .accessibilityValue(photos.selection.selectedIDs.contains(photo.id) ? "已选择" : "未选择")
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { photos.click(photo) }
                            .accessibilityAction(named: "打开照片") { photos.open(photo, index: photos.offset + (photos.items.firstIndex { $0.id == photo.id } ?? 0)) }
                    }
                }.padding(16)
            }
            HStack {
                Button("上一页") { photos.browse(albumID: photos.albumID, offset: max(0, photos.offset - 200)) }.disabled(photos.offset == 0)
                Text("\(photos.total == 0 ? 0 : photos.offset + 1)–\(min(photos.offset + photos.items.count, photos.total)) / \(photos.total) 张照片").monospacedDigit()
                Button("下一页") { photos.browse(albumID: photos.albumID, offset: photos.offset + 200) }.disabled(photos.offset + 200 >= photos.total)
            }.padding(10).disabled(!photos.canAct)
        }
    }
    private func singlePhoto(_ photo: SystemPhoto) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button("返回网格", systemImage: "square.grid.2x2") { photos.closePreview() }
                Button("上一张", systemImage: "chevron.left") { photos.navigate(-1) }.disabled(photos.previewIndex == 0)
                Text(photo.name).lineLimit(1)
                Button("下一张", systemImage: "chevron.right") { photos.navigate(1) }.disabled(photos.previewIndex + 1 >= photos.total)
                Spacer()
                Button("适合窗口") { canvasAction = "fit"; canvasCommand += 1 }
                Button("100%") { canvasAction = "actual"; canvasCommand += 1 }
                if photos.editor == nil { Button("调色") { photos.beginEditing() }.disabled(!photo.canEdit) }
                Button("构图") { photos.beginComposition() }.disabled(!photo.canEdit || photos.editor?.isComposing == true)
                if photos.editor != nil {
                    Button("保存到系统照片") { photos.saveEdit() }.buttonStyle(.borderedProminent)
                        .disabled(photos.conflict != nil || photos.editor?.isComposing == true || !photos.canAct)
                }
            }.padding(10).disabled(photos.isBusy || photos.isNavigating)
            HStack(spacing: 0) {
                if let draft = photos.editor?.composition {
                    CompositionCanvas(draft: draft)
                    CompositionPanel(draft: draft, isBusy: photos.isBusy, cancel: { photos.editor?.cancelComposition() }, apply: photos.applyComposition).frame(width: 310)
                } else {
                    ZoomScroll(image: photos.editor?.result?.image ?? photos.previewImage?.image, assetID: photo.id,
                        nativeSize: photos.editor?.result?.nativeSize ?? photos.previewImage?.nativeSize ?? .zero,
                        action: canvasAction, command: canvasCommand, onExit: photos.closePreview)
                    if let editor = photos.editor {
                        ColorEditPanel(session: editor, isWorking: photos.isBusy, isTransitioning: photos.isNavigating,
                            externallyControlled: false, copyAdjustments: { photos.copiedPatch = ColorPatch(editor.adjustments) },
                            showPresets: photos.showPresets, discardStale: photos.discardDraft).frame(width: 310)
                    } else { information(photo).frame(width: 270) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if photos.isNavigating { ProgressView("正在读取照片…").padding(8) }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(photos.items) { item in
                        SystemPhotoCell(photo: item, client: photos.client, selected: item.id == photo.id, small: true)
                            .frame(width: 86).onTapGesture { photos.open(item, index: photos.offset + (photos.items.firstIndex { $0.id == item.id } ?? 0)) }
                            .accessibilityElement(children: .ignore).accessibilityLabel(item.name).accessibilityAddTraits(.isButton)
                            .accessibilityAction { photos.open(item, index: photos.offset + (photos.items.firstIndex { $0.id == item.id } ?? 0)) }
                    }
                }.padding(8)
            }.frame(height: 86).disabled(photos.isBusy || photos.isNavigating)
            operations.padding(8)
        }
    }
    private func information(_ photo: SystemPhoto) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("照片信息").font(.title3)
                Text("\(photo.width) × \(photo.height)")
                if let date = photo.capturedAt { Text(date.formatted()) }
                if photo.isLivePhoto { Text("Live Photo · 仅显示静态画面，保留动态内容，不支持调色回写。").font(.caption) }
                Button("放弃本机草稿并重载…") { photos.discardDraft() }.disabled(!photos.canAct)
                Divider(); Text("本机原片质量分析").font(.headline)
                if let failure = photos.job?.failures[photo.id] {
                    Text("本次分析未完成：\(failure)").foregroundStyle(.orange)
                }
                if let result = photos.analysis {
                    if photos.job?.failures[photo.id] != nil { Text("以下为上次完成的结果").font(.caption) }
                    Text(result.status.title)
                    if let diagnostic = result.diagnostic {
                        ForEach(diagnostic.reasons, id: \.self) { Text($0).font(.caption) }
                        if let failure = diagnostic.featurePrintFailure { Text(failure).font(.caption).foregroundStyle(.orange) }
                    }
                    Text("高光溢出 \(result.highlightClipping, format: .percent.precision(.fractionLength(1)))")
                    Text("暗部压黑 \(result.shadowClipping, format: .percent.precision(.fractionLength(1)))")
                    Text("相似连拍：\(result.similarGroupID == nil ? "本批未分组" : "已分组")")
                    Text("人工审核：\(result.suggestionState == .accepted ? "已确认" : result.suggestionState == .ignored ? "已忽略" : "待审核")")
                    HStack { Button("确认问题") { photos.review(.accepted) }; Button("忽略") { photos.review(.ignored) } }.disabled(!photos.canAct)
                    Text("基于解码预览统计，不代表 RAW 传感器数据。").font(.caption).foregroundStyle(.secondary)
                } else { Text("尚未完成分析").foregroundStyle(.secondary) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SystemPhotoCell: View {
    let photo: SystemPhoto
    let client: any PhotoLibraryClient
    let selected: Bool
    var small = false
    @State private var image: CGImage?
    @State private var failure: String?
    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Color.secondary.opacity(0.12)
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                else if failure != nil { Image(systemName: "icloud.slash").foregroundStyle(.secondary) }
                else { ProgressView().controlSize(.small) }
            }.frame(height: small ? 60 : 135).clipShape(RoundedRectangle(cornerRadius: 6))
            if !small { Text(photo.name).font(.caption).lineLimit(1) }
        }.padding(5).background(selected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle()).help(failure ?? photo.name)
            .task(id: "\(photo.id)-\(photo.modifiedAt?.timeIntervalSince1970 ?? 0)") {
                image = nil; failure = nil
                do {
                    let result = try await client.image(id: photo.id, pixelSize: small ? 172 : 460)
                    try Task.checkCancellation(); image = result.image
                } catch is CancellationError {} catch { failure = error.localizedDescription }
            }
    }
}

private struct SystemPhotoMutationSheet: View {
    @ObservedObject var photos: SystemPhotosModel
    let plan: SystemPhotoMutationPlan
    private var description: (String, String) {
        switch plan.operation {
        case .createAlbum(let name): ("创建相册“\(name)”", "在系统照片中创建普通相册。")
        case .renameAlbum(_, let name): ("重命名相册", "“\(plan.albumName ?? "")” → “\(name)”")
        case .deleteAlbum: ("删除相册“\(plan.albumName ?? "")”", "仅删除相册及其成员关系，保留全部 \(plan.albumCount ?? 0) 项照片和视频。")
        case .addToAlbum: ("添加到“\(plan.albumName ?? "")”", "将所选照片加入此相册，保留其他相册中的归属。")
        case .removeFromAlbum: ("移出“\(plan.albumName ?? "")”", "仅移出此相册，照片保留在系统图库和其他相册。")
        case .deletePhotos: ("从系统图库删除 \(plan.photos.count) 张照片", "开启 iCloud 照片后，会同步删除其他设备中的照片。可在系统「最近删除」中恢复；镜序本地文件不受影响。")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(description.0).font(.title2); Text(description.1)
            ScrollView { LazyVStack(alignment: .leading) { ForEach(plan.photos) { Text($0.name).font(.caption) } } }.frame(height: 230)
            HStack { Button("取消") { photos.mutationPlan = nil }; Spacer(); Button("确认操作") { photos.confirmMutation() }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 600)
    }
}

struct SystemPhotosUploadSheet: View {
    @ObservedObject var photos: SystemPhotosModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("加入系统照片").font(.title2)
            Text("源文件保留；系统照片可能将内容（含拍摄位置）同步到 iCloud。")
            if !photos.connected {
                Button("授权并连接系统照片") { photos.connect() }.disabled(photos.isBusy)
            }
            Picker("内容", selection: $photos.uploadMode) { Text("原片").tag(PhotoShareMode.original); Text("调色 JPEG").tag(PhotoShareMode.jpeg) }
                .pickerStyle(.segmented).disabled(photos.isBusy || photos.preparedUpload != nil)
            Picker("目标相册", selection: $photos.uploadAlbumID) {
                Text("仅加入图库").tag(String?.none)
                ForEach(photos.albums.filter(\.canAdd)) { Text($0.name).tag(Optional($0.id)) }
            }.disabled(photos.isBusy || photos.preparedUpload != nil)
            ScrollView {
                LazyVStack(alignment: .leading) {
                    if let plan = photos.preparedUpload { ForEach(Array(plan.files.enumerated()), id: \.offset) { Text($0.element.name).font(.caption) } }
                    else { ForEach(photos.uploadSnapshots ?? [], id: \.asset.id) { Text($0.asset.fileName).font(.caption) } }
                }
            }.frame(height: 240)
            Text(photos.status).font(.caption).foregroundStyle(.secondary)
            ForEach(photos.unresolved) { record in Button("核对上次提交：\(record.title)…") { photos.inspectedWrite = record } }
            HStack {
                Button(photos.isBusy ? "取消准备" : "关闭") { photos.cancelUpload() }.disabled(photos.isSubmitting)
                Spacer()
                if photos.isBusy { ProgressView().controlSize(.small) }
                if photos.preparedUpload != nil {
                    Button("重新准备") { photos.preparedUpload = nil }.disabled(photos.isBusy)
                    Button("确认加入系统照片") { photos.confirmUpload() }.disabled(!photos.canAct).buttonStyle(.borderedProminent)
                } else { Button("准备文件") { photos.prepareUpload() }.disabled(!photos.canAct).buttonStyle(.borderedProminent) }
            }
        }.padding(24).frame(width: 650).interactiveDismissDisabled(photos.isBusy)
            .sheet(item: $photos.inspectedWrite) { record in SystemPhotoWriteSheet(photos: photos, record: record) }
            .modifier(SystemPhotosErrorPresentation(photos: photos))
    }
}

private struct SystemPhotoWriteSheet: View {
    @ObservedObject var photos: SystemPhotosModel
    let record: SystemPhotoWriteRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(record.title).font(.title2)
            Text(record.submittedAt.formatted()).font(.caption)
            Text(record.detail ?? "上次提交未收到完整结果，请在系统照片中核对。")
            ScrollView { LazyVStack(alignment: .leading) {
                ForEach(Array(record.names.enumerated()), id: \.offset) { Text($0.element) }
                if !record.createdIDs.isEmpty {
                    Divider(); Text("系统返回的照片标识").font(.caption)
                    ForEach(record.createdIDs, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 240)
            HStack {
                Button("关闭") { photos.inspectedWrite = nil }; Spacer()
                Button("已在系统照片中核对…") { photos.acknowledge(record); photos.inspectedWrite = nil }
            }
        }.padding(24).frame(width: 600)
    }
}

private struct SystemPhotoPresetsSheet: View {
    @ObservedObject var photos: SystemPhotosModel
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("调色预设").font(.title2)
            if let patch = photos.copiedPatch { Button("应用复制的参数") { photos.applyPreset(patch) } }
            List(photos.presets) { preset in Button(preset.name) { do { photos.applyPreset(try preset.patch) } catch { photos.error = error.localizedDescription } } }
            HStack { TextField("保存当前调整为预设", text: $name); Button("保存") { photos.savePreset(name: name) }.disabled(name.isEmpty || photos.isBusy) }
            HStack { Spacer(); Button("关闭") { photos.showsPresets = false } }
        }.padding(24).frame(width: 440, height: 430)
    }
}

private struct SystemPhotosErrorPresentation: ViewModifier {
    @ObservedObject var photos: SystemPhotosModel
    func body(content: Content) -> some View {
        content.alert("系统照片", isPresented: Binding(get: { photos.error != nil }, set: { if !$0 { photos.error = nil } })) {
            Button("好") { photos.error = nil }
        } message: { Text(photos.error ?? "") }
    }
}
