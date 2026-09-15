import SwiftUI
import JingXuCore

struct ColorHistogram: View {
    @ObservedObject var session: ColorEditSession
    let result: HistogramResult
    let enabled: Bool
    let prepare: () -> Void
    let finished: () -> Void
    @State private var hovered: ColorParameter?
    @State private var drag: HistogramDrag?
    @State private var interrupted = false
    @GestureState private var gestureActive = false
    @Environment(\.scenePhase) private var scenePhase

    private var active: ColorParameter? { drag?.parameter ?? hovered }

    var body: some View {
        GroupBox("成片直方图 · sRGB") {
            VStack(spacing: 5) {
                GeometryReader { geometry in
                    Canvas { context, size in
                        let channels: [([Int], Color)] = [(result.red, .red), (result.green, .green), (result.blue, .blue)]
                        let peak = max(1, channels.flatMap { $0.0 }.max() ?? 1)
                        for (bins, color) in channels {
                            var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
                            for i in 0..<256 {
                                path.addLine(to: CGPoint(x: Double(i) / 255 * size.width,
                                    y: size.height * (1 - Double(bins[i]) / Double(peak))))
                            }
                            path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                            context.fill(path, with: .color(color.opacity(0.45)))
                        }
                        if enabled, let active, let index = HistogramDrag.parameters.firstIndex(of: active) {
                            let region = CGRect(x: size.width * Double(index) / 5, y: 0, width: size.width / 5, height: size.height)
                            context.fill(Path(region), with: .color(.white.opacity(0.16)))
                            context.stroke(Path(region), with: .color(.white.opacity(0.4)), lineWidth: 1)
                        }
                    }
                    .background(.black.opacity(0.3))
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hovered = enabled ? HistogramDrag.parameter(at: point.x, width: geometry.size.width) : nil
                        case .ended: hovered = nil
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 2)
                        .updating($gestureActive) { _, state, _ in state = true }
                        .onChanged { value in
                            guard enabled, !interrupted else { return }
                            if drag == nil {
                                guard let parameter = HistogramDrag.parameter(at: value.startLocation.x, width: geometry.size.width) else { return }
                                prepare()
                                drag = HistogramDrag(startX: value.startLocation.x, width: geometry.size.width,
                                    initialValue: session.displayValue(parameter))
                                session.beginGesture()
                            }
                            if let drag { session.change(drag.parameter, value: drag.value(translation: value.translation.width)) }
                        }
                        .onEnded { _ in finishDrag(); interrupted = false })
                    .accessibilityLabel("成片直方图")
                    .accessibilityHint("从左至右拖动黑色、阴影、曝光、高光、白色区域；也可使用下方同名滑块调整")
                }.frame(height: 100)
                HStack {
                    if enabled, let active {
                        Text(active.title)
                        Text(session.displayValue(active), format: .number.precision(.fractionLength(active == .exposure ? 2 : 0)))
                        if active == .exposure { Text("EV") }
                        Spacer()
                        Text("左右拖动调整")
                    } else {
                        Text("黑色 · 阴影 · 曝光 · 高光 · 白色")
                    }
                }.font(.caption2).foregroundStyle(.secondary).frame(height: 16)
            }
        }
        .onChange(of: gestureActive) { _, active in if !active { finishDrag(); interrupted = false } }
        .onChange(of: enabled) { _, enabled in if !enabled { hovered = nil; interruptDrag() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { interruptDrag() } }
        .onDisappear { finishDrag() }
    }

    private func interruptDrag() {
        interrupted = gestureActive
        finishDrag()
    }

    private func finishDrag() {
        guard drag != nil else { return }
        drag = nil
        session.endGesture()
        finished()
    }
}
