import JingXuCore
import SwiftUI

struct LocalPhotoGridStage: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var gridScrollID: String?

    private var spacing: CGFloat { model.gridAspectMode.gridSpacing }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.gridSize, maximum: model.gridSize * 1.32), spacing: spacing)]
    }

    private var showsContextStrip: Bool {
        model.hasUserFilters ||
        model.appliedQuery.similarGroupID != nil ||
        model.resultsChanged ||
        model.browseError != nil ||
        (model.isLoadingAssets && !model.assets.isEmpty)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if showsContextStrip {
                    LocalGridContextStrip()
                    Divider().overlay(DarkroomPalette.hairline(colorScheme: colorScheme, appearance: model.appearanceMode, stage: .grid))
                }
                gridContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DarkroomPalette.gridCanvasFill(colorScheme: colorScheme, appearance: model.appearanceMode))

            LocalFloatingSelectionDock()
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        if model.isLoadingAssets && model.assets.isEmpty {
            ProgressView("正在载入当前范围…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.assets.isEmpty {
            ContentUnavailableView {
                Label(
                    model.directoryHasNoDirectFiles
                        ? "此目录没有直接文件"
                        : (model.hasUserFilters ? "当前筛选无匹配结果" : "当前范围暂无照片"),
                    systemImage: "photo.on.rectangle.angled"
                )
            } description: {
                Text(
                    model.directoryHasNoDirectFiles
                        ? "可开启包含子目录，查看下级文件夹中的已索引照片与视频。"
                        : (model.hasUserFilters ? "照片可能被搜索、评分或旗标条件隐藏。" : "可添加照片文件夹、从相机卡安全导入，或等待当前扫描完成。")
                )
            } actions: {
                if model.directoryHasNoDirectFiles {
                    Button("包含子目录") { model.setIncludeSubdirectories(true) }
                        .buttonStyle(.borderedProminent)
                }
                if model.hasUserFilters {
                    Button("清除筛选") { model.clearFilters() }
                        .buttonStyle(.borderedProminent)
                }
                HStack(spacing: 10) {
                    Button("添加文件夹…") { model.chooseAndAddFolder() }
                    Button("从相机卡导入…") { model.isShowingImport = true }
                }
                .disabled(model.fileOperationsBlockedByShare)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                        Section {
                            ForEach(0..<model.gridLeadingCells, id: \.self) { _ in
                                Color.clear.frame(height: model.gridSize).accessibilityHidden(true)
                            }
                            ForEach(model.assets) { item in
                                PhotoGridCell(
                                    item: item,
                                    size: model.gridSize,
                                    aspectMode: model.gridAspectMode,
                                    isSelected: item.kind == .photo
                                        ? model.photoSelection.selectedIDs.contains(item.id)
                                        : model.selectedAssetID == item.id,
                                    isFocused: model.selectedAssetID == item.id
                                )
                                .id(item.id)
                                .contextMenu {
                                    if item.kind == .photo {
                                        Button("打开单图（空格）") { model.openPreview(item) }
                                        Button("进入调色（D）") {
                                            model.selectAsset(item)
                                            model.switchStage(to: .develop)
                                        }
                                        .disabled(!model.canStartColorAction)
                                        Divider()
                                    }
                                    Button("重新载入缩略图") { model.thumbnailReloadID = UUID() }
                                    Button("重新授权来源…") { model.reauthorizeThumbnailSource(item) }
                                    Button("在访达中显示") { model.revealSelectedInFinder(assetID: item.id) }
                                    Menu("添加到相册") {
                                        ForEach(model.albums) { album in
                                            Button(album.name) {
                                                model.applyAnnotation(.init(albumID: album.id), title: "添加到相册", ids: [item.id])
                                            }
                                        }
                                        if model.albums.isEmpty { Text("请先新建相册") }
                                    }
                                }
                            }
                        } header: {
                            if model.hasPreviousPage { loadMore(before: true) }
                        } footer: {
                            if model.hasNextPage {
                                loadMore(before: false)
                            } else {
                                Text("已显示当前范围全部 \(model.matchingAssetCount) 项")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 14)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 84)
                    .background(GeometryReader { geometry in
                        Color.clear
                            .onChange(of: geometry.size.width, initial: true) { _, width in
                                updateColumns(width: width)
                            }
                            .onChange(of: model.gridSize) { _, _ in
                                updateColumns(width: geometry.size.width)
                            }
                            .onChange(of: model.gridAspectMode) { _, _ in
                                updateColumns(width: geometry.size.width)
                            }
                    })
                }
                .scrollPosition(id: $gridScrollID)
                .onChange(of: model.gridTrimRevision) { _, _ in
                    let anchor = [gridScrollID, model.gridTrimFallbackID].compactMap { $0 }
                        .first { model.loadedAssets.contains($0) }
                    if let anchor {
                        gridScrollID = anchor
                        let revision = model.gridTrimRevision
                        DispatchQueue.main.async {
                            if model.gridTrimRevision == revision { proxy.scrollTo(anchor, anchor: .top) }
                        }
                    }
                }
                .onChange(of: model.gridJumpRevision, initial: true) { _, _ in
                    if let id = model.gridJumpID {
                        gridScrollID = id
                        let revision = model.gridJumpRevision
                        DispatchQueue.main.async {
                            if model.gridJumpRevision == revision { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
                .onChange(of: model.appliedQuery) { _, _ in gridScrollID = nil }
                .onChange(of: model.selectedAssetID, initial: true) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func updateColumns(width: CGFloat) {
        model.updateGridColumns(Int((width - 28 + spacing) / (model.gridSize + spacing)))
    }

    private func loadMore(before: Bool) -> some View {
        BrowseLoadMore(
            title: before ? "载入前面的照片" : "继续滚动浏览 · \(model.browseSummary)",
            isLoading: model.isLoadingMoreAssets,
            canLoad: !model.isLoadingAssets && !model.isLoadingMoreAssets && model.browseError == nil,
            load: { model.loadMoreAssets(before: before) }
        )
        .id("load-\(before)-\(model.assets.count)")
    }
}

struct LocalGridContextStrip: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if !model.appliedQuery.searchText.isEmpty {
                    FilterChip(title: "搜索：" + model.appliedQuery.searchText) {
                        model.searchText = ""
                        model.requestFilters()
                    }
                }
                if model.appliedQuery.minimumRating > 0 {
                    FilterChip(title: "\(model.appliedQuery.minimumRating) 星及以上") {
                        model.minimumRating = 0
                    }
                }
                if let flag = model.appliedQuery.flag {
                    FilterChip(title: flag.displayName) {
                        model.flagFilter = nil
                    }
                }
                if model.hasUserFilters {
                    Button("清除筛选") { model.clearFilters() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }

                if model.appliedQuery.similarGroupID != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up.fill").font(.caption2)
                        Text("正在查看相似连拍组").font(.caption)
                        Button("返回原范围") { model.leaveSimilarGroup() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                }

                if model.resultsChanged {
                    HStack(spacing: 6) {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                        Text("结果有更新，当前浏览位置已保留").font(.caption)
                        Button("刷新结果") {
                            model.resultsChanged = false
                            Task { await model.reloadAssets() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }

                if model.isLoadingAssets {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("更新中…").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let failure = model.browseError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DarkroomPalette.warningAmber)
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(DarkroomPalette.warningAmber)
                            .lineLimit(1)
                        Button("重试") { model.retryBrowse() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(!model.canChangeBrowseScope)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .disabled(!model.canChangeBrowseScope)
    }
}

struct PhotoGridCell: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    let item: AssetListItem
    let size: CGFloat
    let aspectMode: GridAspectMode
    let isSelected: Bool
    let isFocused: Bool
    @State private var isHovered = false
    @State private var thumbnailFailed = false

    private var isRejected: Bool { item.flag == .rejected }
    private var isRAW: Bool { MediaSupport.isRaw(URL(fileURLWithPath: item.fileName)) }
    private var showsCheckmark: Bool { item.kind == .photo && (isHovered || isSelected) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                PhotoThumbnail(
                    item: item,
                    size: Int(size),
                    aspectMode: aspectMode,
                    slotBackground: DarkroomPalette.gridSlotFill(colorScheme: colorScheme, appearance: model.appearanceMode),
                    failureChanged: { thumbnailFailed = $0 }
                )
                .aspectRatio(1, contentMode: .fit)
                .opacity(isRejected ? 0.42 : 1.0)
                .saturation(isRejected ? 0.45 : 1.0)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            DarkroomPalette.gridSlotBorder(colorScheme: colorScheme, appearance: model.appearanceMode),
                            lineWidth: 1
                        )
                )
                .overlay(alignment: .topTrailing) {
                    microBadges
                        .padding(6)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottomLeading) {
                    if item.rating > 0 {
                        ratingPill(item.rating)
                            .padding(6)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    selectionAndFocusStroke(cornerRadius: 6)
                        .allowsHitTesting(false)
                }
                .overlay {
                    if !thumbnailFailed {
                        GridClickHandler(label: item.fileName) { command, shift, count in
                            model.clickAsset(item, command: command, shift: shift, count: count)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if showsCheckmark {
                        GridCheckmarkButton(isSelected: isSelected) {
                            model.toggleAssetCheckmark(item)
                        }
                    }
                }
            }

            if model.showsFileNames || thumbnailFailed {
                HStack(spacing: 4) {
                    Text(item.fileName)
                        .font(.caption2)
                        .foregroundStyle(isRejected ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
                .help(item.fileName)
                .overlay {
                    if thumbnailFailed {
                        GridClickHandler(label: item.fileName) { command, shift, count in
                            model.clickAsset(item, command: command, shift: shift, count: count)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var microBadges: some View {
        HStack(spacing: 3) {
            if isRAW {
                textMicroBadge("RAW")
            }
            if item.kind == .video {
                iconMicroBadge("video.fill", fg: .white)
            }
            if item.isColorEdited {
                iconMicroBadge("slider.horizontal.3", fg: .white)
                    .help("已应用非破坏式调色")
                    .accessibilityLabel("已编辑")
            }
            if item.similarGroupID != nil || item.issues.contains(.similarBurst) {
                iconMicroBadge("square.stack.3d.up", fg: .white)
                    .help("相似连拍组")
                    .accessibilityLabel("相似照片")
            }
            if item.hasPendingQualityWarning {
                iconMicroBadge("exclamationmark.triangle.fill", fg: DarkroomPalette.warningAmber)
                    .help("存在待审核质量提示")
            }
            if isRejected {
                iconMicroBadge("xmark", fg: .white, bg: DarkroomPalette.rejectCoral.opacity(0.92))
                    .help("已标记淘汰")
            }
        }
    }

    private func textMicroBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 4.5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
    }

    private func iconMicroBadge(_ symbol: String, fg: Color, bg: Color = Color.black.opacity(0.62)) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(fg)
            .frame(width: 18, height: 18)
            .background(bg, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func ratingPill(_ stars: Int) -> some View {
        HStack(spacing: 1.5) {
            ForEach(1...stars, id: \.self) { _ in
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
            }
        }
        .foregroundStyle(.yellow)
        .padding(.horizontal, 5)
        .padding(.vertical, 2.5)
        .background(Color.black.opacity(0.58), in: Capsule())
    }

    private func selectionAndFocusStroke(cornerRadius: CGFloat) -> some View {
        ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
            if isFocused {
                RoundedRectangle(cornerRadius: max(2, cornerRadius - (isSelected ? 2 : 0)), style: .continuous)
                    .inset(by: isSelected ? 2 : 0)
                    .strokeBorder(Color.white.opacity(0.92), lineWidth: 1)
            }
        }
    }
}

struct GridCheckmarkButton: View {
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.accentColor : Color.black.opacity(0.50))
                    .frame(width: 20, height: 20)
                Circle()
                    .strokeBorder(isSelected ? Color.white.opacity(0.85) : Color.white.opacity(0.78), lineWidth: 1.25)
                    .frame(width: 20, height: 20)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(2)
        .accessibilityLabel(isSelected ? "取消勾选此照片" : "勾选此照片")
    }
}

struct SystemPhotoGridStage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var photos: SystemPhotosModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var gridScrollID: String?

    private var spacing: CGFloat { model.gridAspectMode.gridSpacing }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.gridSize, maximum: model.gridSize * 1.32), spacing: spacing)]
    }

    private var showsContextStrip: Bool {
        photos.browseError != nil || photos.conflict != nil || !photos.unresolved.isEmpty || !(photos.job?.failures.isEmpty ?? true)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if showsContextStrip {
                    systemContextStrip
                    Divider().overlay(DarkroomPalette.hairline(colorScheme: colorScheme, appearance: model.appearanceMode, stage: .grid))
                }
                if !photos.connected {
                    ContentUnavailableView {
                        Label("系统照片", systemImage: "photo.on.rectangle")
                    } description: {
                        Text("授权后查看和管理系统图库。开启 iCloud 照片后，更改由系统同步到其他设备。")
                    } actions: {
                        Button("连接系统照片") { photos.connect() }
                            .buttonStyle(.borderedProminent)
                            .disabled(photos.isBusy)
                        Button("打开系统设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if photos.items.isEmpty {
                    ContentUnavailableView(
                        "此范围暂无照片",
                        systemImage: "photo.on.rectangle",
                        description: Text("可切换相册，或从本地图库选择照片加入系统照片。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                                Section {
                                    ForEach(0..<(photos.offset % max(1, photos.gridColumns)), id: \.self) { _ in
                                        Color.clear.frame(height: model.gridSize).accessibilityHidden(true)
                                    }
                                    ForEach(photos.items) { photo in
                                        SystemPhotoGridCell(
                                            photo: photo,
                                            client: photos.client,
                                            aspectMode: model.gridAspectMode,
                                            slotFill: DarkroomPalette.gridSlotFill(colorScheme: colorScheme, appearance: model.appearanceMode),
                                            slotBorder: DarkroomPalette.gridSlotBorder(colorScheme: colorScheme, appearance: model.appearanceMode),
                                            selected: photos.selection.selectedIDs.contains(photo.id),
                                            focused: photos.selection.focusID == photo.id,
                                            showsName: model.showsFileNames,
                                            onClick: { command, shift, count in
                                                photos.click(photo, command: command, shift: shift, count: count)
                                            },
                                            onToggleCheck: {
                                                photos.toggleCheckmark(photo)
                                            }
                                        )
                                        .id(photo.id)
                                    }
                                } header: {
                                    if photos.offset > 0 { loadMore(before: true) }
                                } footer: {
                                    if photos.offset + photos.items.count < photos.total {
                                        loadMore(before: false)
                                    } else {
                                        Text("已显示当前范围全部 \(photos.total) 张照片")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .padding(.vertical, 14)
                                    }
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal, 14)
                            .padding(.top, 12)
                            .padding(.bottom, 84)
                            .background(GeometryReader { geometry in
                                Color.clear
                                    .onChange(of: geometry.size.width, initial: true) { _, width in
                                        updateColumns(width: width)
                                    }
                                    .onChange(of: model.gridSize) { _, _ in
                                        updateColumns(width: geometry.size.width)
                                    }
                                    .onChange(of: model.gridAspectMode) { _, _ in
                                        updateColumns(width: geometry.size.width)
                                    }
                            })
                        }
                        .scrollPosition(id: $gridScrollID)
                        .onChange(of: photos.gridTrimRevision) { _, _ in
                            let anchor = [gridScrollID, photos.gridTrimFallbackID].compactMap { $0 }
                                .first { id in photos.items.contains(where: { $0.id == id }) }
                            if let anchor {
                                gridScrollID = anchor
                                let revision = photos.gridTrimRevision
                                DispatchQueue.main.async {
                                    if photos.gridTrimRevision == revision { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            }
                        }
                        .onChange(of: photos.gridJumpRevision, initial: true) { _, _ in
                            if let id = photos.gridJumpID {
                                gridScrollID = id
                                let revision = photos.gridJumpRevision
                                DispatchQueue.main.async {
                                    if photos.gridJumpRevision == revision { proxy.scrollTo(id, anchor: .center) }
                                }
                            }
                        }
                        .onChange(of: gridScrollID) { _, id in photos.visibleGridID = id }
                        .onChange(of: photos.albumID) { _, _ in gridScrollID = nil }
                        .onChange(of: photos.selection.focusID, initial: true) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DarkroomPalette.gridCanvasFill(colorScheme: colorScheme, appearance: model.appearanceMode))

            SystemPhotosFloatingDock(photos: photos)
        }
    }

    private var systemContextStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                if let error = photos.browseError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DarkroomPalette.warningAmber)
                        Text(error).font(.caption).foregroundStyle(DarkroomPalette.warningAmber)
                        Button("重试") { photos.retryBrowse() }.buttonStyle(.bordered).controlSize(.mini)
                    }
                }
                if let conflict = photos.conflict {
                    Text(conflict).font(.caption).foregroundStyle(DarkroomPalette.warningAmber)
                }
                ForEach(photos.unresolved) { record in
                    HStack(spacing: 6) {
                        Text("待核对：\(record.title) · \(record.names.count) 项")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(DarkroomPalette.warningAmber)
                        Button("查看记录…") { photos.inspectedWrite = record }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
                if let job = photos.job, !job.failures.isEmpty {
                    Text("分析未完成 \(job.failures.count) 项（可在右上角任务胶囊查看）")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
    }

    private func updateColumns(width: CGFloat) {
        model.updateGridColumns(Int((width - 28 + spacing) / (model.gridSize + spacing)))
        photos.gridColumns = model.gridColumns
    }

    private func loadMore(before: Bool) -> some View {
        BrowseLoadMore(
            title: before ? "载入前面的照片" : "继续滚动浏览",
            isLoading: photos.isLoadingMore,
            canLoad: photos.canAct && photos.browseError == nil,
            load: { photos.loadMore(before: before) }
        )
        .id("\(before)-\(photos.items.count)-\(photos.offset)")
    }
}

struct SystemPhotoGridCell: View {
    let photo: SystemPhoto
    let client: any PhotoLibraryClient
    var aspectMode: GridAspectMode = .aspectFit
    var slotFill: Color = DarkroomPalette.panelSurface
    var slotBorder: Color = DarkroomPalette.subtleDivider.opacity(0.65)
    let selected: Bool
    var focused: Bool = false
    var small: Bool = false
    var showsName: Bool = true
    var onClick: ((Bool, Bool, Int) -> Void)? = nil
    var onToggleCheck: (() -> Void)? = nil
    @State private var image: CGImage?
    @State private var failure: String?
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                slotFill
                if let image {
                    let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    if aspectMode == .squareFill && !small {
                        SquareThumbnail(image: nsImage)
                    } else {
                        FittedThumbnail(image: nsImage)
                            .padding(aspectMode == .aspectFit && !small ? 4 : 0)
                    }
                } else if failure != nil {
                    VStack(spacing: 4) {
                        Image(systemName: "icloud.slash").foregroundStyle(DarkroomPalette.warningAmber)
                        if !small {
                            Text(photo.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .padding(4)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(small ? 1.45 : 1.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: small ? 4 : 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: small ? 4 : 6, style: .continuous)
                    .strokeBorder(slotBorder, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if photo.isLivePhoto && !small {
                    Image(systemName: "livephoto")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.black.opacity(0.60), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: small ? 4 : 6, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                    if focused && !small {
                        RoundedRectangle(cornerRadius: max(2, 6 - (selected ? 2 : 0)), style: .continuous)
                            .inset(by: selected ? 2 : 0)
                            .strokeBorder(Color.white.opacity(0.92), lineWidth: 1)
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay {
                if let onClick, !small {
                    GridClickHandler(label: photo.name, action: onClick)
                }
            }
            .overlay(alignment: .topLeading) {
                if !small, let onToggleCheck, (isHovered || selected) {
                    GridCheckmarkButton(isSelected: selected, toggle: onToggleCheck)
                }
            }

            if !small && (showsName || failure != nil) {
                Text(photo.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 2)
            }
        }
        .contentShape(Rectangle())
        .help(failure ?? photo.name)
        .onHover { isHovered = $0 }
        .task(id: "\(photo.id)-\(photo.modifiedAt?.timeIntervalSince1970 ?? 0)-\(small)") {
            image = nil; failure = nil
            do {
                let result = try await client.image(id: photo.id, pixelSize: small ? 172 : 520)
                try Task.checkCancellation()
                image = result.image
            } catch is CancellationError {} catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
        }
        .onDisappear { image = nil }
    }
}
