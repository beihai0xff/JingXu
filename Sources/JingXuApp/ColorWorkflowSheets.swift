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
            .sheet(isPresented: $model.isShowingColorExport, onDismiss: model.cancelColorExport) {
                ColorExportOptionsSheet().environmentObject(model).interactiveDismissDisabled(model.isPreparingColorExport)
            }
            .sheet(isPresented: Binding(get: { model.colorExportReport != nil }, set: { if !$0 { model.colorExportReport = nil } })) {
                if let report = model.colorExportReport { ColorExportResultSheet(report: report) { model.colorExportReport = nil } }
            }
    }
}

private struct ColorConfirmationSheet: View {
    let title: String, summary: String, rows: [String], warnings: [String], confirmTitle: String
    let cancel: () -> Void, confirm: () -> Void

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "范围：已确认的 \(rows.count) 张所选照片",
            title: title,
            safetyNote: summary,
            metrics: [
                ManifestMetric(label: "可应用照片", value: "\(rows.count) 张", tone: .accent),
                ManifestMetric(label: "跳过项目", value: "\(warnings.count) 项", tone: warnings.isEmpty ? .neutral : .warning)
            ],
            width: 650,
            onCancel: cancel,
            confirmTitle: confirmTitle,
            confirmDisabled: rows.isEmpty,
            onConfirm: confirm
        ) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row)
                }
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, row in
                    Text("跳过：\(row)")
                        .foregroundStyle(DarkroomPalette.warningAmber)
                }
            }
        }
    }
}

private struct ColorExportOptionsSheet: View {
    @EnvironmentObject private var model: AppModel
    @State private var format = ColorExportFormat.jpeg

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "范围：已确认的 \(model.colorExportDraft.count) 张照片 · 原生尺寸 sRGB",
            title: "导出调色成片",
            safetyNote: "输出为应用已保存调色与裁剪的独立图片文件，原片始终保留；已有同名文件和批次内重名均自动跳过不覆盖。",
            metrics: model.colorExportPlan.map { plan in
                [
                    ManifestMetric(label: "可执行导出", value: "\(plan.items.count) 张", tone: .accent),
                    ManifestMetric(label: "重名／异常跳过", value: "\(plan.skipped.count) 张", tone: plan.skipped.isEmpty ? .neutral : .warning)
                ]
            } ?? [],
            width: 600,
            manifestMaxHeight: 165,
            cancelTitle: model.isPreparingColorExport ? "取消准备" : "取消",
            onCancel: { model.cancelColorExport() },
            confirmTitle: model.colorExportPlan.map { "导出 \($0.items.count) 张成片" } ?? "导出成片",
            confirmDisabled: model.colorExportPlan?.items.isEmpty != false || model.isPreparingColorExport,
            onConfirm: {
                if let plan = model.colorExportPlan { model.confirmColorExport(plan) }
            },
            controls: {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        ForEach(Array(model.colorExportDraft.prefix(5))) { item in
                            PhotoThumbnail(item: item, size: 140, compact: true)
                                .frame(width: 68, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        if model.colorExportDraft.count > 5 {
                            Text("+\(model.colorExportDraft.count - 5)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("输出格式", selection: $format) {
                        ForEach(ColorExportFormat.allCases, id: \.self) { f in
                            Text(f.title).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.isPreparingColorExport)

                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.colorExportDirectory?.lastPathComponent ?? "请选择导出目标目录")
                                .font(.callout.weight(.medium))
                            if let directory = model.colorExportDirectory {
                                Text(directory.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                        Button(model.colorExportDirectory == nil ? "选择目录…" : "更改目录…") {
                            model.chooseColorExportDirectory(format: format)
                        }
                        .disabled(model.isPreparingColorExport)
                    }
                    .padding(10)
                    .background(DarkroomPalette.elevatedControl.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))

                    if let error = model.colorExportError {
                        HStack {
                            Text(error).font(.caption).foregroundStyle(DarkroomPalette.rejectCoral)
                            Spacer()
                            Button("重试核对") { model.prepareColorExport(format: format) }.controlSize(.small)
                        }
                    }
                }
            },
            manifestBody: {
                if let plan = model.colorExportPlan {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.items) { item in
                            Text("\(item.snapshot.asset.fileName) → \(item.destination.lastPathComponent)")
                        }
                        ForEach(Array(plan.skipped.enumerated()), id: \.offset) { _, reason in
                            Text("跳过：\(reason)")
                                .foregroundStyle(DarkroomPalette.warningAmber)
                        }
                    }
                } else {
                    Text(model.isPreparingColorExport ? "正在核对源文件与目标路径…" : "选择导出目录后将在此生成固定导出清单。")
                        .foregroundStyle(.secondary)
                }
            },
            leadingFooter: {
                if model.isPreparingColorExport {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在预检…").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        )
        .onChange(of: format) { _, _ in model.prepareColorExport(format: format) }
    }
}

private struct ColorExportResultSheet: View {
    let report: ColorExportReport
    let close: () -> Void

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: report.cancelled ? "导出任务已中途停止" : "导出任务已完成",
            title: report.cancelled ? "成片导出已停止" : "成片导出结果",
            safetyNote: "已导出的文件已原子落盘，原照片未做任何修改。",
            metrics: [
                ManifestMetric(label: "成功导出", value: "\(report.written.count) 张", tone: .accent),
                ManifestMetric(label: "同名跳过", value: "\(report.skipped.count) 张", tone: report.skipped.isEmpty ? .neutral : .warning),
                ManifestMetric(label: "失败", value: "\(report.failed.count) 张", tone: report.failed.isEmpty ? .neutral : .destructive)
            ],
            width: 580,
            cancelTitle: nil,
            onCancel: nil,
            confirmTitle: "完成",
            onConfirm: close,
            controls: { EmptyView() },
            manifestBody: {
                if report.skipped.isEmpty && report.failed.isEmpty {
                    ForEach(report.written, id: \.self) { url in
                        Text(url.path)
                    }
                } else {
                    ForEach(Array((report.skipped + report.failed).enumerated()), id: \.offset) { _, line in
                        Text(line).foregroundStyle(DarkroomPalette.warningAmber)
                    }
                }
            },
            leadingFooter: {
                if !report.written.isEmpty {
                    Button("在访达中查看") {
                        NSWorkspace.shared.activateFileViewerSelecting(report.written)
                    }
                }
            }
        )
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
