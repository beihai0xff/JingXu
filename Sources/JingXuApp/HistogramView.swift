import JingXuCore
import SwiftUI

struct HistogramView: View {
    @EnvironmentObject var model: AppModel
    let item: AssetListItem
    @State private var result: HistogramResult?
    @State private var failure: String?
    @State private var rgb = false
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("原片直方图")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DarkroomPalette.textPrimary)
                Spacer()
                if item.kind == .photo {
                    Picker("通道", selection: $rgb) {
                        Text("亮度").tag(false)
                        Text("RGB").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 96)
                }
            }

            if item.kind == .video {
                Text("不支持视频直方图")
                    .font(.caption)
                    .foregroundStyle(DarkroomPalette.textMuted)
            } else {
                ZStack {
                    DarkroomPalette.histogramWell
                    if let result {
                        Canvas { context, size in
                            let channels: [([Int], Color)] = rgb
                                ? [
                                    (result.red, Color(.sRGB, red: 0.95, green: 0.32, blue: 0.30, opacity: 1)),
                                    (result.green, Color(.sRGB, red: 0.30, green: 0.86, blue: 0.45, opacity: 1)),
                                    (result.blue, Color(.sRGB, red: 0.34, green: 0.58, blue: 0.98, opacity: 1))
                                ]
                                : [(result.luminance, DarkroomPalette.textPrimary)]
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
                                context.fill(path, with: .color(color.opacity(rgb ? 0.45 : 0.65)))
                            }
                        }
                    } else if let failure {
                        VStack(spacing: 6) {
                            Text(failure).font(.caption2).foregroundStyle(DarkroomPalette.warningAmber).multilineTextAlignment(.center)
                            Button("重试") { retry += 1 }.controlSize(.mini)
                        }
                        .padding(8)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1))

                HStack {
                    Text("0").monospacedDigit()
                    Spacer()
                    Text("基于解码预览 · sRGB")
                    Spacer()
                    Text("255").monospacedDigit()
                }
                .font(.system(size: 10))
                .foregroundStyle(DarkroomPalette.textMuted)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DarkroomPalette.canvasDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1))
        .task(id: "\(item.id)-\(retry)") {
            result = nil
            failure = nil
            guard item.kind == .photo else { return }
            do {
                let value = try await model.histogram(for: item)
                try Task.checkCancellation()
                result = value
            } catch is CancellationError {} catch {
                if !Task.isCancelled { failure = "无法读取直方图：\(error.localizedDescription)" }
            }
        }
    }
}
