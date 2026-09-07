import SwiftUI
import JingXuCore

struct HistogramView: View {
    @EnvironmentObject var model: AppModel
    let item: AssetListItem
    @State private var result: HistogramResult?
    @State private var failure: String?
    @State private var rgb = false
    @State private var retry = 0
    var body: some View {
        GroupBox("直方图") {
            VStack(spacing: 8) {
                if item.kind == .video { Text("不支持视频直方图").font(.caption) }
                else {
                    Picker("通道", selection: $rgb) {
                        Text("亮度").tag(false); Text("RGB").tag(true)
                    }.pickerStyle(.segmented)
                    if let result {
                        Canvas { context, size in
                            let channels: [([Int], Color)] = rgb ? [(result.red, .red), (result.green, .green), (result.blue, .blue)] : [(result.luminance, .gray)]
                            let peak = max(1, channels.flatMap { $0.0 }.max() ?? 1)
                            for (bins, color) in channels {
                                var path = Path()
                                path.move(to: CGPoint(x: 0, y: size.height))
                                for i in 0..<256 {
                                    path.addLine(to: CGPoint(x: Double(i) / 255 * size.width, y: size.height * (1 - Double(bins[i]) / Double(peak))))
                                }
                                path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                                context.fill(path, with: .color(color.opacity(rgb ? 0.45 : 0.8)))
                            }
                        }.frame(height: 100).background(.black.opacity(0.08))
                        HStack { Text("0"); Spacer(); Text("255") }.font(.caption2)
                    } else if let failure {
                        Text(failure).font(.caption)
                        Button("重试") { retry += 1 }
                    } else { ProgressView().frame(height: 100) }
                    Text("基于解码预览 · sRGB").font(.caption2).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity)
        }
        .task(id: "\(item.id)-\(retry)") {
            result = nil; failure = nil
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
