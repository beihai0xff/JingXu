import SwiftUI
import AppKit
import UniformTypeIdentifiers
import JingXuCore

struct ColorWorkflowPresentation: ViewModifier {
    @EnvironmentObject private var model: AppModel
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.isShowingColorPresets) { ColorPresetsSheet().environmentObject(model) }
            .sheet(item: $model.colorBatchPlan) { plan in
                ColorConfirmationSheet(title: "批量应用调色", summary: "将修改 \(plan.items.count) 张照片，其中 \(plan.items.filter { $0.snapshot.record?.isEdited == true }.count) 张已有调色。\n参数组：\(ColorGroup.allCases.filter { plan.groups.contains($0) }.map(\.title).joined(separator: "、"))。仅替换所选参数，执行前备份图库。",
                    rows: plan.items.map { $0.snapshot.source.pathHint + "/" + $0.snapshot.asset.relativePath }, warnings: plan.warnings,
                    confirmTitle: "备份并应用", cancel: { model.colorBatchPlan = nil }, confirm: { model.confirmColorBatch(plan) })
            }
            .sheet(isPresented: $model.isShowingColorExport) { ColorExportOptionsSheet().environmentObject(model) }
            .sheet(item: $model.colorExportPlan) { plan in
                ColorConfirmationSheet(title: "导出成片", summary: "原尺寸 · sRGB · \(plan.format.title)\n目标：\(plan.directory.path)\n将导出 \(plan.items.count) 张照片，跳过已有文件。",
                    rows: plan.items.map { $0.snapshot.asset.fileName + " → " + $0.destination.lastPathComponent }, warnings: plan.skipped,
                    confirmTitle: "开始导出", cancel: { model.colorExportPlan = nil }, confirm: { model.confirmColorExport(plan) })
            }
    }
}

private struct ColorConfirmationSheet: View {
    let title: String, summary: String, rows: [String], warnings: [String], confirmTitle: String
    let cancel: () -> Void, confirm: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2)
            Text(summary).textSelection(.enabled)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in Text(row).font(.caption).textSelection(.enabled) }
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, row in Text("跳过：" + row).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 250)
            HStack { Spacer(); Button("取消", action: cancel).keyboardShortcut(.cancelAction); Button(confirmTitle, action: confirm).disabled(rows.isEmpty) }
        }.padding(24).frame(width: 640)
    }
}

private struct ColorExportOptionsSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var format = ColorExportFormat.jpeg
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("导出成片").font(.title2)
            Text("已选 \(model.colorTargetIDs.count) 张照片 · 原尺寸 · sRGB")
            Picker("格式", selection: $format) {
                ForEach(ColorExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text("JPEG 将透明区域合成到白色背景；PNG 和 TIFF 保留透明度。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { model.isShowingColorExport = false }; Button("选择目录…") { model.prepareColorExport(format: format) } }
        }.padding(24).frame(width: 480)
    }
}

