import JingXuCore
import SwiftUI

struct ColorEditPanel: View {
    @ObservedObject var session: ColorEditSession
    let isWorking: Bool
    let isTransitioning: Bool
    let externallyControlled: Bool
    let histogramIsDragging: Bool
    let copyAdjustments: () -> Void
    let discardStale: () -> Void

    @FocusState private var focusedParameter: ColorParameter?
    @State private var editingParameter: ColorParameter?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let error = session.saveError {
                    errorBanner(
                        title: "保存失败：\(error)",
                        color: DarkroomPalette.rejectCoral,
                        primaryTitle: "重试保存",
                        primaryAction: { Task { _ = await session.flush() } },
                        secondaryTitle: "放弃未保存调整",
                        secondaryDisabled: session.isSaving,
                        secondaryAction: { session.discardDraft() }
                    )
                }

                if let error = session.renderError {
                    errorBanner(
                        title: error,
                        color: DarkroomPalette.warningAmber,
                        primaryTitle: "重试渲染",
                        primaryAction: { session.render(interactive: false) },
                        secondaryTitle: "放弃旧调整…",
                        secondaryDisabled: false,
                        secondaryAction: discardStale
                    )
                }

                // Group 1: Tone
                developGroupCard(
                    title: "明暗影调",
                    subtitle: nil,
                    resetTitle: "重置",
                    resetAction: {
                        var values = session.adjustments
                        for p in ColorParameter.allCases where p.group == .tone { values[p] = 0 }
                        session.apply(values)
                    }
                ) {
                    ForEach([ColorParameter.exposure, .contrast, .highlights, .shadows, .whites, .blacks], id: \.self) { param in
                        sliderRow(param)
                    }
                }

                // Group 2: White Balance
                developGroupCard(
                    title: "白平衡",
                    subtitle: session.isRAW ? "RAW · 绝对色温" : "普通图片 · 相对调整",
                    resetTitle: "拍摄时",
                    resetAction: { session.asShot() }
                ) {
                    sliderRow(.temperature)
                    sliderRow(.tint)
                }

                // Group 3: Color
                developGroupCard(
                    title: "色彩",
                    subtitle: nil,
                    resetTitle: "重置",
                    resetAction: {
                        var values = session.adjustments
                        for p in ColorParameter.allCases where p.group == .color { values[p] = 0 }
                        session.apply(values)
                    }
                ) {
                    sliderRow(.vibrance)
                    sliderRow(.saturation)
                }

                // Bottom actions
                HStack(spacing: 8) {
                    Button("复制调整", systemImage: "doc.on.doc") {
                        copyAdjustments()
                    }
                    .disabled(!session.usable)

                    Spacer()

                    Button(session.snapshot.isSystemPhoto ? "重置镜序调整" : "恢复原图") {
                        session.resetAll()
                    }
                    .disabled(session.result == nil || isTransitioning)
                }
                .controlSize(.small)
                .padding(.top, 2)

                Text(
                    session.snapshot.isSystemPhoto
                        ? "调整自动保存为本机草稿；点击顶栏「保存到系统照片」后提交，原片可随时复原。"
                        : "调整自动保存在本机图库（原片零修改）；导出成片可生成独立图片。"
                )
                .font(.caption2)
                .foregroundStyle(DarkroomPalette.textMuted)
            }
            .padding(14)
        }
        .disabled(isWorking || isTransitioning || externallyControlled || session.isExternallyControlled || session.isComposing)
        .onChange(of: focusedParameter) { previous, current in
            if previous != nil && current == nil {
                editingParameter = nil
                if !histogramIsDragging { session.endGesture() }
            }
        }
    }

    private func sliderRow(_ parameter: ColorParameter) -> some View {
        DarkroomSlider(
            session: session,
            parameter: parameter,
            focusedParameter: $focusedParameter,
            editingParameter: $editingParameter
        )
        .disabled(session.result == nil || isWorking || isTransitioning)
    }

    private func developGroupCard<Content: View>(
        title: String,
        subtitle: String?,
        resetTitle: String,
        resetAction: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DarkroomPalette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DarkroomPalette.textMuted)
                }
                Spacer()
                Button(resetTitle, action: resetAction)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .foregroundStyle(DarkroomPalette.textSecondary)
            }
            content()
        }
        .padding(11)
        .background(DarkroomPalette.canvasDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1)
        )
    }

    private func errorBanner(
        title: String,
        color: Color,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        secondaryTitle: String,
        secondaryDisabled: Bool,
        secondaryAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(color)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Button(primaryTitle, action: primaryAction)
                Button(secondaryTitle, action: secondaryAction)
                    .disabled(secondaryDisabled)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(color.opacity(0.45), lineWidth: 1)
        )
    }
}
