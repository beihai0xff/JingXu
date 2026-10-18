import SwiftUI
import JingXuCore

struct ColorEditPanel: View {
    @ObservedObject var session: ColorEditSession
    let isWorking: Bool
    let isTransitioning: Bool
    let externallyControlled: Bool
    let copyAdjustments: () -> Void
    let discardStale: () -> Void
    @FocusState private var focusedParameter: ColorParameter?
    @State private var histogramIsDragging = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button("撤销") { session.undo() }.disabled(!session.history.canUndo)
                    Button("重做") { session.redo() }.disabled(!session.history.canRedo)
                    Spacer()
                    Button(session.comparing ? "松开恢复成片" : (session.snapshot.usesRenderedBase ? "本次编辑前对比" : "按住对比原图")) {}
                        .buttonStyle(OriginalComparisonButtonStyle { pressed in
                            if pressed {
                                focusedParameter = nil
                                session.beginComparison()
                            } else { session.endComparison() }
                        })
                        .disabled(!session.usable || isWorking)
                        .help(session.snapshot.usesRenderedBase ? "按住查看其他应用提供的成片底图；只移除镜序调整，保留之前的编辑。" : "按住查看未调色、未裁剪的原图，松开或移出按钮恢复成片；不会修改调整。")
                }.disabled(isTransitioning)
                if let error = session.saveError {
                    Text("保存失败：\(error)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    HStack {
                        Button("重试保存") { Task { _ = await session.flush() } }
                        Button("放弃未保存调整") { session.discardDraft() }.disabled(session.isSaving)
                    }
                }
                if let error = session.renderError {
                    Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    HStack {
                        Button("重试") { session.render(interactive: false) }
                        Button("放弃旧调整…") { discardStale() }
                    }
                }
                DisclosureGroup("直方图") {
                    if let result = session.result {
                        ColorHistogram(session: session, result: result.histogram,
                            enabled: session.usable && !isWorking && !isTransitioning && !externallyControlled && !session.isExternallyControlled,
                            prepare: { histogramIsDragging = true; focusedParameter = nil; session.endGesture() },
                            finished: { histogramIsDragging = false })
                    }
                }
                HStack {
                    Text("明暗").font(.headline)
                    Spacer()
                    Button("重置") {
                        var values = session.adjustments
                        for p in ColorParameter.allCases where p.group == .tone { values[p] = 0 }
                        session.apply(values)
                    }.buttonStyle(.borderless).font(.caption)
                }.padding(.top, 8)
                ForEach([ColorParameter.exposure, .contrast, .highlights, .shadows], id: \.self) { parameter($0) }
                DisclosureGroup("白色与黑色") {
                    VStack(spacing: 10) { parameter(.whites); parameter(.blacks) }.padding(.top, 10)
                }
                Divider()
                DisclosureGroup("白平衡") {
                    VStack(spacing: 10) {
                        HStack {
                            Text(session.isRAW ? "RAW · 绝对色温" : "普通图片 · 相对调整").font(.caption).foregroundStyle(.secondary)
                            Spacer(); Button("拍摄时") { session.asShot() }.font(.caption)
                        }
                        parameter(.temperature); parameter(.tint)
                    }.padding(.top, 10)
                }
                Divider()
                DisclosureGroup("色彩") {
                    VStack(spacing: 10) { parameter(.saturation); parameter(.vibrance) }.padding(.top, 10)
                }
                Divider()
                HStack {
                    Button("复制调整") { copyAdjustments() }
                    Spacer()
                }.disabled(!session.usable)
                Button(session.snapshot.isSystemPhoto ? "重置镜序调整" : "恢复原图") { session.resetAll() }.disabled(session.result == nil || isTransitioning)
                Text(session.snapshot.isSystemPhoto ? "调整自动保存为本机草稿；点击「保存到系统照片」后提交。" : "调整自动保存在图库；导出成片可生成独立图片。").font(.caption2).foregroundStyle(.secondary)
            }.padding(14)
        }.background(Color(nsColor: .controlBackgroundColor))
            .disabled(isWorking || isTransitioning || externallyControlled || session.isExternallyControlled || session.isComposing)
            .onChange(of: focusedParameter) { previous, _ in if previous != nil && !histogramIsDragging { session.endGesture() } }
    }
    private func parameter(_ p: ColorParameter) -> some View {
        VStack(spacing: 2) {
            HStack {
                Text(p.title).font(.callout)
                Spacer()
                TextField(p.title, value: Binding(get: { session.displayValue(p) }, set: { session.change(p, value: $0) }),
                    format: .number.precision(.fractionLength(p == .exposure ? 2 : 0)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 68)
                    .focused($focusedParameter, equals: p).onSubmit { session.endGesture() }
                Button { session.reset(p) } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless).help("重置\(p.title)").accessibilityLabel("重置\(p.title)")
            }
            Slider(value: Binding(get: { session.displayValue(p) }, set: { session.change(p, value: $0) }),
                in: p.range(isRAW: session.isRAW), step: p == .exposure ? 0.01 : 1,
                onEditingChanged: { editing in if editing { session.beginGesture() } else { session.endGesture() } })
                .accessibilityLabel(p.title)
        }.disabled(session.result == nil || isWorking || isTransitioning)
    }

}

/// ButtonStyle follows mouse and keyboard press state, including dragging outside the button.
private struct OriginalComparisonButtonStyle: ButtonStyle {
    let pressed: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(configuration.isPressed ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, value in pressed(value) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in pressed(false) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in pressed(false) }
            .onDisappear { pressed(false) }
    }
}
