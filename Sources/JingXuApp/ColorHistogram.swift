import JingXuCore
import SwiftUI

struct ColorHistogram: View {
    @ObservedObject var session: ColorEditSession
    let result: HistogramResult?
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
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack {
                    DarkroomPalette.histogramWell

                    if let result {
                        Canvas { context, size in
                            // Quarter-tone subtle gridlines
                            for fraction in [0.2, 0.4, 0.6, 0.8] {
                                let x = size.width * fraction
                                var line = Path()
                                line.move(to: CGPoint(x: x, y: 0))
                                line.addLine(to: CGPoint(x: x, y: size.height))
                                context.stroke(line, with: .color(DarkroomPalette.subtleDivider.opacity(0.45)), lineWidth: 0.5)
                            }

                            let channels: [([Int], Color)] = [
                                (result.red, Color(.sRGB, red: 0.95, green: 0.32, blue: 0.30, opacity: 1)),
                                (result.green, Color(.sRGB, red: 0.30, green: 0.86, blue: 0.45, opacity: 1)),
                                (result.blue, Color(.sRGB, red: 0.34, green: 0.58, blue: 0.98, opacity: 1))
                            ]
                            let peak = max(1, channels.flatMap { $0.0 }.max() ?? 1)
                            for (bins, color) in channels {
                                var path = Path()
                                path.move(to: CGPoint(x: 0, y: size.height))
                                for i in 0..<256 {
                                    path.addLine(to: CGPoint(
                                        x: Double(i) / 255 * size.width,
                                        y: size.height * (1 - Double(bins[i]) / Double(peak))
                                    ))
                                }
                                path.addLine(to: CGPoint(x: size.width, y: size.height))
                                path.closeSubpath()
                                context.fill(path, with: .color(color.opacity(0.42)))
                            }
                            if enabled, let active, let index = HistogramDrag.parameters.firstIndex(of: active) {
                                let region = CGRect(x: size.width * Double(index) / 5, y: 0, width: size.width / 5, height: size.height)
                                context.fill(Path(region), with: .color(.white.opacity(0.12)))
                                context.stroke(Path(region), with: .color(.white.opacity(0.35)), lineWidth: 1)
                            }
                        }
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1)
                )
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hovered = (enabled && result != nil) ? HistogramDrag.parameter(at: point.x, width: geometry.size.width) : nil
                    case .ended:
                        hovered = nil
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .updating($gestureActive) { _, state, _ in state = true }
                        .onChanged { value in
                            guard enabled, result != nil, !interrupted else { return }
                            if drag == nil {
                                guard let parameter = HistogramDrag.parameter(at: value.startLocation.x, width: geometry.size.width) else { return }
                                prepare()
                                drag = HistogramDrag(
                                    startX: value.startLocation.x,
                                    width: geometry.size.width,
                                    initialValue: session.displayValue(parameter)
                                )
                                session.beginGesture()
                            }
                            if let drag {
                                session.change(drag.parameter, value: drag.value(translation: value.translation.width))
                            }
                        }
                        .onEnded { _ in finishDrag(); interrupted = false }
                )
                .accessibilityLabel("成片直方图")
                .accessibilityHint("从左至右拖动黑色、阴影、曝光、高光、白色区域；也可使用下方同名滑块调整")
            }
            .frame(height: 96)

            HStack(spacing: 4) {
                if enabled, let active {
                    Text(active.title)
                        .foregroundStyle(DarkroomPalette.textPrimary)
                    Text(session.displayValue(active), format: .number.precision(.fractionLength(active == .exposure ? 2 : 0)))
                        .monospacedDigit()
                        .foregroundStyle(DarkroomPalette.textPrimary)
                    if active == .exposure { Text("EV").foregroundStyle(DarkroomPalette.textSecondary) }
                    Spacer()
                    Text("左右拖动调整")
                        .foregroundStyle(DarkroomPalette.textMuted)
                } else {
                    Text("sRGB 成片直方图")
                        .foregroundStyle(DarkroomPalette.textMuted)
                    Spacer()
                    Text("黑 · 阴影 · 曝光 · 高光 · 白")
                        .foregroundStyle(DarkroomPalette.textMuted)
                }
            }
            .font(.system(size: 10.5))
            .frame(height: 14)
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
