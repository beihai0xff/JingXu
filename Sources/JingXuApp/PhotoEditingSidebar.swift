import SwiftUI
import JingXuCore

private enum PhotoEditTab: String, CaseIterable { case adjust = "调整", crop = "裁剪", presets = "预设" }

struct PhotoEditingSidebar: View {
    @ObservedObject var session: ColorEditSession
    @Binding var presetPreview: ColorRenderedImage?
    let presets: [ColorPreset]
    let isWorking: Bool
    let isTransitioning: Bool
    let externallyControlled: Bool
    let beginComposition: () -> Void
    let applyComposition: () -> Void
    let copyAdjustments: () -> Void
    let managePresets: () -> Void
    let discardStale: () -> Void
    @State private var tab = PhotoEditTab.adjust

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑照片").font(.headline)
                Spacer()
                if session.isSaving || session.isRendering { ProgressView().controlSize(.small) }
                Text(session.saveError != nil ? "保存失败" : session.isSaving ? "正在保存…" : session.isDirty ? "未保存" : session.snapshot.isSystemPhoto ? "草稿已保存" : "已保存")
                    .font(.caption).foregroundStyle(session.saveError == nil ? Color.secondary : .red)
            }.padding(16)
            Picker("编辑工具", selection: Binding(get: { session.isComposing ? .crop : tab }, set: { value in
                presetPreview = nil
                if value == .crop { beginComposition() }
                else { session.cancelComposition(); tab = value }
            })) {
                ForEach(PhotoEditTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.bottom, 12)
                .disabled(isWorking || isTransitioning || externallyControlled)
            if let draft = session.composition {
                CompositionPanel(draft: draft, isBusy: isWorking || isTransitioning,
                    cancel: { session.cancelComposition(); tab = .adjust }, apply: applyComposition)
            } else if tab == .presets {
                EditorPresetBrowser(session: session, preview: $presetPreview, presets: presets, manage: managePresets)
                    .disabled(isWorking || isTransitioning || externallyControlled || !session.usable)
            } else {
                ColorEditPanel(session: session, isWorking: isWorking, isTransitioning: isTransitioning,
                    externallyControlled: externallyControlled, copyAdjustments: copyAdjustments,
                    discardStale: discardStale)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onDisappear { presetPreview = nil }
    }
}

private struct EditorPresetChoice: Identifiable {
    let id: String
    let name: String
    let patch: ColorPatch
}

private struct EditorPresetBrowser: View {
    @ObservedObject var session: ColorEditSession
    @Binding var preview: ColorRenderedImage?
    let presets: [ColorPreset]
    let manage: () -> Void
    @State private var selectedID: String?
    @State private var error: String?
    @State private var rendering = false

    private var choices: [EditorPresetChoice] {
        var clear = ColorAdjustments(); clear.highlights = -25; clear.shadows = 15; clear.contrast = 8; clear.saturation = -5
        var warm = ColorAdjustments(); warm.highlights = -15; warm.shadows = 10
        warm.whiteBalance = session.isRAW ? .raw : .relative
        warm.temperature = session.isRAW ? min(50_000, max(2_000, (session.result?.rawTemperature ?? 6500) + 500)) : 8
        warm.tint = session.isRAW ? session.result?.rawTint ?? 0 : 0
        var mono = ColorAdjustments(); mono.saturation = -100; mono.contrast = 15
        let builtins = [("original", "原始色彩", ColorAdjustments()), ("clear", "清透", clear), ("warm", "暖调", warm), ("mono", "黑白", mono)]
            .map { EditorPresetChoice(id: "builtin-" + $0.0, name: $0.1, patch: ColorPatch($0.2)) }
        return builtins + presets.compactMap { preset in
            guard let patch = try? preset.patch else { return nil }
            return EditorPresetChoice(id: preset.id, name: preset.name, patch: patch)
        }
    }
    private var chosen: EditorPresetChoice? { choices.first { $0.id == selectedID } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(choices) { choice in
                        Button { selectedID = choice.id } label: {
                            VStack(spacing: 6) {
                                PresetThumbnail(snapshot: session.snapshot, adjustments: session.adjustments,
                                    patch: choice.patch, revision: session.editVersion)
                                    .frame(height: 80).clipped()
                                Text(choice.name).font(.caption).lineLimit(1)
                            }.padding(5).frame(maxWidth: .infinity)
                                .background(selectedID == choice.id ? Color.accentColor.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(selectedID == choice.id ? Color.accentColor : .clear, lineWidth: 2))
                        }.buttonStyle(.plain).accessibilityLabel("预览预设：" + choice.name)
                    }
                }
                if rendering { ProgressView("正在预览…").controlSize(.small) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("取消预览") { selectedID = nil; preview = nil }.disabled(selectedID == nil)
                    Spacer()
                    Button("应用预设") {
                        guard let chosen else { return }
                        do {
                            let values = try chosen.patch.applying(to: session.adjustments, groups: Set(ColorGroup.allCases), isRAW: session.isRAW)
                            session.apply(values); selectedID = nil; preview = nil
                        } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(chosen == nil || preview == nil || rendering)
                }
                Text("选择预览，应用后保存；可撤销。裁剪范围保持不变。").font(.caption).foregroundStyle(.secondary)
                Divider()
                Button(session.snapshot.isSystemPhoto ? "管理预设…" : "管理预设与导入 XMP…", action: manage)
            }.padding(16)
        }
        .task(id: (selectedID ?? "") + session.editVersion.uuidString) {
            preview = nil; error = nil
            guard let chosen else { rendering = false; return }
            rendering = true
            defer { if !Task.isCancelled { rendering = false } }
            do {
                let values = try chosen.patch.applying(to: session.adjustments, groups: Set(ColorGroup.allCases), isRAW: session.isRAW)
                let result = try await ColorImageRenderer.shared.render(session.snapshot, adjustments: values, maximumDimension: 2048)
                try Task.checkCancellation(); preview = result
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onDisappear { preview = nil }
    }
}

private struct PresetThumbnail: View {
    let snapshot: ColorEditingSnapshot
    let adjustments: ColorAdjustments
    let patch: ColorPatch
    let revision: UUID
    @State private var image: CGImage?
    @State private var error: String?
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else if error != nil { Image(systemName: "photo.badge.exclamationmark").help(error ?? "") }
            else { ProgressView().controlSize(.small) }
        }.task(id: revision) {
            image = nil; error = nil
            do {
                let values = try patch.applying(to: adjustments, groups: Set(ColorGroup.allCases), isRAW: snapshot.isRAW)
                let result = try await ColorImageRenderer.shared.render(snapshot, adjustments: values, maximumDimension: 300)
                try Task.checkCancellation(); image = result.image
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
