import AppKit
import JingXuCore
import SwiftUI

struct SystemPhotosPresentation: ViewModifier {
    var photos: SystemPhotosModel?
    @Binding var showCreateAlbum: Bool
    @Binding var newAlbumName: String
    @Binding var renameTarget: SystemPhotoAlbum?
    @Binding var renameText: String
    @Binding var showsShare: Bool
    @Binding var shareImage: CGImage?

    func body(content: Content) -> some View {
        if let photos {
            content.modifier(
                ActiveSystemPhotosPresentation(
                    photos: photos,
                    showCreateAlbum: $showCreateAlbum,
                    newAlbumName: $newAlbumName,
                    renameTarget: $renameTarget,
                    renameText: $renameText,
                    showsShare: $showsShare,
                    shareImage: $shareImage
                )
            )
        } else {
            content
        }
    }
}

private struct ActiveSystemPhotosPresentation: ViewModifier {
    @ObservedObject var photos: SystemPhotosModel
    @Binding var showCreateAlbum: Bool
    @Binding var newAlbumName: String
    @Binding var renameTarget: SystemPhotoAlbum?
    @Binding var renameText: String
    @Binding var showsShare: Bool
    @Binding var shareImage: CGImage?

    func body(content: Content) -> some View {
        content
            .sheet(
                isPresented: Binding(
                    get: { photos.uploadSnapshots != nil },
                    set: { if !$0 { photos.cancelUpload() } }
                )
            ) {
                SystemPhotosUploadSheet(photos: photos)
            }
            .sheet(isPresented: $showsShare) {
                if let shareImage {
                    let image = Image(decorative: shareImage, scale: 1)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("分享当前画面").font(.title3.weight(.bold))
                        Text("1 张静态图片 · 包含画面中当前显示的调整").font(.callout).foregroundStyle(.secondary)
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: 420, height: 260)
                            .background(DarkroomPalette.canvasDeep, in: RoundedRectangle(cornerRadius: 8))
                        Text("不包含 Live Photo 动态内容；发送由所选系统分享服务处理。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("关闭") { showsShare = false }
                            Spacer()
                            ShareLink(item: image, preview: SharePreview(photos.preview?.name ?? "照片", image: image)) {
                                Label("系统分享…", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(24)
                }
            }
            .alert("新建系统相册", isPresented: $showCreateAlbum) {
                TextField("相册名称", text: $newAlbumName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    photos.prepareMutation(.createAlbum(newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)))
                    newAlbumName = ""
                }
            }
            .alert(
                "重命名系统相册",
                isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
            ) {
                TextField("相册名称", text: $renameText)
                Button("取消", role: .cancel) { renameTarget = nil }
                Button("继续") {
                    if let album = renameTarget {
                        photos.prepareMutation(
                            .renameAlbum(id: album.id, name: renameText.trimmingCharacters(in: .whitespacesAndNewlines)),
                            album: album
                        )
                    }
                    renameTarget = nil
                }
            }
            .sheet(item: $photos.mutationPlan) { plan in
                SystemPhotoMutationSheet(photos: photos, plan: plan)
            }
            .sheet(item: $photos.analysisPlan) { plan in
                SystemPhotoAnalysisSheet(photos: photos, plan: plan)
            }
            .sheet(isPresented: $photos.showsPresets) {
                SystemPhotoPresetsSheet(photos: photos)
            }
            .sheet(item: $photos.inspectedWrite) { record in
                SystemPhotoWriteSheet(photos: photos, record: record)
            }
            .modifier(SystemPhotosErrorPresentation(photos: photos))
    }
}

private struct SystemPhotoAnalysisSheet: View {
    @ObservedObject var photos: SystemPhotosModel
    let plan: SystemPhotoAnalysisJob

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "范围：已确认的 \(plan.photos.count) 张系统照片",
            title: "本机质量分析预检清单",
            safetyNote: "原片按需下载并仅在本机离线分析，绝不修改系统照片或触发外部上传。",
            metrics: [
                ManifestMetric(label: "待分析照片", value: "\(plan.photos.count) 张", tone: .accent)
            ],
            width: 580,
            onCancel: { photos.analysisPlan = nil },
            confirmTitle: "开始分析",
            confirmDisabled: plan.photos.isEmpty,
            onConfirm: { photos.analyze(plan) }
        ) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(plan.photos) { photo in
                    Text(photo.name)
                }
            }
        }
    }
}

private struct SystemPhotoMutationSheet: View {
    @ObservedObject var photos: SystemPhotosModel
    let plan: SystemPhotoMutationPlan

