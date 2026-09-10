import SwiftUI
import JingXuCore

struct ColorEditPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: ColorEditSession
    @FocusState private var focusedParameter: ColorParameter?
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
                    Toggle("原图对比", isOn: $session.comparing).toggleStyle(.button)
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
                if let result = session.result { ColorHistogram(result: result.histogram) }
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
            .onChange(of: focusedParameter) { previous, _ in if previous != nil { session.endGesture() } }
    }
}

struct ColorHistogram: View {
    let result: HistogramResult
    var body: some View {
        GroupBox("成片直方图 · sRGB") {
            Canvas { context, size in
                let channels: [([Int], Color)] = [(result.red, .red), (result.green, .green), (result.blue, .blue)]
                let peak = max(1, channels.flatMap { $0.0 }.max() ?? 1)
                for (bins, color) in channels {
                    var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
                    for i in 0..<256 { path.addLine(to: CGPoint(x: Double(i) / 255 * size.width, y: size.height * (1 - Double(bins[i]) / Double(peak)))) }
                    path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                    context.fill(path, with: .color(color.opacity(0.45)))
                }
            }.frame(height: 76).background(.black.opacity(0.3))
        }
    }
}
