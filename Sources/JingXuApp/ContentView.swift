import JingXuCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var keywordDraft = ""

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.gridSize, maximum: model.gridSize * 1.35), spacing: 12)]
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            libraryGrid
                .navigationSplitViewColumnWidth(min: 560, ideal: 760)
        } detail: {
            inspector
                .navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 420)
        }
        .toolbar { toolbar }
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
        .onChange(of: model.sidebarSelection) { _, _ in Task { await model.reloadAssets() } }
        .onChange(of: model.minimumRating) { _, _ in Task { await model.reloadAssets() } }
        .onChange(of: model.flagFilter) { _, _ in Task { await model.reloadAssets() } }
    }

    private var sidebar: some View {
        List(selection: $model.sidebarSelection) {
            Section("图库") {
                ForEach(SmartCollection.allCases) { collection in
                    Label(collection.displayName, systemImage: collection.systemImage)
                        .tag(SidebarDestination.smart(collection))
                }
            }

            Section("来源") {
                ForEach(model.sources) { source in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                            if !source.isOnline { Text("离线").font(.caption).foregroundStyle(.secondary) }
                        }
                    } icon: {
                        Image(systemName: source.isOnline ? "folder" : "externaldrive.badge.xmark")
                    }
                    .tag(SidebarDestination.source(source.id))
                }
                Button("添加文件夹…") { model.chooseAndAddFolder() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }

            Section("相册") {
                ForEach(model.albums) { album in
                    Label(album.name, systemImage: "rectangle.stack")
                        .tag(SidebarDestination.album(album.id))
                }
                Button("新建相册…") { model.isShowingAlbumCreator = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("镜序")
    }

    private var libraryGrid: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            if model.assets.isEmpty {
                ContentUnavailableView {
                    Label("图库为空", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("添加本地照片文件夹，或从相机卡安全导入。")
                } actions: {
                    HStack {
                        Button("添加文件夹") { model.chooseAndAddFolder() }
                        Button("从相机卡导入") { model.isShowingImport = true }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(model.assets) { item in
                            AssetCell(item: item, size: model.gridSize, isSelected: model.selectedAssetID == item.id)
                                .onTapGesture { model.selectedAssetID = item.id }
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
                Text("保留").tag(AssetFlag?.some(.picked))
                Text("淘汰").tag(AssetFlag?.some(.rejected))
                Text("未标记").tag(AssetFlag?.some(.none))
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
                Button("取消") { model.cancelCurrentOperation() }.buttonStyle(.borderless)
            }
            Image(systemName: "photo")
            Slider(value: $model.gridSize, in: 100...260)
                .frame(width: 110)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    @ViewBuilder
    private var inspector: some View {
        if let item = model.selectedAsset {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LargePreview(item: item)
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
            Text("旗标").font(.caption).foregroundStyle(.secondary)
            Picker("旗标", selection: Binding(
                get: { item.flag },
                set: { model.updateFlag($0) }
            )) {
                ForEach(AssetFlag.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
        if !item.issues.isEmpty {
            GroupBox("质量建议") {
                VStack(alignment: .leading, spacing: 10) {
                    FlowLayout(spacing: 6) {
                        ForEach(item.issues, id: \.self) { issue in
                            Label(issue.displayName, systemImage: issue == .similarBurst ? "square.stack.3d.up" : "exclamationmark.triangle")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.orange.opacity(0.14), in: Capsule())
                        }
                    }
                    if item.suggestionState == .pending {
                        HStack {
                            Button("标记淘汰") { model.resolveSuggestion(accepted: true) }
                            Button("忽略") { model.resolveSuggestion(accepted: false) }
                        }
                    } else {
                        Text(item.suggestionState == .accepted ? "已接受建议" : "已忽略建议")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
            Button { model.chooseAndAddFolder() } label: { Label("添加文件夹", systemImage: "folder.badge.plus") }
            Button { model.isShowingImport = true } label: { Label("从相机卡导入", systemImage: "externaldrive.badge.plus") }
        }
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
                    if item.kind == .video { badge("video.fill", color: .blue) }
                    if !item.issues.isEmpty { badge("exclamationmark.triangle.fill", color: .orange) }
                    if item.flag == .picked { badge("checkmark", color: .green) }
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
        .task(id: "\(item.id)-\(Int(size))") { image = await model.thumbnail(for: item, pixelSize: Int(size * 1.5)) }
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
            .task(id: item.id) { image = await model.thumbnail(for: item, pixelSize: 1_024) }
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
