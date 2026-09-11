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
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "externaldrive.badge.plus").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("从相机卡安全导入").font(.title2.bold())
                    Text("源文件不会被移动、重命名或删除。").foregroundStyle(.secondary)
                }
            }

            GroupBox("来源") {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.volumeMonitor.volumes.isEmpty {
                        Picker("检测到的外接卷", selection: $sourceURL) {
                            Text("请选择").tag(URL?.none)
                            ForEach(model.volumeMonitor.volumes, id: \.self) { volume in
                                Text(volume.lastPathComponent).tag(URL?.some(volume))
                            }
                        }
                    }
                    pathPicker(title: "相机卡或来源文件夹", url: sourceURL) { sourceURL = chooseDirectory(title: "选择相机卡或来源文件夹") }
                }
                .padding(4)
            }

            GroupBox("目标") {
                VStack(alignment: .leading, spacing: 10) {
                    pathPicker(title: "照片图库根目录", url: destinationURL) { destinationURL = chooseDirectory(title: "选择导入目标根目录") }
                    TextField("批次名称（例如：杭州旅行）", text: $batchName)
                    Text("将创建：\(previewPath)").font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }

            Spacer()
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("开始导入") {
                    guard let sourceURL, let destinationURL else { return }
                    model.importMedia(from: sourceURL, to: destinationURL, batchName: batchName)
                }
                .buttonStyle(.borderedProminent)
                .disabled(sourceURL == nil || destinationURL == nil)
            }
        }
        .padding(24)
        .frame(width: 620, height: 470)
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

    private func chooseDirectory(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
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
    }
}
