import SwiftUI
import JingXuCore

struct CompositionPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var draft: CompositionSession
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("构图").font(.title2.bold())
                Text("当前照片 · 裁剪建议").font(.subheadline).foregroundStyle(.secondary)
                Picker("比例", selection: Binding(get: { draft.ratio }, set: { draft.setRatio($0) })) {
                    ForEach(CompositionRatio.allCases, id: \.self) { ratio in Text(ratio.title).tag(ratio) }
                }.disabled(draft.preview == nil)
                if draft.ratio.canRotate {
                    Picker("方向", selection: Binding(get: { draft.portrait }, set: { draft.setRatio(draft.ratio, portrait: $0) })) {
                        Text("横向").tag(false); Text("竖向").tag(true)
                    }.pickerStyle(.segmented)
                }
                Button("重新推荐") { draft.recommend() }
                    .disabled(draft.preview == nil || draft.ratio == .free || draft.isAnalyzing)
                if draft.ratio == .free { Text("自由比例仅用于手动裁剪，选择固定比例后可重新推荐。").font(.caption).foregroundStyle(.secondary) }
                if draft.isLoading { ProgressView("正在读取完整画面…") }
                if draft.isAnalyzing { ProgressView("正在分析主体…") }
                if !draft.message.isEmpty { Text(draft.message).font(.callout) }
                if let error = draft.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    if draft.preview == nil { Button("重试读取") { draft.start() } }
                }
                if let size = draft.pixelSize {
                    Text("成片尺寸：\(Int(size.width)) × \(Int(size.height)) 像素")
                        .font(.caption).monospacedDigit()
                }
                Divider()
                Text("拖动画框移动取景，拖动四角调整大小。建议优先保留检测到的人物与主体，请检查边缘人物和留白。").font(.caption).foregroundStyle(.secondary)
                Button("重置裁剪") { draft.reset() }.disabled(draft.preview == nil)
                HStack {
                    Button("取消") { model.colorEditor?.cancelComposition() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("应用") { model.applyComposition() }.buttonStyle(.borderedProminent)
                        .disabled(!draft.canApply)
                }
                Text("应用后自动保存到图库；取消不会改变已有编辑，原片始终保留。").font(.caption2).foregroundStyle(.secondary)
            }.padding(16)
        }.background(Color(nsColor: .controlBackgroundColor))
            .disabled(draft.isApplying || model.isPreviewTransitioning)
    }
}

struct CompositionCanvas: View {
    @ObservedObject var draft: CompositionSession
    @State private var dragStart: CropAdjustment?
    var body: some View {
        GeometryReader { proxy in
            if let preview = draft.preview {
                let scale = PreviewGeometry.fit(image: preview.nativeSize, viewport: CGSize(width: max(1, proxy.size.width - 32), height: max(1, proxy.size.height - 32)))
                let size = CGSize(width: preview.nativeSize.width * scale, height: preview.nativeSize.height * scale)
                let crop = CGRect(x: draft.crop.x * size.width, y: draft.crop.y * size.height,
                    width: draft.crop.width * size.width, height: draft.crop.height * size.height)
                ZStack(alignment: .topLeading) {
                    Image(decorative: preview.image, scale: 1).resizable().frame(width: size.width, height: size.height)
                    Canvas { context, _ in
                        var mask = Path(CGRect(origin: .zero, size: size)); mask.addRect(crop)
                        context.fill(mask, with: .color(.black.opacity(0.6)), style: FillStyle(eoFill: true))
                        context.stroke(Path(crop), with: .color(.white), lineWidth: 1)
                        var grid = Path()
                        for fraction in [1.0 / 3, 2.0 / 3] {
                            let x = crop.minX + crop.width * fraction, y = crop.minY + crop.height * fraction
                            grid.move(to: CGPoint(x: x, y: crop.minY)); grid.addLine(to: CGPoint(x: x, y: crop.maxY))
                            grid.move(to: CGPoint(x: crop.minX, y: y)); grid.addLine(to: CGPoint(x: crop.maxX, y: y))
                        }
                        context.stroke(grid, with: .color(.white.opacity(0.55)), lineWidth: 0.5)
                    }.allowsHitTesting(false)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .frame(width: crop.width, height: crop.height).offset(x: crop.minX, y: crop.minY)
                        .gesture(drag(size: size, image: preview.nativeSize, corner: nil))
                        .accessibilityLabel("移动裁剪框")
                    ForEach(0..<4) { corner in
                        let point = CGPoint(x: corner == 0 || corner == 3 ? crop.minX : crop.maxX,
                            y: corner < 2 ? crop.minY : crop.maxY)
                        Circle().fill(.white).frame(width: 10, height: 10)
                            .shadow(color: .black.opacity(0.6), radius: 2)
                            .frame(width: 28, height: 28).contentShape(Rectangle())
                            .position(point)
                            .gesture(drag(size: size, image: preview.nativeSize, corner: corner))
                            .accessibilityLabel(["左上裁剪角", "右上裁剪角", "右下裁剪角", "左下裁剪角"][corner])
                    }
                }.frame(width: size.width, height: size.height)
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .allowsHitTesting(!draft.isApplying)
            } else if draft.isLoading {
                ProgressView("正在读取完整画面…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(.black)
    }
    private func drag(size: CGSize, image: CGSize, corner: Int?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragStart == nil { dragStart = draft.crop }
                guard let start = dragStart else { return }
                let delta = CGSize(width: value.translation.width / size.width, height: value.translation.height / size.height)
                if let corner { draft.setCrop(CropGeometry.resized(start, corner: corner, delta: delta, image: image, ratio: draft.aspectRatio)) }
                else { draft.setCrop(CropGeometry.moved(start, delta: delta)) }
            }.onEnded { _ in dragStart = nil }
    }
}
