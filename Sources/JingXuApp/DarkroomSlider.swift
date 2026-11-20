import JingXuCore
import SwiftUI

struct DarkroomSlider: View {
    @ObservedObject var session: ColorEditSession
    let parameter: ColorParameter
    var focusedParameter: FocusState<ColorParameter?>.Binding
    @Binding var editingParameter: ColorParameter?

    @State private var isDraggingSlider = false
    @State private var suppressDragUntilEnd = false
    @State private var lastTapUptime: TimeInterval = 0
    @State private var lastTapX: CGFloat = 0
    @GestureState private var gestureActive = false
    @Environment(\.scenePhase) private var scenePhase

    private var currentValue: Double { session.displayValue(parameter) }

    private var isModified: Bool {
        if parameter.group == .whiteBalance {
            if session.adjustments.whiteBalance == .asShot { return false }
            if !session.isRAW { return abs(session.adjustments[parameter]) > 0.0001 }
            return true
        }
        return abs(session.adjustments[parameter]) > 0.0001
    }

    private var formattedValue: String {
        switch parameter {
        case .exposure:
            let sign = currentValue > 0.004 ? "+" : ""
            return sign + String(format: "%.2f EV", currentValue)
        case .temperature:
            if session.isRAW {
                return "\(Int(currentValue.rounded())) K"
            }
            let rounded = Int(currentValue.rounded())
            return (rounded > 0 ? "+" : "") + "\(rounded)"
        default:
            let rounded = Int(currentValue.rounded())
            return (rounded > 0 ? "+" : "") + "\(rounded)"
        }
    }

    var body: some View {
        let geometry = DarkroomSliderGeometry(parameter: parameter, value: currentValue, isRAW: session.isRAW)

        VStack(spacing: 5) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(isModified ? Color.accentColor : Color.clear)
                        .frame(width: 4.5, height: 4.5)
                    Text(parameter.title)
                        .font(.caption.weight(isModified ? .medium : .regular))
                        .foregroundStyle(isModified ? DarkroomPalette.textPrimary : DarkroomPalette.textSecondary)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    editingParameter = nil
                    focusedParameter.wrappedValue = nil
                    session.reset(parameter)
                }
                .help("双击重置\(parameter.title)")

                Spacer()

                if editingParameter == parameter {
                    TextField(
                        parameter.title,
                        value: Binding(
                            get: { session.displayValue(parameter) },
                            set: { session.change(parameter, value: $0) }
                        ),
                        format: .number.precision(.fractionLength(parameter == .exposure ? 2 : 0))
                    )
                    .textFieldStyle(.plain)
                    .font(.caption.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .frame(width: 68)
                    .background(DarkroomPalette.elevatedControl, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 1)
                    )
                    .focused(focusedParameter, equals: parameter)
                    .onSubmit {
                        session.endGesture()
                        editingParameter = nil
                        focusedParameter.wrappedValue = nil
                    }
                } else {
                    Button {
                        session.beginGesture()
                        editingParameter = parameter
                        focusedParameter.wrappedValue = parameter
                    } label: {
                        Text(formattedValue)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(isModified ? DarkroomPalette.textPrimary : DarkroomPalette.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                isModified ? DarkroomPalette.elevatedControl : DarkroomPalette.elevatedControl.opacity(0.45),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("单击输入精确数值，双击左侧标题重置")
                }
            }

            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let thumbX = CGFloat(geometry.thumbFraction) * width

                ZStack(alignment: .leading) {
                    trackBackground
                        .frame(height: 4)
                        .clipShape(Capsule())

                    if let zero = geometry.zeroFraction {
                        Rectangle()
                            .fill(DarkroomPalette.textMuted)
                            .frame(width: 1, height: 10)
                            .offset(x: CGFloat(zero) * width - 0.5)
                    }

                    if geometry.fillWidth > 0.001 {
                        Capsule()
                            .fill(isModified ? Color.accentColor.opacity(0.88) : DarkroomPalette.textSecondary.opacity(0.45))
                            .frame(width: max(2, CGFloat(geometry.fillWidth) * width), height: 4)
                            .offset(x: CGFloat(geometry.fillStart) * width)
                    }

                    Circle()
                        .fill(DarkroomPalette.textPrimary)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .strokeBorder(isDraggingSlider ? Color.accentColor : Color.black.opacity(0.35), lineWidth: isDraggingSlider ? 2 : 1)
                        )
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .offset(x: min(max(0, thumbX - 6), max(0, width - 12)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($gestureActive) { _, state, _ in state = true }
                        .onChanged { value in
                            guard !suppressDragUntilEnd else { return }
                            if !isDraggingSlider {
                                let now = ProcessInfo.processInfo.systemUptime
                                if now - lastTapUptime < 0.28 && abs(value.startLocation.x - lastTapX) < 10 && abs(value.translation.width) < 3 {
                                    suppressDragUntilEnd = true
                                    lastTapUptime = 0
                                    editingParameter = nil
                                    focusedParameter.wrappedValue = nil
                                    session.reset(parameter)
                                    return
                                }
                                editingParameter = nil
                                focusedParameter.wrappedValue = nil
                                isDraggingSlider = true
                                session.beginGesture()
                            }
                            let fraction = Double(value.location.x / width)
                            session.change(parameter, value: geometry.value(forFraction: fraction))
                        }
                        .onEnded { value in
                            if isDraggingSlider {
                                isDraggingSlider = false
                                session.endGesture()
                                if abs(value.translation.width) < 3 && abs(value.translation.height) < 3 {
                                    lastTapUptime = ProcessInfo.processInfo.systemUptime
                                    lastTapX = value.startLocation.x
                                }
                            }
                            suppressDragUntilEnd = false
                        }
                )
                .accessibilityElement()
                .accessibilityLabel(parameter.title)
                .accessibilityValue(formattedValue)
                .accessibilityAdjustableAction { direction in
                    let step = parameter == .exposure ? 0.1 : (parameter == .temperature && session.isRAW ? 100.0 : 5.0)
                    let delta = direction == .increment ? step : -step
                    let clamped = min(geometry.range.upperBound, max(geometry.range.lowerBound, currentValue + delta))
                    session.beginGesture()
                    session.change(parameter, value: clamped)
                    session.endGesture()
                }
            }
            .frame(height: 16)
        }
        .onChange(of: gestureActive) { _, active in
            if !active && isDraggingSlider {
                isDraggingSlider = false
                suppressDragUntilEnd = false
                session.endGesture()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && isDraggingSlider {
                isDraggingSlider = false
                suppressDragUntilEnd = false
                session.endGesture()
            }
        }
        .onDisappear {
            if isDraggingSlider {
                isDraggingSlider = false
                suppressDragUntilEnd = false
                session.endGesture()
            }
        }
    }

    @ViewBuilder
    private var trackBackground: some View {
        switch parameter {
        case .temperature:
            LinearGradient(
                colors: [
                    Color(.sRGB, red: 0.30, green: 0.52, blue: 0.90, opacity: 0.38),
                    DarkroomPalette.elevatedControl,
                    Color(.sRGB, red: 0.92, green: 0.66, blue: 0.25, opacity: 0.38)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        case .tint:
            LinearGradient(
                colors: [
                    Color(.sRGB, red: 0.28, green: 0.74, blue: 0.43, opacity: 0.34),
                    DarkroomPalette.elevatedControl,
                    Color(.sRGB, red: 0.85, green: 0.36, blue: 0.74, opacity: 0.34)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        default:
            DarkroomPalette.elevatedControl
        }
    }
}
