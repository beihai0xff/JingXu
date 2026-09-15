import SwiftUI
import JingXuCore

struct ColorEditPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ColorEditSession
    @FocusState private var focusedParameter: ColorParameter?
    @State private var histogramIsDragging = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("调色").font(.title2.bold())
                    if session.isRendering { ProgressView().controlSize(.small) }
                    Spacer()
                    Text(session.isSaving ? "正在保存…" : session.isDirty ? "未保存" : "已保存").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("撤销") { session.undo() }.disabled(!session.history.canUndo)
                    Button("重做") { session.redo() }.disabled(!session.history.canRedo)
                    Spacer()
                    Button(session.comparing ? "松开恢复成片" : "按住对比原图") {}
                        .buttonStyle(OriginalComparisonButtonStyle { pressed in
                            if pressed {
                                focusedParameter = nil
                                session.beginComparison()
                            } else { session.endComparison() }
                        })
                        .disabled(!session.usable || model.isWorking)
                        .help("按住查看未调色、未裁剪的原图，松开或移出按钮恢复成片；不会修改调整。")
                }.disabled(model.isPreviewTransitioning)
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
                        Button("放弃旧调整…") { model.discardStaleColor() }
                    }
                }
                if let result = session.result {
                    ColorHistogram(session: session, result: result.histogram,
                        enabled: session.usable && !model.isWorking && !model.isPreviewTransitioning &&
                            !model.automationOwnsOperation && !session.isExternallyControlled && !session.isComposing,
                        prepare: {
                            histogramIsDragging = true
                            focusedParameter = nil
                            session.endGesture()
                        }, finished: { histogramIsDragging = false })
                        .id(session.snapshot.asset.id)
                }
                ForEach(ColorGroup.allCases, id: \.self) { group in
                    GroupBox(group.title) {
                        VStack(spacing: 10) {
                            if group == .whiteBalance {
                                HStack {
                                    Text(session.isRAW ? "RAW · 绝对色温" : "普通图片 · 相对调整").font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("拍摄时") { session.asShot() }.font(.caption)
                                }
                            }
                            ForEach(ColorParameter.allCases.filter { $0.group == group }, id: \.self) { p in
                                VStack(spacing: 2) {
                                    HStack {
                                        Text(p.title).font(.caption)
                                        Spacer()
                                        TextField(p.title, value: Binding(get: { session.displayValue(p) }, set: { session.change(p, value: $0) }), format: .number.precision(.fractionLength(p == .exposure ? 2 : 0)))
                                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 74)
                                            .focused($focusedParameter, equals: p)
                                            .onSubmit { session.endGesture() }
                                        Button { session.reset(p) } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.borderless).help("重置\(p.title)")
                                    }
                                    Slider(value: Binding(get: { session.displayValue(p) }, set: { session.change(p, value: $0) }),
                                        in: p.range(isRAW: session.isRAW), step: p == .exposure ? 0.01 : 1,
                                        onEditingChanged: { editing in if editing { session.beginGesture() } else { session.endGesture() } })
                                        .accessibilityLabel(p.title)
                                }
                            }
                        }.padding(.vertical, 4)
                    }.disabled(session.result == nil || model.isWorking || model.isPreviewTransitioning)
                }
                HStack {
                    Button("复制调整") { model.copyColorAdjustments() }
                    Button("预设…") { model.showColorPresets() }
                    Spacer()
                }.disabled(!session.usable)
                Button("恢复原图") { session.resetAll() }.disabled(session.result == nil || model.isPreviewTransitioning)
                Text("调整自动保存在图库；导出成片可生成独立图片。").font(.caption2).foregroundStyle(.secondary)
            }.padding(14)
        }.background(Color(nsColor: .controlBackgroundColor))
            .disabled(model.automationOwnsOperation || session.isExternallyControlled || session.isComposing)
            .onChange(of: focusedParameter) { previous, _ in if previous != nil && !histogramIsDragging { session.endGesture() } }
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