    private var isDestructive: Bool {
        switch plan.operation {
        case .deleteAlbum, .deletePhotos: true
        default: false
        }
    }

    private var summary: (scope: String, title: String, note: String) {
        switch plan.operation {
        case .createAlbum(let name):
            return ("范围：系统照片相册列表", "创建系统相册“\(name)”", "在系统照片图库中新建普通相册；iCloud 同步由 macOS 系统处理。")
        case .renameAlbum(_, let name):
            return ("范围：相册“\(plan.albumName ?? "")”", "重命名系统相册", "将相册名称更新为“\(name)”，相册内照片与归属保持不变。")
        case .deleteAlbum:
            return ("范围：相册“\(plan.albumName ?? "")”", "删除系统相册“\(plan.albumName ?? "")”", "仅删除相册结构及其成员关系，保留全部 \(plan.albumCount ?? 0) 项照片和视频。")
        case .addToAlbum:
            return ("范围：已确认的 \(plan.photos.count) 张系统照片", "加入相册“\(plan.albumName ?? "")”", "将所选照片加入此相册，保留其他相册中的归属。")
        case .removeFromAlbum:
            return ("范围：已确认的 \(plan.photos.count) 张系统照片", "移出相册“\(plan.albumName ?? "")”", "仅从当前相册移出，照片保留在系统图库和其他相册中。")
        case .deletePhotos:
            return ("范围：已确认的 \(plan.photos.count) 张系统照片", "从系统图库删除 \(plan.photos.count) 张照片", "通过 PhotoKit 提交删除；开启 iCloud 照片后会同步影响其他设备。可在系统「最近删除」中恢复，镜序本地图库文件不受影响。")
        }
    }

    var body: some View {
        let info = summary
        if plan.photos.isEmpty {
            ManifestConfirmationSheet(
                scopeBadge: info.scope,
                title: info.title,
                safetyNote: info.note,
                metrics: plan.albumCount.map { [ManifestMetric(label: "保留媒体数量", value: "\($0) 项")] } ?? [],
                width: 560,
                onCancel: { photos.mutationPlan = nil },
                confirmTitle: isDestructive ? "确认删除" : "确认操作",
                isDestructive: isDestructive,
                onConfirm: { photos.confirmMutation() },
                controls: { EmptyView() },
                manifestBody: { EmptyView() },
                leadingFooter: { EmptyView() }
            )
        } else {
            ManifestConfirmationSheet(
                scopeBadge: info.scope,
                title: info.title,
                safetyNote: info.note,
                metrics: [
                    ManifestMetric(label: "固定照片范围", value: "\(plan.photos.count) 张", tone: isDestructive ? .destructive : .accent)
                ],
                width: 600,
                onCancel: { photos.mutationPlan = nil },
                confirmTitle: isDestructive ? "确认删除" : "确认操作",
                isDestructive: isDestructive,
                onConfirm: { photos.confirmMutation() }
            ) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(plan.photos) { photo in
                        Text(photo.name)
                    }
                }
            }
        }
    }
}

struct SystemPhotosUploadSheet: View {
    @ObservedObject var photos: SystemPhotosModel

