import AppKit
import SwiftUI
import JingXuCore

struct SystemPhotosView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var photos: SystemPhotosModel
    let leave: () -> Void
    @State private var newAlbum = ""
    @State private var rename = ""
    @State private var showCreate = false
    @State private var renameTarget: SystemPhotoAlbum?
    @State private var canvasCommand = 0
    @State private var canvasAction = "fit"
    @State private var showsInspector = false
    @State private var showsFilmstrip = true
    @State private var showsViewOptions = false
    @State private var showsShare = false
    @State private var shareImage: CGImage?
    @State private var infoTab = PhotoInspectorTab.information

    var body: some View {
        Group {
            if photos.preview != nil { content }
            else {
                NavigationSplitView {
                    sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
                } detail: { content }
                .navigationSplitViewStyle(.balanced)
                .toolbar {
                    ToolbarItemGroup {
                        Button("刷新", systemImage: "arrow.clockwise") { photos.refresh() }.disabled(!photos.canAct)
                        Button("视图选项", systemImage: "slider.horizontal.3") { showsViewOptions.toggle() }
                            .labelStyle(.iconOnly)
                            .popover(isPresented: $showsViewOptions) {
                                GridViewOptions(size: $model.gridSize, showsFileNames: $model.showsFileNames).padding(18)
                            }
                    }
                }
            }
        }
        .sheet(isPresented: $showsShare) {
            if let shareImage {
                let image = Image(decorative: shareImage, scale: 1)
                VStack(alignment: .leading, spacing: 18) {
                    Text("分享当前画面").font(.title2)
                    Text("1 张静态图片 · 包含画面中当前显示的调整").font(.callout)
                    image.resizable().scaledToFit().frame(width: 400, height: 260)
                    Text("不包含 Live Photo 动态内容；发送由所选系统分享服务处理。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("关闭") { showsShare = false }
                        Spacer()
                        ShareLink(item: image, preview: SharePreview(photos.preview?.name ?? "照片", image: image)) {
                            Label("系统分享…", systemImage: "square.and.arrow.up")
                        }
                    }
                }.padding(24)
            }
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
        .background(LibraryKeyboardHandler(enabled: photos.connected && !photos.isBusy && !photos.isNavigating && photos.mutationPlan == nil && photos.analysisPlan == nil && !photos.showsPresets && !showsShare) { code, text, shift, command in
            if command {
                if text == "a", photos.preview == nil { photos.selectAllPhotos(); return true }
                if text == "z", photos.editor != nil { if shift { photos.editor?.redo() } else { photos.editor?.undo() }; return true }
                return false
            }
            if code == 53 { photos.leavePreviewLevel(); return true }
            if photos.editor?.isComposing == true { return false }
            if photos.preview != nil {
                if code == 123 || code == 124 { photos.navigate(code == 123 ? -1 : 1); return true }
            } else {
                if [123, 124, 125, 126].contains(code) {
                    photos.moveGridFocus(by: code == 123 ? -1 : code == 124 ? 1 : code == 125 ? model.gridColumns : -model.gridColumns, extending: shift)
                    return true
                }
                if code == 49, let item = photos.items.first(where: { $0.id == photos.selection.focusID }) {
                    photos.open(item, index: photos.offset + (photos.items.firstIndex { $0.id == item.id } ?? 0)); return true
                }
            }
            return false
        })
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            WorkspaceSwitcher(systemPhotos: true, selectLocal: leave, selectSystem: {})
                .disabled(photos.isBusy || photos.isNavigating)
            List {
                Section("图库") {
                    Button("所有照片", systemImage: "photo.on.rectangle") { photos.browse(albumID: nil) }
                        .listRowBackground(photos.albumID == nil ? Color.accentColor.opacity(0.12) : .clear)
                }
                Section("相册") {
                    ForEach(photos.albums) { album in
                        Button { photos.browse(albumID: album.id) } label: {
                            HStack { Label(album.name, systemImage: "rectangle.stack"); Spacer(); Text("\(album.count)").foregroundStyle(.secondary) }
                        }
                        .listRowBackground(photos.albumID == album.id ? Color.accentColor.opacity(0.12) : .clear)
                        .contextMenu {
                            Button("重命名…") { renameTarget = album; rename = album.name }.disabled(!album.canRename)
                            Button("删除相册…", role: .destructive) { photos.prepareMutation(.deleteAlbum(id: album.id), album: album) }.disabled(!album.canDelete)
                        }
                    }
                    Button("新建相册…", systemImage: "plus") { showCreate = true }.disabled(!photos.canAct)
                }
            }.listStyle(.sidebar).disabled(photos.isBusy || photos.isNavigating)
            Label(photos.isIsolated ? "隔离测试图库" : photos.connected ? "已连接系统照片" : "尚未连接系统照片", systemImage: "icloud")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }.navigationTitle("镜序")
    }

    private var content: some View {
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
            } else if let photo = photos.preview { singlePhoto(photo) }
            else { grid }
            if let conflict = photos.conflict {
                HStack {
                    Text(conflict).font(.callout).foregroundStyle(.orange)
                    if photos.preview != nil { Button("放弃草稿并重载…") { photos.discardDraft() }.disabled(!photos.canAct) }
                }.padding(8)
            }
            ForEach(photos.unresolved) { record in
                HStack {
                    Text("待核对：\(record.title) · \(record.names.count) 项").foregroundStyle(.orange)
                    Button("查看记录…") { photos.inspectedWrite = record }
                }.padding(6)
            }
            HStack {
                if photos.isBusy || photos.isNavigating { ProgressView().controlSize(.small) }
                Text(photos.status).font(.caption).lineLimit(2).help(photos.status)
                Spacer()
                if photos.isBusy || photos.isNavigating {
                    Button(photos.isSubmitting ? "正在提交" : "取消／暂停") { photos.cancel() }.disabled(photos.isSubmitting)
                } else if let job = photos.job, job.isResumable {
                    Button("继续分析（\(job.remaining.count)）") { photos.analyze(job) }.disabled(!photos.canAct)
                    Button("结束任务…") { photos.endAnalysis() }
                }
                if photos.preview == nil { Text("已载入 \(photos.items.count) / \(photos.total) 张").font(.caption).foregroundStyle(.secondary) }
            }.padding(10).background(.bar)
            if let job = photos.job, !job.failures.isEmpty {
                DisclosureGroup("未完成 \(job.failures.count) 项 · 查看原因") {
                    ScrollView { LazyVStack(alignment: .leading) {
                        ForEach(job.photos.filter { job.failures[$0.id] != nil }) { photo in
                            Text("\(photo.name)：\(job.failures[photo.id] ?? "")").font(.caption).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 110)
                }.padding(12)
            }
        }
    }

    private var operations: some View {
        Group {
            Menu("加入相册", systemImage: "folder.badge.plus") {
                ForEach(photos.albums.filter(\.canAdd)) { album in
                    Button(album.name) { photos.prepareMutation(.addToAlbum(id: album.id), album: album) }
                }
                if photos.albums.allSatisfy({ !$0.canAdd }) { Text("请先新建可写入的相册") }
            }
            Button("分析", systemImage: "viewfinder") { photos.prepareAnalysis() }
            Menu {
                if let album = photos.selectedAlbum {
                    Button("移出此相册（保留照片）…") { photos.prepareMutation(.removeFromAlbum(id: album.id), album: album) }.disabled(!album.canRemove)
                }
                Button("从系统图库删除…", role: .destructive) { photos.prepareMutation(.deletePhotos) }
            } label: { Image(systemName: "ellipsis").accessibilityLabel("更多系统照片操作") }.menuIndicator(.hidden)
        }.disabled(!photos.canAct || photos.targetIDs.isEmpty || photos.editor?.isComposing == true)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(photos.selectedAlbum?.name ?? "所有照片").font(.title2.weight(.medium))
                    Text("\(photos.total) 张照片 · 按拍摄时间").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if photos.isSelecting { Button("全选当前范围") { photos.selectAllPhotos() }.buttonStyle(.borderless) }
                Button(photos.isSelecting ? "完成选择" : "选择", systemImage: photos.isSelecting ? "checkmark" : "checkmark.circle") { photos.isSelecting.toggle() }
            }.padding(20).disabled(!photos.canAct)
            if !photos.selection.selectedIDs.isEmpty {
                HStack(spacing: 12) {
                    Text("已选 \(photos.selection.selectedIDs.count) 张").font(.callout.weight(.medium))
                    Button("取消选择") { photos.selection.clear(); photos.isSelecting = false }.buttonStyle(.borderless)
                    Spacer(); operations
                }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 20).padding(.bottom, 14).disabled(!photos.canAct)
            }
            if let error = photos.browseError {
                HStack { Text(error).font(.caption).foregroundStyle(.orange); Spacer(); Button("重试") { photos.retryBrowse() } }.padding(12)
            }
            if photos.items.isEmpty {
                ContentUnavailableView("此范围暂无照片", systemImage: "photo.on.rectangle", description: Text("可切换相册，或从本地图库选择照片加入系统照片。"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if photos.offset > 0 { loadMore(before: true) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: model.gridSize, maximum: model.gridSize * 1.35), spacing: 12)], spacing: 14) {
                                ForEach(photos.items) { photo in
                                    SystemPhotoCell(photo: photo, client: photos.client, selected: photos.selection.selectedIDs.contains(photo.id),
                                        showsName: model.showsFileNames, selecting: photos.isSelecting)
                                        .overlay {
                                            GridClickHandler(label: photo.name) { command, shift, count in photos.click(photo, command: command, shift: shift, count: count) }
                                        }
                                        .id(photo.id)
                                }
                            }.padding(20)
                                .background(GeometryReader { geometry in
                                    Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                                        model.gridColumns = max(1, Int((width - 28) / (model.gridSize + 12)))
                                    }
                                    .onChange(of: model.gridSize) { _, _ in model.gridColumns = max(1, Int((geometry.size.width - 28) / (model.gridSize + 12))) }
                                })
                            if photos.offset + photos.items.count < photos.total { loadMore(before: false) }
                            else { Text("已显示当前范围全部照片").font(.caption).foregroundStyle(.secondary).padding(16) }
                        }
                    }.onChange(of: photos.selection.focusID, initial: true) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
        }
    }

    private func loadMore(before: Bool) -> some View {
        BrowseLoadMore(title: before ? "载入前面的照片" : "继续滚动浏览",
            isLoading: photos.isLoadingMore, canLoad: photos.canAct && photos.browseError == nil,
            load: { photos.loadMore(before: before) })
            .id("\(before)-\(photos.items.count)-\(photos.offset)")
    }

    private var displayedImage: CGImage? { photos.presetPreview?.image ?? photos.editor?.result?.image ?? photos.previewImage?.image }
    private func singlePhoto(_ photo: SystemPhoto) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("返回", systemImage: "chevron.left") { photos.leavePreviewLevel() }
                Divider().frame(height: 16)
                Button { photos.navigate(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上一张").disabled(photos.previewIndex == 0)
                Text(photo.name).font(.callout).lineLimit(1).help(photo.name)
                Button { photos.navigate(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下一张").disabled(photos.previewIndex + 1 >= photos.total)
                Spacer()
                if photos.editor == nil {
                    Button("编辑", systemImage: "slider.horizontal.3") { photos.beginEditing() }.buttonStyle(.borderedProminent).disabled(!photo.canEdit)
                    Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }.accessibilityLabel("照片详情")
                } else {
                    Button("保存到系统照片") { photos.saveEdit() }.buttonStyle(.borderedProminent)
                        .disabled(photos.conflict != nil || photos.editor?.isComposing == true || photos.presetPreview != nil || !photos.canAct)
                    Button("完成") { photos.finishEditing() }.disabled(photos.editor?.isComposing == true)
                }
                Button { shareImage = displayedImage; showsShare = shareImage != nil } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("分享当前画面").disabled(displayedImage == nil || photos.editor?.isRendering == true || photos.presetPreview != nil)
                Menu { Button("分析当前照片…") { photos.prepareAnalysis() } } label: { Image(systemName: "ellipsis") }.menuIndicator(.hidden)
            }.buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 16).frame(height: 52)
                .disabled(photos.isBusy || photos.isNavigating)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let draft = photos.editor?.composition { CompositionCanvas(draft: draft) }
                    else {
                        ZoomScroll(image: displayedImage, assetID: photo.id,
                            nativeSize: photos.presetPreview?.nativeSize ?? photos.editor?.result?.nativeSize ?? photos.previewImage?.nativeSize ?? .zero,
                            action: canvasAction, command: canvasCommand, onExit: photos.leavePreviewLevel)
                    }
                    HStack {
                        Button("适应") { canvasAction = "fit"; canvasCommand += 1 }
                        Button("100%") { canvasAction = "actual"; canvasCommand += 1 }
                        Spacer()
                        Text("\(photos.previewIndex + 1) / \(photos.total) 张").font(.caption).foregroundStyle(.secondary)
                        Button { showsFilmstrip.toggle() } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }.accessibilityLabel("切换胶片栏")
                    }.buttonStyle(.borderless).controlSize(.small).padding(12).disabled(photos.editor?.isComposing == true)
                    if showsFilmstrip { filmstrip(current: photo) }
                }
                if let editor = photos.editor {
                    Divider()
                    PhotoEditingSidebar(session: editor, presetPreview: $photos.presetPreview, presets: photos.presets,
                        isWorking: photos.isBusy, isTransitioning: photos.isNavigating, externallyControlled: false,
                        beginComposition: photos.beginComposition, applyComposition: photos.applyComposition,
                        copyAdjustments: { photos.copiedPatch = ColorPatch(editor.adjustments) },
                        managePresets: photos.showPresets, discardStale: photos.discardDraft).id(editor.snapshot.id).frame(width: 290)
                } else if showsInspector { Divider(); information(photo).frame(width: 270) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if photos.isNavigating { ProgressView("正在读取照片…").padding(8) }
        }
    }
    private func filmstrip(current: SystemPhoto) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(photos.items) { item in
                        Button { photos.open(item, index: photos.offset + (photos.items.firstIndex { $0.id == item.id } ?? 0)) } label: {
                            SystemPhotoCell(photo: item, client: photos.client, selected: item.id == current.id, small: true).frame(width: 76)
                        }.buttonStyle(.plain).accessibilityLabel("查看 " + item.name).id(item.id)
                    }
                }.padding(8)
            }.frame(height: 76).disabled(photos.isBusy || photos.isNavigating)
                .onAppear { proxy.scrollTo(current.id, anchor: .center) }
                .onChange(of: current.id) { _, id in proxy.scrollTo(id, anchor: .center) }
        }
    }
    private func information(_ photo: SystemPhoto) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("照片详情", selection: $infoTab) {
                    ForEach(PhotoInspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Text(photo.name).font(.headline)
                if infoTab == .information {
                Text("\(photo.width) × \(photo.height)")
                if let date = photo.capturedAt { Text(date.formatted()) }
                if photo.isLivePhoto { Text("Live Photo · 仅显示静态画面，保留动态内容，不支持调色回写。").font(.caption) }
                Button("放弃本机草稿并重载…") { photos.discardDraft() }.disabled(!photos.canAct)
                } else {
                Text("本机原片质量分析").font(.headline)
                Button("分析当前照片") { photos.prepareAnalysis() }.disabled(!photos.canAct)
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
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SystemPhotoCell: View {
    let photo: SystemPhoto
    let client: any PhotoLibraryClient
    let selected: Bool
    var small = false
    var showsName = true
    var selecting = false
    @State private var image: CGImage?
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                ZStack {
                    Color.secondary.opacity(0.08)
                    if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                    else if failure != nil { Image(systemName: "icloud.slash").foregroundStyle(.secondary) }
                    else { ProgressView().controlSize(.small) }
                }.aspectRatio(1.15, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
                if selecting || (selected && !small) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(.white)
                        .shadow(radius: 2).padding(7)
                }
            }
            if !small && showsName { Text(photo.name).font(.caption).lineLimit(1) }
        }.padding(4)
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle()).help(failure ?? photo.name)
            .task(id: "\(photo.id)-\(photo.modifiedAt?.timeIntervalSince1970 ?? 0)-\(small)") {
                image = nil; failure = nil
                do {
                    let result = try await client.image(id: photo.id, pixelSize: small ? 172 : 520)
                    try Task.checkCancellation(); image = result.image
                } catch is CancellationError {} catch { if !Task.isCancelled { failure = error.localizedDescription } }
            }.onDisappear { image = nil }
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
            if !plan.photos.isEmpty {
                Text("固定范围：\(plan.photos.count) 张照片").font(.callout.weight(.medium))
                ScrollView { LazyVStack(alignment: .leading) { ForEach(plan.photos) { Text($0.name).font(.caption) } } }.frame(height: 230)
            }
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
