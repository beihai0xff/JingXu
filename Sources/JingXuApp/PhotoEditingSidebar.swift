import AppKit
import JingXuCore
import SwiftUI

private enum PhotoEditTab: String, CaseIterable {
    case adjust = "调整"
    case crop = "裁剪"
    case presets = "预设"
}

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
    @State private var histogramIsDragging = false

    var body: some View {
        VStack(spacing: 0) {
            developHeader
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            ColorHistogram(
                session: session,
                result: (presetPreview ?? session.result)?.histogram,
                enabled: session.usable && !session.isComposing && presetPreview == nil && !isWorking && !isTransitioning && !externallyControlled && !session.isExternallyControlled,
                prepare: {
                    histogramIsDragging = true
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    session.endGesture()
                },
                finished: { histogramIsDragging = false }
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Picker("显影模块", selection: Binding(
                get: { session.isComposing ? .crop : tab },
                set: { value in
                    presetPreview = nil
                    if value == .crop {
                        beginComposition()
                    } else {
                        session.cancelComposition()
                        tab = value
                    }
                }
            )) {
                ForEach(PhotoEditTab.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .disabled(isWorking || isTransitioning || externallyControlled)

            Divider().overlay(DarkroomPalette.subtleDivider)

            if let draft = session.composition {
                CompositionPanel(
                    draft: draft,
                    isBusy: isWorking || isTransitioning,
                    cancel: { session.cancelComposition(); tab = .adjust },
                    apply: applyComposition
                )
            } else if tab == .presets {
                EditorPresetBrowser(session: session, preview: $presetPreview, presets: presets, manage: managePresets)
                    .disabled(isWorking || isTransitioning || externallyControlled || !session.usable)
            } else {
                ColorEditPanel(
                    session: session,
                    isWorking: isWorking,
                    isTransitioning: isTransitioning,
                    externallyControlled: externallyControlled,
                    histogramIsDragging: histogramIsDragging,
                    copyAdjustments: copyAdjustments,
                    discardStale: discardStale
                )
            }
        }
        .darkroomPanelSurface()
        .onDisappear {
            presetPreview = nil
            session.endComparison()
        }
    }

    private var developHeader: some View {
        HStack(spacing: 8) {
            Text("显影调色")
                .font(.callout.weight(.semibold))
                .foregroundStyle(DarkroomPalette.textPrimary)

            HStack(spacing: 2) {
                Button { session.undo() } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!session.history.canUndo || isTransitioning || session.isComposing)
                .help("撤销调整（⌘Z）")
                .accessibilityLabel("撤销")

                Button { session.redo() } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(.borderless)
                .disabled(!session.history.canRedo || isTransitioning || session.isComposing)
                .help("重做调整（⇧⌘Z）")
                .accessibilityLabel("重做")
            }
            .controlSize(.small)

            Spacer(minLength: 4)

            saveStatusBadge

            Button(session.comparing ? "原图对比中" : "对比 \\") {}
                .buttonStyle(OriginalComparisonButtonStyle { pressed in
                    if pressed {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        session.beginComparison()
                    } else {
                        session.endComparison()
                    }
                })
                .disabled(!session.usable || isWorking || session.isComposing)
                .help(
                    session.snapshot.usesRenderedBase
                        ? "按住按钮或键盘 \\ 查看本次编辑前底图；松开恢复成片。"
                        : "按住按钮或键盘 \\ 查看未调色、未裁剪的原片；松开恢复成片。"
                )
        }
    }

    private var saveStatusBadge: some View {
        HStack(spacing: 4) {
            if session.isSaving || session.isRendering {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(
                        session.saveError != nil
                            ? DarkroomPalette.rejectCoral
                            : (session.isDirty ? DarkroomPalette.warningAmber : DarkroomPalette.readyGreen)
                    )
                    .frame(width: 6, height: 6)
            }
            Text(
                session.saveError != nil
                    ? "保存失败"
                    : session.isSaving
                        ? "保存中"
                        : session.isDirty
                            ? "待保存"
                            : (session.snapshot.isSystemPhoto ? "草稿就绪" : "已保存")
            )
            .font(.system(size: 11))
            .foregroundStyle(session.saveError != nil ? DarkroomPalette.rejectCoral : DarkroomPalette.textSecondary)
        }
    }
}

/// ButtonStyle follows mouse and keyboard press state, including dragging outside the button.
struct OriginalComparisonButtonStyle: ButtonStyle {
    let pressed: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Color.white : DarkroomPalette.textPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3.5)
            .background(
                configuration.isPressed ? Color.accentColor : DarkroomPalette.elevatedControl,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, value in pressed(value) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in pressed(false) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in pressed(false) }
            .onDisappear { pressed(false) }
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
            VStack(alignment: .leading, spacing: 14) {
                if selectedID != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(DarkroomPalette.warningAmber)
                        Text("预览中（未保存，导出与分享已锁定）")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(DarkroomPalette.warningAmber)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DarkroomPalette.warningAmber.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(DarkroomPalette.warningAmber.opacity(0.45), lineWidth: 1)
                    )
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(choices) { choice in
                        let active = selectedID == choice.id
                        Button { selectedID = choice.id } label: {
                            VStack(spacing: 5) {
                                PresetThumbnail(
                                    snapshot: session.snapshot,
                                    adjustments: session.adjustments,
                                    patch: choice.patch,
                                    revision: session.editVersion
                                )
                                .frame(height: 76)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

                                Text(choice.name)
                                    .font(.caption)
                                    .foregroundStyle(active ? DarkroomPalette.textPrimary : DarkroomPalette.textSecondary)
                                    .lineLimit(1)
                            }
                            .padding(6)
                            .frame(maxWidth: .infinity)
                            .background(
                                active ? Color.accentColor.opacity(0.18) : DarkroomPalette.elevatedControl.opacity(0.65),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(active ? Color.accentColor : DarkroomPalette.subtleDivider, lineWidth: active ? 1.5 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("预览预设：" + choice.name)
                    }
                }

                if rendering {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在渲染预设预览…").font(.caption).foregroundStyle(DarkroomPalette.textSecondary)
                    }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(DarkroomPalette.rejectCoral)
                }

                HStack {
                    Button("取消预览") { selectedID = nil; preview = nil }
                        .disabled(selectedID == nil)
                    Spacer()
                    Button("应用预设") {
                        guard let chosen else { return }
                        do {
                            let values = try chosen.patch.applying(to: session.adjustments, groups: Set(ColorGroup.allCases), isRAW: session.isRAW)
                            session.apply(values)
                            selectedID = nil
                            preview = nil
                        } catch { self.error = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen == nil || preview == nil || rendering)
                }
                .controlSize(.small)

                Text("单击预设预览效果，点击「应用预设」后写入当前调整；裁剪构图保持不变，支持撤销。")
                    .font(.caption2)
                    .foregroundStyle(DarkroomPalette.textMuted)

                Divider().overlay(DarkroomPalette.subtleDivider)

                Button(session.snapshot.isSystemPhoto ? "管理预设…" : "管理预设与导入 XMP…", action: manage)
                    .controlSize(.small)
            }
            .padding(14)
        }
        .task(id: (selectedID ?? "") + session.editVersion.uuidString) {
            preview = nil; error = nil
            guard let chosen else { rendering = false; return }
            rendering = true
            defer { if !Task.isCancelled { rendering = false } }
            do {
                let values = try chosen.patch.applying(to: session.adjustments, groups: Set(ColorGroup.allCases), isRAW: session.isRAW)
                let result = try await ColorImageRenderer.shared.render(session.snapshot, adjustments: values, maximumDimension: 2048)
                try Task.checkCancellation()
                preview = result
            } catch is CancellationError {} catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
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
            DarkroomPalette.canvasDeep
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFit()
            } else if error != nil {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(DarkroomPalette.warningAmber)
                    .help(error ?? "")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: revision) {
            image = nil; error = nil
            do {
                let values = try patch.applying(to: adjustments, groups: Set(ColorGroup.allCases), isRAW: snapshot.isRAW)
                let result = try await ColorImageRenderer.shared.render(snapshot, adjustments: values, maximumDimension: 300)
                try Task.checkCancellation()
                image = result.image
            } catch is CancellationError {} catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