    private var itemCount: Int {
        photos.preparedUpload?.files.count ?? photos.uploadSnapshots?.count ?? 0
    }

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "范围：来自本地图库的 \(itemCount) 张已选照片",
            title: "加入系统照片图库",
            safetyNote: "本地图库原文件完整保留；提交到系统照片后，macOS 可能将内容（含拍摄位置）同步到 iCloud 照片。",
            metrics: [
                ManifestMetric(label: "待提交照片", value: "\(itemCount) 张", tone: .accent),
                ManifestMetric(label: "准备状态", value: photos.preparedUpload != nil ? "清单已锁定" : "待准备文件", tone: photos.preparedUpload != nil ? .accent : .neutral)
            ],
            width: 650,
            cancelTitle: photos.isBusy ? "取消准备" : "关闭",
            onCancel: photos.isSubmitting ? nil : { photos.cancelUpload() },
            confirmTitle: photos.preparedUpload != nil ? "确认加入系统照片" : "准备固定文件清单",
            confirmDisabled: !photos.canAct,
            onConfirm: {
                if photos.preparedUpload != nil {
                    photos.confirmUpload()
                } else {
                    photos.prepareUpload()
                }
            },
            controls: {
                VStack(alignment: .leading, spacing: 10) {
                    if !photos.connected {
                        Button("授权并连接系统照片") { photos.connect() }
                            .buttonStyle(.borderedProminent)
                            .disabled(photos.isBusy)
                    }
                    HStack(spacing: 14) {
                        Picker("上传内容", selection: $photos.uploadMode) {
                            Text("原片").tag(PhotoShareMode.original)
                            Text("调色 JPEG").tag(PhotoShareMode.jpeg)
                        }
                        .pickerStyle(.segmented)
                        .disabled(photos.isBusy || photos.preparedUpload != nil)

                        Picker("目标相册", selection: $photos.uploadAlbumID) {
                            Text("仅加入图库").tag(String?.none)
                            ForEach(photos.albums.filter(\.canAdd)) { album in
                                Text(album.name).tag(Optional(album.id))
                            }
                        }
                        .disabled(photos.isBusy || photos.preparedUpload != nil)
                    }
                    ForEach(photos.unresolved) { record in
                        Button("先核对上次提交：\(record.title)…") {
                            photos.inspectedWrite = record
                        }
                        .controlSize(.small)
                    }
                }
            },
            manifestBody: {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if let plan = photos.preparedUpload {
                        ForEach(Array(plan.files.enumerated()), id: \.offset) { _, file in
                            Text(file.name)
                        }
                    } else {
                        ForEach(photos.uploadSnapshots ?? [], id: \.asset.id) { snap in
                            Text(snap.asset.fileName)
                        }
                    }
                }
            },
            leadingFooter: {
                HStack(spacing: 8) {
                    if photos.isBusy { ProgressView().controlSize(.small) }
                    Text(photos.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if photos.preparedUpload != nil {
                        Button("重新准备") { photos.preparedUpload = nil }
                            .controlSize(.small)
                            .disabled(photos.isBusy)
                    }
                }
            }
        )
        .interactiveDismissDisabled(photos.isBusy)
        .sheet(item: $photos.inspectedWrite) { record in
            SystemPhotoWriteSheet(photos: photos, record: record)
        }
        .modifier(SystemPhotosErrorPresentation(photos: photos))
    }
}

struct SystemPhotoWriteSheet: View {
    @ObservedObject var photos: SystemPhotosModel
    let record: SystemPhotoWriteRecord

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "待核对提交记录 · \(record.submittedAt.formatted(date: .abbreviated, time: .shortened))",
            title: record.title,
            safetyNote: (record.detail ?? "上次提交未收到系统完整确认结果。") + " 请先在 macOS「照片」应用中人工核对以下项目；为防止重复导入或误改，镜序不会自动重试。",
            metrics: [
                ManifestMetric(label: "提交项目", value: "\(record.names.count) 项", tone: .warning),
                ManifestMetric(label: "系统返回标识", value: "\(record.createdIDs.count) 个")
            ],
            width: 620,
            cancelTitle: "稍后处理",
            onCancel: { photos.inspectedWrite = nil },
            confirmTitle: "已在系统照片中核对…",
            confirmDisabled: photos.isBusy,
            onConfirm: {
                photos.acknowledge(record)
                photos.inspectedWrite = nil
            }
        ) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(record.names.enumerated()), id: \.offset) { _, name in
                    Text(name)
                }
                if !record.createdIDs.isEmpty {
                    Divider()
                    Text("系统返回的照片标识：")
                        .font(.caption.weight(.semibold))
                    ForEach(record.createdIDs, id: \.self) { id in
                        Text(id)
                    }
                }
            }
        }
    }
}

private struct SystemPhotoPresetsSheet: View {
    @ObservedObject var photos: SystemPhotosModel
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("系统照片调色预设").font(.title3.weight(.bold))
            if let patch = photos.copiedPatch {
                Button("应用已复制的调色参数") { photos.applyPreset(patch) }
            }
            List(photos.presets) { preset in
                Button(preset.name) {
                    do { photos.applyPreset(try preset.patch) }
                    catch { photos.error = error.localizedDescription }
                }
            }
            HStack {
                TextField("保存当前调整为新预设", text: $name)
                    .textFieldStyle(.roundedBorder)
                Button("保存") { photos.savePreset(name: name); name = "" }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photos.isBusy)
            }
            HStack {
                Spacer()
                Button("关闭") { photos.showsPresets = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 440, height: 420)
    }
}

private struct SystemPhotosErrorPresentation: ViewModifier {
    @ObservedObject var photos: SystemPhotosModel

    func body(content: Content) -> some View {
        content.alert(
            "系统照片",
            isPresented: Binding(get: { photos.error != nil }, set: { if !$0 { photos.error = nil } })
        ) {
            Button("好") { photos.error = nil }
        } message: {
            Text(photos.error ?? "")
        }
    }
}
