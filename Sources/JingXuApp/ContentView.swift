import JingXuCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var keywordDraft = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsPreviewFilmstrip = true
    @State private var showsPreviewInspector = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.gridSize, maximum: model.gridSize * 1.35), spacing: 12)]
    }

    var body: some View {
        Group {
            if let item = model.previewAsset {
                photoPreview(item)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                        .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
                } content: {
                    libraryGrid
                        .navigationSplitViewColumnWidth(min: 560, ideal: 760)
                } detail: {
                    inspector
                        .disabled(model.isDeleting)
                        .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 420)
                }
            }
        }
        .toolbar { toolbar }
        .modifier(PhotoSharePresentation(model: model, session: model.photoShareSession))
        .sheet(item: $model.archivePlan) { plan in
            VStack(alignment: .leading, spacing: 12) {
                Text(plan.isBatchMove == true ? "移动所选照片" : "按日期重新归档").font(.title2)
                Text(plan.isBatchMove == true ? "范围：已确认的所选照片及明确配套文件" : "范围：整个图库，不受当前目录或筛选影响").font(.callout)
                Text("\(plan.count) 个文件 · \(ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file))")
                Text("同一磁盘直接移动，不复制、不覆盖。原路径将失效，其他软件不会自动更新。视频保留原位。执行前备份图库；评分、标签和相册关系保留。")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(plan.groups.indices, id: \.self) { i in
                            Text(plan.groups[i].source.pathHint).font(.headline)
                            if let destination = plan.groups[i].destination {
                                Text("目标来源：\(destination.pathHint)").font(.headline)
                            }
                            ForEach(plan.groups[i].files.indices, id: \.self) { j in
                                Text("\(plan.groups[i].files[j].from) → \(plan.groups[i].files[j].to)").font(.caption)
                            }
                        }
                        ForEach(plan.warnings.indices, id: \.self) { Text(plan.warnings[$0]).foregroundStyle(.secondary) }
                    }.textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button("取消") { model.archivePlan = nil }.keyboardShortcut(.cancelAction)
                    Button("授权并移动") { model.confirmArchive() }.disabled(plan.count == 0)
                }
            }.padding(20).frame(width: 760, height: 520)
        }
        .background(FlagKeyboardHandler(enabled: !model.isShowingPhotoShare && !model.isDeleting && model.archivePlan == nil && !model.isShowingImport && !model.isShowingAlbumCreator && model.deletionPlan == nil && model.missingAssetPlan == nil && model.sourceMergePlan == nil && model.qualityReanalysisPlan == nil && model.errorMessage == nil && (model.previewAsset != nil || model.selectedAsset?.kind == .photo), requiresCanvasFocus: model.colorEditor != nil, navigate: model.previewNavigationEnabled ? { model.navigatePreview($0) } : nil) { flag in
            model.updateFlag(flag, advanceToNext: flag == .rejected)
        })
        .sheet(item: $model.missingAssetPlan) { plan in
            MissingAssetCleanupSheet(plan: plan).environmentObject(model)
        }
        .sheet(item: $model.qualityReanalysisPlan) { plan in
            QualityReanalysisSheet(plan: plan).environmentObject(model)
        }
        .sheet(item: $model.sourceMergePlan) { plan in
            VStack(alignment: .leading, spacing: 16) {
                Text("整理重复来源").font(.title2)
                Text("发现 \(plan.groups.count) 组；评分或旗标冲突 \(plan.conflicts) 项。保留最早来源，标签及相册关系合并；评分和旗标采用最近修改记录。执行前备份图库，不修改原文件。")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(plan.groups.indices, id: \.self) { index in
                            Text("保留：\(plan.groups[index][0].name) · \(plan.groups[index][0].id)\n\(plan.groups[index][0].pathHint)\n合并 \(plan.groups[index].count) 个来源").font(.caption).textSelection(.enabled)
                            ForEach(Array(plan.groups[index].dropFirst())) { source in
                                Text("并入：\(source.name) · \(source.id)\n\(source.pathHint)")
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                        ForEach(plan.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                }.frame(height: 230)
                HStack {
                    Spacer()
                    Button("取消") { model.sourceMergePlan = nil }.keyboardShortcut(.cancelAction)
                    Button("备份并合并") { model.confirmSourceMerge(plan) }.disabled(plan.groups.isEmpty)
                }
            }.padding(24).frame(width: 600)
        }
        .sheet(item: $model.deletionPlan) { plan in
            VStack(alignment: .leading, spacing: 16) {
                Text("清理淘汰图片").font(.title2)
                Text("将当前范围内的 \(plan.files.count) 个照片文件（\(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))）移到废纸篓。不会删除视频、配对文件或 XMP。")
                Text("可在访达中恢复文件；已清理的评分、标签、调色和相册成员不会自动恢复。")
                DisclosureGroup("查看固定文件清单") {
                    ScrollView { LazyVStack(alignment: .leading) {
                        ForEach(plan.files) { file in
                            Text((plan.sourcePaths[file.sourceID].map { $0 + "/" } ?? "") + file.relativePath)
                                .font(.caption).textSelection(.enabled)
                        }
                    } }.frame(height: 230)
                }
                HStack {
                    Spacer()
                    Button("取消") { model.deletionPlan = nil }.keyboardShortcut(.cancelAction)
                    Button("移到废纸篓", role: .destructive) { model.confirmDeletion(plan) }.disabled(plan.files.isEmpty)
                }
            }.padding(24).frame(width: 580)
        }
        .sheet(isPresented: $model.isShowingImport) {
            ImportSheet()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.isShowingAlbumCreator) {
            AlbumCreatorSheet()
                .environmentObject(model)
        }
        .alert("镜序", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .modifier(ColorWorkflowPresentation())
        .onChange(of: model.searchText) { _, _ in model.closePreview() }
        .onChange(of: model.minimumRating) { _, _ in
            model.closePreview()
            Task { await model.reloadAssets() }
        }
        .onChange(of: model.flagFilter) { _, _ in
            model.closePreview()
            Task { await model.reloadAssets() }
        }
    }

    private func photoPreview(_ item: AssetListItem) -> some View {
        VStack(spacing: 0) {
            FolderScopeBar()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZoomPreview(item: item, showsFilmstrip: $showsPreviewFilmstrip, showsInspector: $showsPreviewInspector)
                        .id(item.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if showsPreviewFilmstrip {
                        PreviewFilmstrip(items: model.previewFilmstrip, currentID: item.id)
                    }
                }
                if let editor = model.colorEditor {
                    Divider()
                    ColorEditPanel(session: editor).frame(width: 310)
                } else if showsPreviewInspector {
                    Divider()
                    inspector
                        .disabled(model.isDeleting)
                        .frame(width: 300)
                }
            }
            if model.isWorking || model.resumableQualityJob != nil {
                Divider()
                statusBar
            }
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.sidebarSelection }, set: { model.selectSidebar($0) })) {
            Section("图库") {
                ForEach(SmartCollection.allCases) { collection in
                    Label(collection.displayName, systemImage: collection.systemImage)
                        .tag(SidebarDestination.smart(collection))
                }
            }

            Section("来源") {
                ForEach(model.visibleFolderRows) { row in
                    FolderSidebarLabel(row: row)
                    .tag(row.destination)
                    .contextMenu {
                        if row.depth == 0 {
                            Button("移除来源…", role: .destructive) { model.removeSource(row.source) }
                                .disabled(model.isWorking || model.fileOperationsBlockedByShare)
                        }
                    }
                }
                Button("添加文件夹…") { model.chooseAndAddFolder() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(model.fileOperationsBlockedByShare)
            }

            Section("相册") {
                ForEach(model.albums) { album in
                    Label(album.name, systemImage: "rectangle.stack")
                        .tag(SidebarDestination.album(album.id))
                        .contextMenu {
                            Button("删除相册…", role: .destructive) { model.deleteAlbum(album) }
                                .disabled(model.isWorking || model.fileOperationsBlockedByShare)
                        }
                }
                Button("新建相册…") { model.isShowingAlbumCreator = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
        .listStyle(.sidebar)
        .disabled(!model.canChangeBrowseScope)
        .navigationTitle("镜序")
    }

    private var libraryGrid: some View {
        VStack(spacing: 0) {
            FolderScopeBar()
            filterBar
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle("批量选择", isOn: Binding(get: { model.isBatchSelecting }, set: { model.changeCheckboxMode($0) }))
                        .toggleStyle(.button)
                        .help("也可使用 ⌘ 点击增减、Shift 点击连续选择")
                    if model.isBatchSelecting || !model.selectedPhotoIDs.isEmpty {
                        Text("已选 \(model.selectedPhotoIDs.count) 张")
                        Button("全选当前照片") { model.selectVisiblePhotos() }
                        Button("清空选择") { model.clearPhotoSelection() }
                    }
                    Spacer()
                }
                HStack {
                    Button("移动到目录…") { model.prepareBatchMove() }
                        .disabled(model.selectedPhotoIDs.isEmpty || model.archivePending || model.fileOperationsBlockedByShare)
                    Button("分享…", systemImage: "square.and.arrow.up") { model.showPhotoShare() }.disabled(!model.canShowPhotoShare)
                    Button("预设与调色…") { model.showColorPresets() }.disabled(model.colorTargetIDs.isEmpty || !model.canStartColorAction)
                    Button("导出成片…") { model.showColorExport() }.disabled(model.colorTargetIDs.isEmpty || !model.canStartColorAction)
                    if model.colorUndoPlan != nil { Button("撤销批量调色") { model.undoColorBatch() }.disabled(!model.canStartColorAction) }
                    Spacer()
                }
            }
            .disabled(model.isWorking)
            .padding(8)
            Divider()
            if model.isLoadingAssets && model.assets.isEmpty {
                ProgressView("正在载入当前范围…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.assets.isEmpty {
                ContentUnavailableView {
                    Label(model.directoryHasNoDirectFiles ? "此目录没有直接文件" : (model.hasUserFilters ? "当前筛选无匹配结果" : "当前范围暂无照片"), systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(model.directoryHasNoDirectFiles ? "可开启包含子目录，查看下级文件夹中的已索引照片与视频。" : (model.hasUserFilters ? "照片可能被搜索、评分或旗标条件隐藏。" : "可添加照片文件夹、导入照片，或等待当前扫描完成。"))
                } actions: {
                    if model.directoryHasNoDirectFiles { Button("包含子目录") { model.setIncludeSubdirectories(true) } }
                    if model.hasUserFilters { Button("清除筛选") { model.clearFilters() } }
                    HStack {
                        Button("添加文件夹") { model.chooseAndAddFolder() }
                        Button("从相机卡导入") { model.isShowingImport = true }
                    }.disabled(model.fileOperationsBlockedByShare)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(model.assets) { item in
                                AssetCell(item: item, size: model.gridSize, isSelected: item.kind == .photo ? model.photoSelection.selectedIDs.contains(item.id) : model.selectedAssetID == item.id)
                                    .overlay(alignment: .topLeading) {
                                        if model.isBatchSelecting && item.kind == .photo {
                                            Image(systemName: model.photoSelection.selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(.white).padding(8)
                                                .allowsHitTesting(false)
                                        }
                                    }
                                    .overlay {
                                        GridClickHandler(label: item.fileName) { command, shift, count in
                                            model.clickAsset(item, command: command, shift: shift, count: count)
                                        }
                                    }
                                    .contextMenu {
                                        Button("在访达中显示") {
                                            model.selectedAssetID = item.id
                                            model.revealSelectedInFinder()
                                        }
                                        Menu("添加到相册") {
                                            ForEach(model.albums) { album in
                                                Button(album.name) {
                                                    model.selectedAssetID = item.id
                                                    model.addSelectedAsset(to: album)
                                                }
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: model.selectedAssetID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            statusBar
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("文件名、相机、镜头或标签", text: $model.searchText)
                .textFieldStyle(.plain)
                .onSubmit { Task { await model.reloadAssets() } }
            Divider().frame(height: 18)
            Picker("最低评分", selection: $model.minimumRating) {
                Text("全部评分").tag(0)
                ForEach(1...5, id: \.self) { Text("\($0) 星以上").tag($0) }
            }
            .labelsHidden()
            .frame(width: 115)
            Picker("旗标", selection: $model.flagFilter) {
                Text("全部旗标").tag(AssetFlag?.none)
                ForEach(AssetFlag.allCases, id: \.self) {
                    Text($0.displayName).tag(AssetFlag?.some($0))
                }
            }
            .labelsHidden()
            .frame(width: 105)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var statusBar: some View {
        HStack {
            if model.isWorking { ProgressView().controlSize(.small) }
            Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if model.isWorking {
                if model.isReanalyzing {
                    Button("暂停") { model.pauseQualityReanalysis() }.buttonStyle(.borderless)
                }
                Button("取消") { model.cancelCurrentOperation() }.buttonStyle(.borderless)
            } else if let job = model.resumableQualityJob {
                Text("重算 \(job.completed)/\(job.total)").font(.caption)
                Button("继续") { model.resumeQualityReanalysis() }.buttonStyle(.borderless)
                Button("取消重算") { model.cancelPausedQualityJob() }.buttonStyle(.borderless)
            }
            if model.previewAsset == nil {
                Image(systemName: "photo")
                Slider(value: $model.gridSize, in: 100...260)
                    .frame(width: 110)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    @ViewBuilder
    private var inspector: some View {
        if let item = model.previewAsset ?? model.selectedAsset {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LargePreview(item: item)
                        .onTapGesture { model.openPreview(item) }
                        .help("点击放大查看原图")
                    HistogramView(item: item).id(item.id)
                    Text("质量诊断基于原始照片").font(.caption2).foregroundStyle(.secondary)
                    Text(item.fileName).font(.headline).textSelection(.enabled)
                    ratingControl(item)
                    flagControl(item)
                    metadataSection(item)
                    qualitySection(item)
                    keywordSection(item)
                    Divider()
                    HStack {
                        Button("在访达中显示") { model.revealSelectedInFinder() }
                        Spacer()
                        Menu("XMP") {
                            Button("导出（跳过已有文件）") { model.exportSelectedXMP() }
                            Button("替换已有 XMP") { model.replaceSelectedXMP() }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("检查器")
            .onChange(of: model.selectedAssetID) { _, _ in keywordDraft = item.keywords.joined(separator: ", ") }
            .onAppear { keywordDraft = item.keywords.joined(separator: ", ") }
        } else {
            ContentUnavailableView("未选择照片", systemImage: "sidebar.right", description: Text("选择一项以查看元数据和整理选项。"))
        }
    }

    private func ratingControl(_ item: AssetListItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("评分").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { value in
                    Button { model.updateRating(item.rating == value ? 0 : value) } label: {
                        Image(systemName: value <= item.rating ? "star.fill" : "star")
                            .foregroundStyle(value <= item.rating ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func flagControl(_ item: AssetListItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Delete 淘汰并下一张 / U 未标记").font(.caption).foregroundStyle(.secondary)
            Picker("旗标", selection: Binding(
                get: { item.flag },
                set: { model.updateFlag($0) }
            )) {
                ForEach(AssetFlag.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isSavingFlag)
        }
    }

    private func metadataSection(_ item: AssetListItem) -> some View {
        GroupBox("拍摄信息") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                infoRow("日期", item.capturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知")
                infoRow("相机", item.cameraModel ?? "未知")
                infoRow("镜头", item.lens ?? "未知")
                if let width = item.width, let height = item.height { infoRow("尺寸", "\(width) × \(height)") }
                infoRow("类型", item.kind == .photo ? "照片" : "视频")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(2).textSelection(.enabled)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func qualitySection(_ item: AssetListItem) -> some View {
        QualityInspector(item: item)
    }

    private func keywordSection(_ item: AssetListItem) -> some View {
        GroupBox("关键词") {
            HStack {
                TextField("旅行, 人像, 夜景", text: $keywordDraft)
                    .onSubmit { saveKeywords() }
                Button("保存") { saveKeywords() }
            }
        }
    }

    private func saveKeywords() {
        model.updateKeywords(keywordDraft.split(separator: ",").map(String.init))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Group {
                if model.previewAsset == nil {
                    Button("按日期重新归档…") { model.prepareArchive() }.disabled(model.isWorking || model.archivePending)
                    Button("恢复未完成归档…") { model.resumeArchive(undo: false) }.disabled(model.isWorking || !model.archivePending)
                    Button("撤销最近一次归档…") { model.resumeArchive(undo: true) }.disabled(model.isWorking)
                    Button("清理失效索引…", systemImage: "photo.badge.exclamationmark") { model.prepareMissingAssetCleanup() }
                        .disabled(model.isWorking || model.missingAssetPlan != nil)
                    Button("整理重复来源…", systemImage: "folder.badge.gearshape") { model.prepareSourceMerge() }
                        .disabled(model.isWorking || model.sourceMergePlan != nil || model.deletionPlan != nil)
                    Button("清理淘汰图片…", systemImage: "trash") { model.prepareDeletion() }
                        .disabled(model.isWorking || model.deletionPlan != nil)
                    Button { model.chooseAndAddFolder() } label: { Label("添加文件夹", systemImage: "folder.badge.plus") }
                    Button { model.isShowingImport = true } label: { Label("从相机卡导入", systemImage: "externaldrive.badge.plus") }
                }
            }.disabled(model.fileOperationsBlockedByShare)
        }
    }
}

private struct MissingAssetCleanupSheet: View {
    @EnvironmentObject private var model: AppModel
    let plan: MissingAssetPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("清理失效索引").font(.title2)
            Text("当前来源、目录、相册和筛选范围内，确认缺失 \(plan.files.count) 项文件（含视频），不受网格显示上限限制。")
            Text("仅移除图库记录及对应评分、标签、调色、分析和相册成员关系，不操作硬盘文件。执行前备份图库并再次复核。离线或权限异常的项目保留。")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.files) { file in
                        Text((plan.sources[file.sourceID]?.pathHint ?? "") + "/" + file.relativePath)
                            .font(.caption).textSelection(.enabled)
                    }
                    if !plan.warnings.isEmpty {
                        Text("无法确认 \(plan.warnings.count) 项文件或来源，已跳过").font(.headline)
                        ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.frame(height: 260)
            HStack {
                Spacer()
                Button("取消") { model.missingAssetPlan = nil }.keyboardShortcut(.cancelAction)
                Button("备份并移除索引", role: .destructive) { model.confirmMissingAssetCleanup(plan) }
                    .disabled(plan.files.isEmpty || model.isWorking)
            }
        }.padding(24).frame(width: 620)
    }
}

private struct AssetCell: View {
    @EnvironmentObject private var model: AppModel
    let item: AssetListItem
    let size: CGFloat
    let isSelected: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(.quaternary)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                HStack(spacing: 4) {
                    if item.isColorEdited { badge("slider.horizontal.3", color: .purple).help("已调色").accessibilityLabel("已调色") }
                    if item.kind == .video { badge("video.fill", color: .blue) }
                    if item.hasPendingQualityWarning { badge("exclamationmark.triangle.fill", color: .orange) }
                    if item.similarGroupID != nil || item.issues.contains(.similarBurst) { badge("square.stack.3d.up", color: .blue) }
                    if item.flag == .rejected { badge("xmark", color: .red) }
                }
                .padding(7)
            }
            Text(item.fileName).font(.caption).lineLimit(1)
            HStack(spacing: 4) {
                if item.rating > 0 {
                    Label("\(item.rating)", systemImage: "star.fill").foregroundStyle(.yellow)
                }
                Spacer()
                Text(item.capturedAt?.formatted(date: .numeric, time: .omitted) ?? "")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(5)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        .contentShape(Rectangle())
        .task(id: "\(item.id)-\(item.fileVersion)-\(item.colorRevision)-\(Int(size))") {
            let result = await model.thumbnail(for: item, pixelSize: Int(size * 1.5))
            guard !Task.isCancelled else { return }
            image = result
        }
    }

    private func badge(_ symbol: String, color: Color) -> some View {
        Image(systemName: symbol)
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(5)
            .background(color, in: Circle())
    }
}

private struct LargePreview: View {
    @EnvironmentObject private var model: AppModel
    let item: AssetListItem
    @State private var image: NSImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFit().padding(4) }
                else { ProgressView() }
            }
            .task(id: "\(item.id)-\(item.fileVersion)-\(item.colorRevision)") {
                let result = await model.thumbnail(for: item, pixelSize: 1_024)
                guard !Task.isCancelled else { return }
                image = result
            }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: min(width, x), height: y + rowHeight), points)
    }
}
