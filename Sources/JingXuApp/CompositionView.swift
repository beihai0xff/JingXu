import JingXuCore
import SwiftUI

struct CompositionPanel: View {
    @ObservedObject var draft: CompositionSession
    let isBusy: Bool
    let cancel: () -> Void
    let apply: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("画幅比例")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DarkroomPalette.textPrimary)

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(CompositionRatio.allCases, id: \.self) { ratio in
                            let selected = draft.ratio == ratio
                            Button {
                                draft.setRatio(ratio)
                            } label: {
                                Text(ratio.title)
                                    .font(.caption.weight(selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Color.white : DarkroomPalette.textPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                                    .background(
                                        selected ? Color.accentColor : DarkroomPalette.elevatedControl,
                                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .strokeBorder(selected ? Color.accentColor : DarkroomPalette.subtleDivider, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(draft.preview == nil)
                        }
                    }
                }

                if draft.ratio.canRotate {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("取景方向")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DarkroomPalette.textPrimary)
                        Picker("方向", selection: Binding(
                            get: { draft.portrait },
                            set: { draft.setRatio(draft.ratio, portrait: $0) }
                        )) {
                            Text("横向").tag(false)
                            Text("竖向").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }

                HStack(spacing: 8) {
                    Button("智能推荐构图", systemImage: "sparkles") {
                        draft.recommend()
                    }
                    .controlSize(.small)
                    .disabled(draft.preview == nil || draft.ratio == .free || draft.isAnalyzing)

                    Spacer()

                    Button("重置裁剪") {
                        draft.reset()
                    }
                    .controlSize(.small)
                    .disabled(draft.preview == nil)
                }

                if draft.ratio == .free {
                    Text("自由比例仅用于手动裁剪；选择固定比例后可智能推荐。")
                        .font(.caption2)
                        .foregroundStyle(DarkroomPalette.textMuted)
                }

                if draft.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在读取完整画面…").font(.caption).foregroundStyle(DarkroomPalette.textSecondary)
                    }
                }
                if draft.isAnalyzing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在检测人物与主体…").font(.caption).foregroundStyle(DarkroomPalette.textSecondary)
                    }
                }
                if !draft.message.isEmpty {
                    Text(draft.message)
                        .font(.caption)
                        .foregroundStyle(DarkroomPalette.textSecondary)
                }
                if let error = draft.errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(DarkroomPalette.warningAmber)
                            .textSelection(.enabled)
                        if draft.preview == nil {
                            Button("重试读取") { draft.start() }.controlSize(.small)
                        }
                    }
                }

                if let size = draft.pixelSize {
                    HStack {
                        Text("成片像素尺寸")
                            .font(.caption)
                            .foregroundStyle(DarkroomPalette.textSecondary)
                        Spacer()
                        Text("\(Int(size.width)) × \(Int(size.height)) px")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(DarkroomPalette.textPrimary)
                    }
                    .padding(9)
                    .background(DarkroomPalette.elevatedControl, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                Divider().overlay(DarkroomPalette.subtleDivider)

                Text("拖动画框移动取景，拖动四角调整大小。智能推荐优先保留检测到的人物与主体。")
                    .font(.caption2)
                    .foregroundStyle(DarkroomPalette.textMuted)

                HStack {
                    Button("取消") { cancel() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("应用裁剪") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.canApply)
                }
                .controlSize(.small)

                Text("应用后写入非破坏式调整；取消不改变已有编辑，原片始终保留。")
                    .font(.caption2)
                    .foregroundStyle(DarkroomPalette.textMuted)
            }
            .padding(14)
        }
        .disabled(draft.isApplying || isBusy)
    }
}

struct CompositionCanvas: View {
    @ObservedObject var draft: CompositionSession
    @State private var dragStart: CropAdjustment?

    var body: some View {
        GeometryReader { proxy in
            if let preview = draft.preview {
                let scale = PreviewGeometry.fit(
                    image: preview.nativeSize,
                    viewport: CGSize(width: max(1, proxy.size.width - 36), height: max(1, proxy.size.height - 36))
                )
                let size = CGSize(width: preview.nativeSize.width * scale, height: preview.nativeSize.height * scale)
                let crop = CGRect(
                    x: draft.crop.x * size.width,
                    y: draft.crop.y * size.height,
                    width: draft.crop.width * size.width,
                    height: draft.crop.height * size.height
                )
                ZStack(alignment: .topLeading) {
                    Image(decorative: preview.image, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)

                    Canvas { context, _ in
                        var mask = Path(CGRect(origin: .zero, size: size))
                        mask.addRect(crop)
                        context.fill(mask, with: .color(.black.opacity(0.65)), style: FillStyle(eoFill: true))
                        context.stroke(Path(crop), with: .color(.white), lineWidth: 1.2)
                        var grid = Path()
                        for fraction in [1.0 / 3, 2.0 / 3] {
                            let x = crop.minX + crop.width * fraction
                            let y = crop.minY + crop.height * fraction
                            grid.move(to: CGPoint(x: x, y: crop.minY))
                            grid.addLine(to: CGPoint(x: x, y: crop.maxY))
                            grid.move(to: CGPoint(x: crop.minX, y: y))
                            grid.addLine(to: CGPoint(x: crop.maxX, y: y))
                        }
                        context.stroke(grid, with: .color(.white.opacity(0.55)), lineWidth: 0.6)
                    }
                    .allowsHitTesting(false)

                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .frame(width: crop.width, height: crop.height)
                        .offset(x: crop.minX, y: crop.minY)
                        .gesture(drag(size: size, image: preview.nativeSize, corner: nil))
                        .accessibilityLabel("移动裁剪框")

                    ForEach(0..<4) { corner in
                        let point = CGPoint(
                            x: corner == 0 || corner == 3 ? crop.minX : crop.maxX,
                            y: corner < 2 ? crop.minY : crop.maxY
                        )
                        Circle()
                            .fill(.white)
                            .frame(width: 10, height: 10)
                            .shadow(color: .black.opacity(0.65), radius: 2)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                            .position(point)
                            .gesture(drag(size: size, image: preview.nativeSize, corner: corner))
                            .accessibilityLabel(["左上裁剪角", "右上裁剪角", "右下裁剪角", "左下裁剪角"][corner])
                    }
                }
                .frame(width: size.width, height: size.height)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .allowsHitTesting(!draft.isApplying)
            } else if draft.isLoading {
                ProgressView("正在读取完整画面…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .darkroomStageSurface()
    }

    private func drag(size: CGSize, image: CGSize, corner: Int?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if dragStart == nil { dragStart = draft.crop }
                guard let start = dragStart else { return }
                let delta = CGSize(width: value.translation.width / size.width, height: value.translation.height / size.height)
                if let corner {
                    draft.setCrop(CropGeometry.resized(start, corner: corner, delta: delta, image: image, ratio: draft.aspectRatio))
                } else {
                    draft.setCrop(CropGeometry.moved(start, delta: delta))
                }
            }
            .onEnded { _ in dragStart = nil }
    }
}
