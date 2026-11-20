@preconcurrency import AppKit
import JingXuCore
import SwiftUI

struct ImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourceURL: URL?
    @State private var destinationURL: URL?
    @State private var batchName = ""

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "安全导入向导 · 原卡零删除",
            title: "从相机卡或目录安全导入",
            safetyNote: "源文件不会被移动、重命名或删除。导入前将先生成含哈希与同名跳过的固定清单供核对。",
            metrics: [],
            width: 620,
            cancelTitle: "取消",
            onCancel: { dismiss() },
            confirmTitle: "生成导入预检清单",
            confirmDisabled: sourceURL == nil || destinationURL == nil,
            onConfirm: {
                guard let sourceURL, let destinationURL else { return }
                model.prepareImport(from: sourceURL, to: destinationURL, batchName: batchName)
            },
            controls: {
                VStack(alignment: .leading, spacing: 12) {
                    GroupBox("1. 选择相机卡或来源目录") {
                        VStack(alignment: .leading, spacing: 8) {
                            if !model.volumeMonitor.volumes.isEmpty {
                                Menu("检测到的外接存储卷") {
                                    ForEach(model.volumeMonitor.volumes, id: \.self) { volume in
                                        Button(volume.lastPathComponent) {
                                            if let selected = chooseDirectory(title: "授权访问相机卡或来源文件夹", startingAt: volume) {
                                                sourceURL = selected
                                            }
                                        }
                                    }
                                }
                                Text("选择外接卷后，请在系统窗口确认目录以授予访问权限。")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            pathPicker(title: "来源路径", url: sourceURL) {
                                sourceURL = chooseDirectory(title: "选择相机卡或来源文件夹")
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("2. 选择本地图库目标根目录") {
                        VStack(alignment: .leading, spacing: 8) {
                            pathPicker(title: "目标根目录", url: destinationURL) {
                                destinationURL = chooseDirectory(title: "选择导入目标根目录")
                            }
                            TextField("批次名称（例如：杭州旅行，可留空）", text: $batchName)
                                .textFieldStyle(.roundedBorder)
                            Text("将创建批次子目录：\(previewPath)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                    }
                }
            },
            manifestBody: { EmptyView() },
            leadingFooter: { EmptyView() }
        )
        .onAppear { model.volumeMonitor.refresh() }
    }

    private var previewPath: String {
        ImportNaming.destinationFolder(date: Date(), batchName: batchName)
    }

    private func pathPicker(title: String, url: URL?, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(url?.path ?? "尚未选择").lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("选择…", action: action)
        }
    }

    private func chooseDirectory(title: String, startingAt directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.directoryURL = directory
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct AlbumCreatorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建相册").font(.title2.bold())
            TextField("相册名称", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建") {
                    model.createAlbum(named: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420, height: 160)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("外观与网格") {
                Picker("工作台外观", selection: $model.appearanceMode) {
                    ForEach(AppAppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text("单图看片、双图对比与调色舞台始终锁定光学中性暗灰（#141416），消除浅色背景对曝光与白平衡判断的明度同时对比干扰。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("网格画幅模式", selection: $model.gridAspectMode) {
                    ForEach(GridAspectMode.allCases, id: \.self) { aspect in
                        Text(aspect.title).tag(aspect)
                    }
                }
            }
            Section("隐私") {
                Label("完全离线分析", systemImage: "lock.shield")
                Text("镜序在本机分析和渲染照片。启用 AI 助手连接后，所选照片的缩小预览与参数可交给 Codex，进入模型上下文。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let connection = model.automationConnection {
                AutomationConnectionSection(connection: connection)
            }
            Section("缓存") {
                Button("清理缩略图缓存") { model.clearThumbnailCache() }
                Text("不会删除目录、评分、标签或原始文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .appAppearance(model.appearanceMode)
    }
}
