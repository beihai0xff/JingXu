import JingXuCore
import SwiftUI

struct PhotoSharePresentation: ViewModifier {
    @ObservedObject var model: AppModel
    @ObservedObject var session: PhotoShareSession
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.isShowingPhotoShare) {
                PhotoShareSheet(model: model, session: session).interactiveDismissDisabled()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if session.phase == .sharing {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text(session.message).font(.caption)
                        if session.blocksFileChanges { Text("原片分享期间暂停文件整理").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("结束本次分享会话…") { model.endPhotoShare() }
                    }.padding(8).background(.bar)
                }
            }
            .onChange(of: session.phase) { _, phase in
                if phase == .sharing || phase == .finished { model.isShowingPhotoShare = false }
            }
            .onChange(of: session.message) { _, message in
                if !message.isEmpty { model.statusText = message }
            }
    }
}

private struct PhotoShareSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: PhotoShareSession
    @State private var mode = PhotoShareMode.original
    @State private var smallJPEG = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("分享照片").font(.title2)
            Text("当前明确选择 \(model.shareDraft.count) 张照片，不包含未选中的配对文件或 XMP。")
            Picker("分享内容", selection: $mode) {
                ForEach(PhotoShareMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).disabled(model.isWorking || session.isActive)
            if mode == .jpeg {
                Toggle("缩小到最长边 2,048 像素", isOn: $smallJPEG).disabled(model.isWorking || session.isActive)
                Text("默认原尺寸 · JPEG 品质 92% · sRGB · 应用已保存的调色").font(.caption)
            } else {
                Text("直接交付原文件，不复制、不转换。会话结束前暂停镜序的文件整理操作。").font(.caption)
            }
            Label("可能包含 GPS 位置信息；分享原片及成片均保留拍摄信息。", systemImage: "location")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.shareDraft) { Text($0.fileName).font(.caption) }
                    if let prepared = session.prepared {
                        Divider()
                        Text("可分享 \(prepared.files.count) 张").font(.headline)
                        ForEach(Array(prepared.issues.enumerated()), id: \.offset) { Text($0.element).font(.caption).foregroundStyle(.orange) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 200)
            if let prepared = session.prepared, !prepared.issues.isEmpty, !prepared.files.isEmpty {
                Toggle("仅分享成功项（\(prepared.files.count) 张）", isOn: $session.acceptsPartial)
            }
            HStack {
                if model.isWorking { ProgressView().controlSize(.small) }
                Text(model.sharePreparationProgress).font(.caption)
                Spacer()
            }
            HStack {
                Button(model.isWorking ? "取消准备" : "关闭") { model.cancelPhotoShare() }.keyboardShortcut(.cancelAction)
                Spacer()
                if session.isActive {
                    if session.phase == .ready {
                        Button("重新准备") { model.retryPhotoShare(mode: mode, maximumDimension: smallJPEG ? 2048 : nil) }
                    }
                    NativeShareButton(presenter: model.systemSharePresenter, session: session).frame(width: 110, height: 28)
                } else {
                    Button("准备分享") { model.preparePhotoShare(mode: mode, maximumDimension: smallJPEG ? 2048 : nil) }
                        .disabled(model.isWorking).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(22).frame(width: 590)
    }
}