private struct ColorPresetsSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = "current"
    @State private var current: ColorPatch?
    @State private var imported: ColorPreset?
    @State private var name = "我的预设"
    @State private var groups = Set(ColorGroup.allCases)
    @State private var preview: ColorRenderedImage?
    @State private var error: String?
    @State private var previewError: String?
    @State private var busy = false
    @State private var confirmingDelete = false
    private var preset: ColorPreset? { model.colorPresets.first { $0.id == selection } }
    private var patch: ColorPatch? {
        if selection == "current" { return current }
        if selection == "copied" { return model.copiedColorPatch }
        if selection == "imported" { return try? imported?.patch }
        return try? preset?.patch
    }
    private var previewKey: String {
        // Dictionary descriptions have unstable ordering across JSON decodes.
        let parameters = ColorParameter.allCases.compactMap { p in patch?.values[p].map { "\(p.rawValue)=\($0)" } }.joined(separator: ",")
        return selection + groups.map(\.rawValue).sorted().joined() + parameters + (patch?.whiteBalance?.rawValue ?? "") + (patch?.target.rawValue ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("预设与调色").font(.title2); Spacer(); Button("导入 Lightroom XMP…") { importXMP() }.disabled(busy) }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("参数来源", selection: $selection) {
                        Text("当前照片调整").tag("current")
                        if model.copiedColorPatch != nil { Text("已复制的调整").tag("copied") }
                        if let imported { Text("待导入：" + imported.name).tag("imported") }
                        ForEach(model.colorPresets) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        ForEach(ColorGroup.allCases, id: \.self) { group in
                            Toggle(group.title, isOn: Binding(get: { groups.contains(group) }, set: { if $0 { groups.insert(group) } else { groups.remove(group) } }))
                        }
                    }
                    if let patch {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(ColorParameter.allCases.filter { patch.values[$0] != nil && groups.contains($0.group) }, id: \.self) { p in
                                    Text("\(p.title)：\(patch.values[p]!, format: .number.precision(.fractionLength(0...2)))").font(.caption)
                                }
                                if let wb = patch.whiteBalance, groups.contains(.whiteBalance) {
                                    Text(wb == .asShot ? "白平衡：拍摄时" : wb == .raw ? "白平衡：RAW 绝对色温" : "白平衡：普通图片相对调整").font(.caption)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 170)
                    }
                    TextField("预设名称", text: $name)
                    HStack {
                        Button("保存为新预设") { savePreset(replacing: false) }.disabled(patch == nil || preview == nil || busy)
                        if preset != nil {
                            Button("重命名") { savePreset(replacing: true) }.disabled(busy)
                            Button("删除", role: .destructive) { confirmingDelete = true }.disabled(busy)
                        }
                    }
                }.frame(width: 340)
                VStack(spacing: 8) {
                    ZStack {
                        Color.black
                        if let preview { Image(decorative: preview.image, scale: 1).resizable().scaledToFit() }
                        else if previewError == nil { ProgressView() }
                        else { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
                    }.frame(width: 340, height: 260)
                    Text("以首张所选照片试用 · 镜序渲染").font(.caption)
                    Text("与 Lightroom 的最终成片效果不保证一致。").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let message = error ?? previewError { ScrollView { Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100) }
            HStack {
                Text("应用到 \(model.colorTargetIDs.count) 张照片；缺失的参数保持原值。").font(.caption)
                Spacer()
                Button("取消") { model.isShowingColorPresets = false }.keyboardShortcut(.cancelAction)
                Button(model.colorEditor == nil ? "生成应用清单…" : "应用到当前照片") {
                    if let patch { model.applyColorPatch(patch, groups: groups) }
                }.disabled(patch == nil || groups.isEmpty || (model.colorEditor != nil && preview == nil) || busy)
            }
        }.padding(24).frame(width: 740)
            .task {
                do {
                    if let editor = model.colorEditor { current = ColorPatch(editor.adjustments) }
                    else if let id = model.colorTargetIDs.first, let store = model.store { current = ColorPatch(try await store.colorSnapshot(assetID: id).adjustments) }
                } catch { self.error = error.localizedDescription }
            }
            .task(id: previewKey) {
                preview = nil; previewError = nil
                guard let patch, !groups.isEmpty else { previewError = "请选择至少一组调整"; return }
                do {
                    let value = try await model.previewColorPatch(patch, groups: groups)
                    try Task.checkCancellation(); preview = value
                } catch is CancellationError {} catch { if !Task.isCancelled { previewError = error.localizedDescription } }
            }
            .onChange(of: selection) { _, _ in name = preset?.name ?? imported?.name ?? "我的预设"; error = nil }
            .confirmationDialog("删除此预设？已应用到照片的调整仍保留。", isPresented: $confirmingDelete) {
                Button("删除预设", role: .destructive) {
                    guard let preset else { return }
                    Task { do { try await model.deleteColorPreset(preset); selection = "current" } catch { self.error = error.localizedDescription } }
                }
            }
    }
    private func savePreset(replacing: Bool) {
        guard let patch else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let id = replacing ? preset?.id ?? UUID().uuidString : UUID().uuidString
                try await model.saveColorPreset(name: name, patch: patch, id: id)
                selection = id; imported = nil; error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
    private func importXMP() {
        let panel = NSOpenPanel()
        panel.title = "选择 Lightroom 参数预设"; panel.allowedContentTypes = [UTType(filenameExtension: "xmp") ?? .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let value = try await Task.detached {
                    let lease = PreviewAccessLease(url: url)
                    defer { withExtendedLifetime(lease) {} }
                    let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard count <= 2 * 1024 * 1024 else { throw ColorEditError("XMP 文件超过 2 MB") }
                    return try ColorXMPImporter.parse(Data(contentsOf: url), suggestedName: url.deletingPathExtension().lastPathComponent)
                }.value
                imported = value; selection = "imported"; name = value.name; error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}
