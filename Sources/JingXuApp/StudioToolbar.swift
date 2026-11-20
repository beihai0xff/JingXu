import JingXuCore
import SwiftUI

struct StudioToolbar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    let isSidebarVisible: Bool
    let toggleSidebar: () -> Void
    let shareSystemPhoto: () -> Void

    @State private var showsFilters = false
    @State private var showsViewOptions = false
    @State private var showsTaskCenter = false

    private var stage: StudioStageMode { model.stageMode }
    private var forcesDark: Bool { model.appearanceMode.forcesDarkStage(for: stage) }

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                leftCluster
                Spacer(minLength: 8)
                rightCluster
            }
            centerStageSwitcher
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(DarkroomPalette.chromeSurface(colorScheme: colorScheme, appearance: model.appearanceMode, stage: stage))
        .environment(\.colorScheme, forcesDark ? .dark : colorScheme)
    }

    // MARK: - Left Cluster

    @ViewBuilder
    private var leftCluster: some View {
        HStack(spacing: 8) {
            Button(action: toggleSidebar) {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(isSidebarVisible ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isSidebarVisible ? "收起左侧导航栏" : "展开左侧导航栏")
            .accessibilityLabel("切换左侧导航栏")

            Divider().frame(height: 16)

            if stage == .grid {
                gridScopeHeader
            } else {
                previewPagerHeader
            }
        }
    }

    @ViewBuilder
    private var gridScopeHeader: some View {
        if model.showsSystemPhotos, let photos = model.systemPhotos {
            HStack(spacing: 8) {
                Text(photos.selectedAlbum?.name ?? "所有照片")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(photos.total) 张 · 按拍摄时间")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            HStack(spacing: 8) {
                Text(model.libraryTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Text("\(model.matchingAssetCount) 项 · \(model.appliedQuery.sortOrder.displayName)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let path = model.selectedFolderPath {
                    Button {
                        model.setIncludeSubdirectories(!model.includeSubdirectories)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: model.includeSubdirectories ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 10))
                            Text("含子目录")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            model.includeSubdirectories ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.canChangeBrowseScope)
                    .help("当前文件夹：\(path)\n点击切换是否包含子目录")
                }
            }
        }
    }

    @ViewBuilder
    private var previewPagerHeader: some View {
        if model.showsSystemPhotos, let photos = model.systemPhotos, let photo = photos.preview {
            HStack(spacing: 6) {
                Button {
                    photos.switchStage(to: .grid)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Text("网格")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(photos.isBusy || photos.editor?.isComposing == true)
                .help("返回照片网格（G）")

                Divider().frame(height: 14)

                Button { photos.navigate(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(photos.navigationIndex == 0 || !photos.canNavigate)
                    .accessibilityLabel("上一张")

                Text(photo.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 180)
                    .help(photo.name)

                Button { photos.navigate(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(photos.navigationIndex + 1 >= photos.total || !photos.canNavigate)
                    .accessibilityLabel("下一张")

                if photos.previewSession.hasDraft {
                    Text("本机草稿 · 未写入系统照片")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DarkroomPalette.warningAmber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(DarkroomPalette.warningAmber.opacity(0.15), in: Capsule())
                }
            }
            .controlSize(.small)
        } else if let item = model.previewAsset {
            HStack(spacing: 6) {
                Button {
                    model.switchStage(to: .grid)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                        Text("网格")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .disabled(model.isPreviewTransitioning || model.colorEditor?.isComposing == true)
                .help("返回照片网格（G）")

                Divider().frame(height: 14)

                Button { model.navigatePreview(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .disabled(!model.canNavigatePreview(-1))
                    .accessibilityLabel("上一张")

                Text(item.fileName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 200)
                    .help(item.relativePath)

                Button { model.navigatePreview(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(!model.canNavigatePreview(1))
                    .accessibilityLabel("下一张")
            }
            .controlSize(.small)
        }
    }

    // MARK: - Center Stage Switcher

    private var centerStageSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(StudioStageMode.allCases, id: \.self) { candidate in
                let selected = stage == candidate
                let availability = stageAvailability(for: candidate)
                Button {
                    model.switchStage(to: candidate)
                } label: {
                    HStack(spacing: 4) {
                        Text(candidate.title)
                            .font(.caption.weight(selected ? .semibold : .regular))
                        Text(candidate.shortcutHint)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(selected ? Color.primary.opacity(0.85) : Color.secondary)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        selected ? Color.accentColor.opacity(0.24) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor.opacity(0.75) : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!availability.enabled)
                .opacity(availability.enabled || selected ? 1.0 : 0.45)
                .help(availability.help)
            }
        }
        .padding(2.5)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("工作台舞台切换")
    }

    private func stageAvailability(for target: StudioStageMode) -> (enabled: Bool, help: String) {
        if model.showsSystemPhotos {
            guard let photos = model.systemPhotos, photos.connected else {
                return (target == .grid, "请先连接系统照片")
            }
            if photos.isBusy || photos.isNavigating || photos.editor?.isComposing == true {
                return (false, "请先完成当前系统照片读取或裁剪操作")
            }
            switch target {
            case .grid:
                return (true, "网格视图（G）")
            case .loupe:
                let ok = photos.preview != nil || photos.primaryTargetPhotoForPreview != nil
                return (ok, ok ? "单图审片视图（空格 / E）" : "当前范围暂无可预览照片")
            case .compare:
                return (false, "系统照片暂不支持双图对比")
            case .develop:
                let candidate = photos.preview ?? photos.primaryTargetPhotoForPreview
                guard let candidate else { return (false, "当前范围暂无可调色照片") }
                guard candidate.canEdit else { return (false, "Live Photo 或只读项目不支持调色回写") }
                return (photos.canAct, "显影调色视图（D）")
            }
        } else {
            if model.isPreviewTransitioning || model.colorEditor?.isComposing == true {
                return (false, "请先完成或取消当前构图裁剪")
            }
            if let reason = model.operationBlockReason(.browse) {
                return (false, reason)
            }
            switch target {
            case .grid:
                return (true, "网格选片视图（G）")
            case .loupe:
                let ok = model.previewAsset != nil || model.primaryTargetPhotoForPreview != nil
                return (ok, ok ? "单图审片视图（空格 / E）" : "当前范围暂无可预览照片")
            case .compare:
                let ok = stage == .compare || model.canEnterCompareStage
                return (ok, ok ? "双图同步对比（C）" : "选择 2 张照片或打开相似连拍组照片以进入双图对比（C）")
            case .develop:
                let hasPhoto = model.previewAsset != nil || model.primaryTargetPhotoForPreview != nil
                let ok = hasPhoto && (model.colorEditor != nil || model.canStartColorAction)
                return (ok, ok ? "显影调色视图（D）" : "请选择照片并等待后台操作完成后进入调色")
            }
        }
    }

    // MARK: - Right Cluster

    private var rightCluster: some View {
        HStack(spacing: 8) {
            TaskStatusPill(showsPopover: $showsTaskCenter)

            if model.showsSystemPhotos, let photos = model.systemPhotos {
                systemRightControls(photos)
            } else {
                localRightControls
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var localRightControls: some View {
        switch stage {
        case .grid:
            BrowseSearchField(
                text: $model.searchText,
                changed: { model.scheduleSearch() },
                submit: { model.requestFilters() },
                composing: { model.searchTask?.cancel() }
            )
            .frame(minWidth: 165, idealWidth: 205, maxWidth: 235)
            .disabled(!model.canInteractWithLibrary || model.isSavingAnnotation)

            Button {
                showsFilters.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                    if model.hasUserFilters {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 2, y: -2)
                    }
                }
            }
            .buttonStyle(.borderless)
            .help("筛选评分与淘汰标记")
            .popover(isPresented: $showsFilters) { filterPopover }

            viewOptionsButton

            Menu {
                Button("添加文件夹…") { model.chooseAndAddFolder() }
                Button("从相机卡导入…") { model.isShowingImport = true }
            } label: {
                Image(systemName: "plus")
                    .accessibilityLabel("添加或导入照片")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.operationBlockReason(.files) != nil)

            Menu {
                if model.archivePending {
                    Button("恢复未完成归档…") { model.resumeArchive(undo: false) }
                    Divider()
                }
                Button("按日期重新归档…") { model.prepareArchive() }
                    .disabled(model.archivePending)
                Button("撤销最近一次归档…") { model.resumeArchive(undo: true) }
                Divider()
                Button("重新分析当前范围…") { model.prepareQualityReanalysis() }
                Button("重新分析全部旧结果…") { model.prepareQualityReanalysis(legacyOnly: true) }
                Divider()
                Button("清理失效索引…") { model.prepareMissingAssetCleanup() }
                Button("整理重复来源…") { model.prepareSourceMerge() }
                Button("清理淘汰图片…") { model.prepareDeletion() }
            } label: {
                Image(systemName: "tray.full")
                    .accessibilityLabel("整理与维护")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.operationBlockReason(.files) != nil)
            .help(model.operationBlockReason(.files) ?? "图库归档、重算与清理维护")

            inspectorToggleButton

        case .loupe, .compare:
            Button("导出", systemImage: "square.and.arrow.down") {
                model.showColorExport()
            }
            .buttonStyle(.borderless)
            .disabled(!model.canExportColor)

            Button {
                model.showPhotoShare()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canShowPhotoShare)
            .help("系统分享当前照片")
            .accessibilityLabel("分享照片")

            Button("调色", systemImage: "slider.horizontal.3") {
                model.switchStage(to: .develop)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStartColorAction)

            inspectorToggleButton

        case .develop:
            Button("导出", systemImage: "square.and.arrow.down") {
                model.showColorExport()
            }
            .buttonStyle(.borderless)
            .disabled(!model.canExportColor)
            .help(model.colorPresetPreview != nil ? "请先应用或取消预设预览后再导出" : "导出当前调色成片（⇧⌘E）")

            Button {
                model.showPhotoShare()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canShowPhotoShare)
            .help("分享当前照片")
            .accessibilityLabel("分享照片")

            Button("完成编辑", systemImage: "checkmark") {
                model.finishColorEditing()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canStartColorAction)
            .help("保存并返回单图审片（D / Esc）")
        }
    }

    @ViewBuilder
    private func systemRightControls(_ photos: SystemPhotosModel) -> some View {
        switch stage {
        case .grid:
            Button {
                photos.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!photos.canAct)
            .help("刷新系统照片图库")
            .accessibilityLabel("刷新")

            viewOptionsButton

            inspectorToggleButton

        case .loupe, .compare:
            Button(action: shareSystemPhoto) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(!photos.canAct || photos.previewImage == nil)
            .help("分享当前画面")
            .accessibilityLabel("分享当前画面")

            if let photo = photos.preview {
                Button("调色", systemImage: "slider.horizontal.3") {
                    photos.beginEditing()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!photo.canEdit || !photos.canAct)
            }

            Menu {
                Button("分析当前照片…") { photos.prepareAnalysis() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!photos.canAct)

            inspectorToggleButton

        case .develop:
            Button(action: shareSystemPhoto) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .disabled(!photos.canAct || photos.editor?.isComposing == true || photos.presetPreview != nil)
            .help("分享当前成片画面")

            Button("完成") {
                photos.finishEditing()
            }
            .buttonStyle(.bordered)
            .disabled(photos.editor?.isComposing == true || !photos.canAct)
            .help("保留本机草稿并返回单图（暂不写入系统照片）")

            Button("保存到系统照片") {
                photos.saveEdit()
            }
            .buttonStyle(.borderedProminent)
            .disabled(photos.conflict != nil || photos.editor?.isComposing == true || photos.presetPreview != nil || !photos.canAct)
        }
    }

    private var viewOptionsButton: some View {
        Button {
            showsViewOptions.toggle()
        } label: {
            Image(systemName: model.gridAspectMode.symbolName)
        }
        .buttonStyle(.borderless)
        .help("网格尺寸、画幅比例与排序选项")
        .accessibilityLabel("视图选项")
        .popover(isPresented: $showsViewOptions) {
            VStack(alignment: .leading, spacing: 16) {
                GridViewOptions(
                    size: $model.gridSize,
                    aspectMode: $model.gridAspectMode,
                    showsFileNames: $model.showsFileNames
                )
                if !model.showsSystemPhotos {
                    Divider()
                    Picker("排序方式", selection: $model.sortOrder) {
                        ForEach(BrowseSortOrder.allCases) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    .disabled(!model.canChangeBrowseScope)
                }
            }
            .padding(18)
            .frame(width: 288)
        }
    }

    private var inspectorToggleButton: some View {
        Button {
            model.showsInspector.toggle()
        } label: {
            Image(systemName: "sidebar.right")
                .foregroundStyle(model.showsInspector ? Color.accentColor : .secondary)
        }
        .buttonStyle(.borderless)
        .help(model.showsInspector ? "隐藏右侧信息检查器（I）" : "显示右侧信息检查器（I）")
        .accessibilityLabel("切换信息检查器")
    }

    private var filterPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("筛选照片").font(.headline)
            Picker("最低评分", selection: $model.minimumRating) {
                Text("全部评分").tag(0)
                ForEach(1...5, id: \.self) { Text("\($0) 星及以上").tag($0) }
            }
            Picker("照片标记", selection: $model.flagFilter) {
                Text("全部标记").tag(AssetFlag?.none)
                ForEach(AssetFlag.allCases, id: \.self) { Text($0.displayName).tag(AssetFlag?.some($0)) }
            }
            HStack {
                Spacer()
                Button("清除全部筛选") { model.clearFilters() }
                    .disabled(!model.hasUserFilters)
            }
        }
        .padding(18)
        .frame(width: 276)
        .disabled(!model.canChangeBrowseScope)
    }
}

struct TaskStatusPill: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showsPopover: Bool
    @State private var showsScanDetail = false

    private var pillState: (label: String?, isBusy: Bool, isWarning: Bool) {
        if model.showsSystemPhotos, let photos = model.systemPhotos {
            if photos.isBusy || photos.isNavigating || photos.previewSession.isLoadingFullImage {
                return (photos.isSubmitting ? "正在提交系统照片…" : "处理中…", true, false)
            }
            if !photos.unresolved.isEmpty {
                return ("待核对提交 \(photos.unresolved.count)", false, true)
            }
            if let job = photos.job, job.isResumable {
                return ("分析待继续 \(job.completed.count)/\(job.photos.count)", false, true)
            }
            return (nil, false, false)
        }

        if model.isWorking {
            if let p = model.importProgress {
                return ("导入 \(p.completedFiles + p.skippedFiles)/\(p.totalFiles)", true, false)
            }
            if let p = model.scanProgress {
                return ("索引 \(p.processed)/\(p.discovered)", true, false)
            }
            if let p = model.analysisProgress {
                return ("分析 \(p.completed)/\(p.total)", true, false)
            }
            return ("处理中…", true, false)
        }
        if model.archivePending {
            return ("待恢复归档", false, true)
        }
        if let job = model.resumableQualityJob {
            return ("重算 \(job.completed)/\(job.total)", false, true)
        }
        if model.lastScanReport?.isPartial == true {
            return ("扫描有遗漏", false, true)
        }
        if let report = model.lastImportReport, report.outcome != .completed {
            return (report.outcome.rawValue, false, true)
        }
        return (nil, false, false)
    }

    var body: some View {
        let state = pillState
        Button {
            showsPopover.toggle()
        } label: {
            if let label = state.label {
                HStack(spacing: 5) {
                    if state.isBusy {
                        ProgressView().controlSize(.mini)
                    } else if state.isWarning {
                        Circle().fill(DarkroomPalette.warningAmber).frame(width: 6, height: 6)
                    }
                    Text(label)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(state.isWarning ? DarkroomPalette.warningAmber : .primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(
                    (state.isWarning ? DarkroomPalette.warningAmber.opacity(0.14) : Color.secondary.opacity(0.14)),
                    in: Capsule()
                )
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(model.showsSystemPhotos ? (model.systemPhotos?.status ?? "任务与状态中心") : (model.activeTaskSummary ?? model.statusText))
        .accessibilityLabel("任务与状态中心")
        .popover(isPresented: $showsPopover) {
            taskCenterContent
        }
    }

    private var taskCenterContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("任务与记录中心").font(.headline)
                Spacer()
                if !model.showsSystemPhotos {
                    Text(model.browseSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if model.showsSystemPhotos, let photos = model.systemPhotos {
                Text(photos.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if photos.isBusy || photos.isNavigating || photos.previewSession.isLoadingFullImage {
                    HStack {
                        ProgressView().controlSize(.small)
                        Spacer()
                        Button(photos.isSubmitting ? "正在提交" : "取消／暂停") { photos.cancel() }
                            .disabled(photos.isSubmitting)
                    }
                }

                if let job = photos.job, job.isResumable {
                    HStack {
                        Text("系统照片质量分析：\(job.completed.count)/\(job.photos.count)")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Button("继续") { photos.analyze(job) }.disabled(!photos.canAct)
                        Button("结束…") { photos.endAnalysis() }
                    }
                }

                if let job = photos.job, !job.failures.isEmpty {
                    Divider()
                    Text("分析未完成 \(job.failures.count) 项").font(.caption.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(job.photos.filter { job.failures[$0.id] != nil }) { photo in
                                Text("\(photo.name)：\(job.failures[photo.id] ?? "")")
                                    .font(.caption2)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxHeight: 100)
                }

                ForEach(photos.unresolved) { record in
                    HStack {
                        Text("待核对：\(record.title)（\(record.names.count) 项）")
                            .font(.caption)
                            .foregroundStyle(DarkroomPalette.warningAmber)
                        Spacer()
                        Button("查看记录…") {
                            showsPopover = false
                            photos.inspectedWrite = record
                        }
                    }
                }
            } else {
                Text(model.activeTaskSummary ?? model.statusText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if model.isWorking {
                    HStack {
                        ProgressView().controlSize(.small)
                        Spacer()
                        if model.isReanalyzing {
                            Button("暂停") { model.pauseQualityReanalysis() }
                        }
                        Button("取消") { model.cancelCurrentOperation() }
                    }
                }

                if model.archivePending {
                    HStack {
                        Label("存在未完成的归档日志", systemImage: "exclamationmark.arrow.circlepath")
                            .font(.caption)
                            .foregroundStyle(DarkroomPalette.warningAmber)
                        Spacer()
                        Button("恢复归档…") {
                            showsPopover = false
                            model.resumeArchive(undo: false)
                        }
                        .disabled(model.operationBlockReason(.files) != nil)
                    }
                }

                if !model.isWorking, let job = model.resumableQualityJob {
                    HStack {
                        Text("已暂停质量重算：\(job.completed)/\(job.total)")
                            .font(.caption.monospacedDigit())
                        Spacer()
                        Button("继续") { model.resumeQualityReanalysis() }
                        Button("取消重算") { model.cancelPausedQualityJob() }
                    }
                }

                HStack(spacing: 10) {
                    if let report = model.lastImportReport {
                        Button("导入报告：\(report.outcome.rawValue)") {
                            showsPopover = false
                            model.isShowingImportReport = true
                        }
                    }
                    if let scan = model.lastScanReport {
                        Button(scan.isPartial ? "查看扫描遗漏详情…" : "查看最近扫描统计…") {
                            showsScanDetail.toggle()
                        }
                        .popover(isPresented: $showsScanDetail) {
                            ScanReportView(report: scan)
                        }
                    }
                }
                .controlSize(.small)

                if !model.operationResults.isEmpty {
                    Divider()
                    Text("最近操作记录").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.operationResults.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
            }
        }
        .controlSize(.small)
        .padding(16)
        .frame(width: 360)
    }
}
