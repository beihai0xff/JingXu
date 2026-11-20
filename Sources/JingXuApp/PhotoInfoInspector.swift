import AppKit
import JingXuCore
import SwiftUI

struct PhotoInfoInspector: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab = PhotoInspectorTab.information

    var body: some View {
        Group {
            if model.showsSystemPhotos, let photos = model.systemPhotos {
                systemInspector(photos)
            } else {
                localInspector
            }
        }
        .frame(width: 296)
        .darkroomPanelSurface()
    }

    @ViewBuilder
    private var localInspector: some View {
        if model.previewAsset == nil && model.photoSelection.selectedIDs.count > 1 {
            VStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(DarkroomPalette.textSecondary)
                Text("已选择 \(model.photoSelection.selectedIDs.count) 张照片")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(DarkroomPalette.textPrimary)
                Text("请使用网格底部的悬浮胶囊操作坞进行批量评分、标记淘汰、双图对比、归入相册或导出。")
                    .font(.caption)
                    .foregroundStyle(DarkroomPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let item = model.previewAsset ?? model.selectedAsset {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(item.fileName)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(DarkroomPalette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.fileName, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("复制文件名")
                    }

                    Picker("详情分区", selection: $tab) {
                        ForEach(PhotoInspectorTab.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

                Divider().overlay(DarkroomPalette.subtleDivider)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if tab == .information {
                            localAnnotationCard(item)
                            localMetadataCard(item)
                            localKeywordCard
                            localActionsBar(item)
                        } else {
                            HistogramView(item: item).id(item.id)
                            QualityInspector(item: item)
                        }
                    }
                    .padding(14)
                }
            }
            .disabled(model.isDeleting)
            .onChange(of: model.selectedAssetID) { _, _ in model.syncKeywordDraft() }
            .onChange(of: model.previewAsset?.id) { _, _ in model.syncKeywordDraft() }
            .onAppear { model.syncKeywordDraft() }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 26))
                    .foregroundStyle(DarkroomPalette.textMuted)
                Text("未选择照片")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(DarkroomPalette.textSecondary)
                Text("单击网格中的照片以查看拍摄参数、编辑关键词与质量诊断。")
                    .font(.caption)
                    .foregroundStyle(DarkroomPalette.textMuted)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func localAnnotationCard(_ item: AssetListItem) -> some View {
        inspectorCard(title: "评级与筛选") {
            HStack {
                HStack(spacing: 5) {
                    ForEach(1...5, id: \.self) { value in
                        Button {
                            model.updateRating(item.rating == value ? 0 : value)
                        } label: {
                            Image(systemName: value <= item.rating ? "star.fill" : "star")
                                .foregroundStyle(value <= item.rating ? Color.yellow : DarkroomPalette.textMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                Picker("旗标", selection: Binding(
                    get: { item.flag },
                    set: { model.updateFlag($0) }
                )) {
                    ForEach(AssetFlag.allCases, id: \.self) { flag in
                        Text(flag.displayName).tag(flag)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 112)
                .disabled(model.isSavingAnnotation)
            }
            Text("快捷键：0–5 评分 · X / Delete 淘汰 · U 取消淘汰")
                .font(.system(size: 10.5))
                .foregroundStyle(DarkroomPalette.textMuted)
        }
    }

    private func localMetadataCard(_ item: AssetListItem) -> some View {
        inspectorCard(title: "拍摄参数") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                metaRow("拍摄时间", item.capturedAt?.formatted(date: .abbreviated, time: .shortened) ?? "未知")
                metaRow("机身", item.cameraModel ?? "未知")
                metaRow("镜头", item.lens ?? "未知")
                if let width = item.width, let height = item.height {
                    metaRow("像素尺寸", "\(width) × \(height)", monospaced: true)
                }
                metaRow("格式类型", MediaSupport.isRaw(URL(fileURLWithPath: item.fileName)) ? "RAW 照片" : (item.kind == .photo ? "照片" : "视频"))
                metaRow("相对路径", item.relativePath)
            }
        }
    }

    private var localKeywordCard: some View {
        inspectorCard(title: "关键词") {
            HStack(spacing: 6) {
                TextField("旅行, 人像, 夜景", text: $model.keywordDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { Task { _ = await model.flushKeywords() } }
                Button("保存") {
                    Task { _ = await model.flushKeywords() }
                }
                .controlSize(.small)
                .disabled(model.keywordDraft == model.keywordSaved)
            }
            .disabled(model.operationBlockReason(.annotation) != nil)
        }
    }

    private func localActionsBar(_ item: AssetListItem) -> some View {
        HStack(spacing: 8) {
            Button("在访达中显示", systemImage: "folder") {
                model.revealSelectedInFinder(assetID: item.id)
            }
            Spacer()
            if item.kind == .photo {
                Button("导出新 XMP…") {
                    model.exportSelectedXMP()
                }
                .disabled(model.operationBlockReason(.files) != nil)
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func systemInspector(_ photos: SystemPhotosModel) -> some View {
        if photos.preview == nil && photos.selection.selectedIDs.count > 1 {
            VStack(spacing: 12) {
                Image(systemName: "icloud")
                    .font(.system(size: 28))
                    .foregroundStyle(DarkroomPalette.textSecondary)
                Text("已选择 \(photos.selection.selectedIDs.count) 张系统照片")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(DarkroomPalette.textPrimary)
                Text("请使用网格底部悬浮操作坞批量加入相册、执行本机质量分析或删除。")
                    .font(.caption)
                    .foregroundStyle(DarkroomPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let photo = photos.preview ?? photos.primaryTargetPhotoForPreview {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(photo.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(DarkroomPalette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Picker("详情分区", selection: $tab) {
                        ForEach(PhotoInspectorTab.allCases, id: \.self) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

                Divider().overlay(DarkroomPalette.subtleDivider)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if tab == .information {
                            inspectorCard(title: "系统照片信息") {
                                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                                    metaRow("像素尺寸", "\(photo.width) × \(photo.height)", monospaced: true)
                                    if let date = photo.capturedAt {
                                        metaRow("拍摄时间", date.formatted(date: .abbreviated, time: .shortened))
                                    }
                                    metaRow("媒体属性", photo.isLivePhoto ? "Live Photo" : "静态照片")
                                }
                                if photo.isLivePhoto {
                                    Text("Live Photo 仅显示静态画面，保留系统动态内容，不支持调色回写。")
                                        .font(.caption2)
                                        .foregroundStyle(DarkroomPalette.warningAmber)
                                }
                            }
                            if photos.preview != nil {
                                Button("放弃本机草稿并重载…") {
                                    photos.discardDraft()
                                }
                                .controlSize(.small)
                                .disabled(!photos.canAct)
                            }
                        } else {
                            inspectorCard(title: "本机原片质量诊断") {
                                Button("分析当前照片") {
                                    photos.prepareAnalysis()
                                }
                                .controlSize(.small)
                                .disabled(!photos.canAct)

                                if let failure = photos.job?.failures[photo.id] {
                                    Text("本次分析未完成：\(failure)")
                                        .font(.caption)
                                        .foregroundStyle(DarkroomPalette.warningAmber)
                                }

                                if let result = photos.analysis, photos.preview?.id == photo.id {
                                    Text(result.status.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(DarkroomPalette.textPrimary)
                                    if let diagnostic = result.diagnostic {
                                        ForEach(diagnostic.reasons, id: \.self) { reason in
                                            Text(reason).font(.caption2).foregroundStyle(DarkroomPalette.textSecondary)
                                        }
                                        if let failure = diagnostic.featurePrintFailure {
                                            Text(failure).font(.caption2).foregroundStyle(DarkroomPalette.warningAmber)
                                        }
                                    }
                                    Text("高光溢出 \(result.highlightClipping, format: .percent.precision(.fractionLength(1))) · 暗部压黑 \(result.shadowClipping, format: .percent.precision(.fractionLength(1)))")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(DarkroomPalette.textSecondary)
                                    Text("相似连拍：\(result.similarGroupID == nil ? "本批未分组" : "已分组")")
                                        .font(.caption2)
                                        .foregroundStyle(DarkroomPalette.textSecondary)
                                    Text("人工审核：\(result.suggestionState == .accepted ? "已确认" : result.suggestionState == .ignored ? "已忽略" : "待审核")")
                                        .font(.caption2)
                                        .foregroundStyle(DarkroomPalette.textSecondary)
                                    HStack(spacing: 8) {
                                        Button("确认问题") { photos.review(.accepted) }
                                        Button("忽略") { photos.review(.ignored) }
                                    }
                                    .controlSize(.small)
                                    .disabled(!photos.canAct)
                                    Text("基于解码预览统计，不代表 RAW 传感器数据。")
                                        .font(.caption2)
                                        .foregroundStyle(DarkroomPalette.textMuted)
                                } else {
                                    Text(photos.preview == nil ? "打开单图后查看或触发单张原片质量诊断。" : "尚未完成本机质量分析。")
                                        .font(.caption)
                                        .foregroundStyle(DarkroomPalette.textMuted)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 26))
                    .foregroundStyle(DarkroomPalette.textMuted)
                Text("未选择系统照片")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(DarkroomPalette.textSecondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func inspectorCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DarkroomPalette.textPrimary)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DarkroomPalette.canvasDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1)
        )
    }

    private func metaRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(.caption2)
                .foregroundStyle(DarkroomPalette.textMuted)
            Text(value)
                .font(monospaced ? .caption2.monospacedDigit() : .caption2)
                .foregroundStyle(DarkroomPalette.textSecondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}
