import JingXuCore
import SwiftUI

struct QualityInspector: View {
    @EnvironmentObject private var model: AppModel
    let item: AssetListItem

    var body: some View {
        if item.kind == .photo {
            VStack(spacing: 10) {
                darkroomCard(title: "原片质量诊断") {
                    Text(item.qualityStatus?.title ?? "尚未分析")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(item.hasPendingQualityWarning ? DarkroomPalette.warningAmber : DarkroomPalette.textPrimary)

                    if item.algorithmVersion == 1 {
                        Text("旧版结果不参与新版警告，也不代表质量正常。重算不会改变评分、旗标或标签。")
                    }
                    if let error = item.analysisError {
                        Text(error).foregroundStyle(DarkroomPalette.warningAmber).textSelection(.enabled)
                    }
                    if let summary = item.diagnostic {
                        ForEach(summary.reasons, id: \.self) { Text($0) }
                        Text("预览尺度：" + summary.scales.map { "\($0.width)×\($0.height)" }.joined(separator: " / "))
                            .monospacedDigit()
                        DisclosureGroup("查看局部指标") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(summary.scales.enumerated()), id: \.offset) { _, scale in
                                    Text("\(scale.width)×\(scale.height)：有效区块 \(scale.validBlocks)/64；对比度 \(scale.contrast, specifier: "%.4f")；Sobel \(scale.sobelEnergy, specifier: "%.5f")；Laplacian \(scale.laplacianVariance, specifier: "%.5f")")
                                        .monospacedDigit()
                                }
                                Text("指标未校准为准确率；不判断主体是否合焦。")
                                    .foregroundStyle(DarkroomPalette.textMuted)
                            }
                            .padding(.top, 4)
                        }
                        DisclosureGroup("算法信息") {
                            Text("算法 v\(item.algorithmVersion ?? 2) · \(summary.parameterVersion)")
                                .monospacedDigit()
                                .padding(.top, 4)
                        }
                        if let reason = summary.featurePrintFailure {
                            Text(reason).foregroundStyle(DarkroomPalette.warningAmber)
                        }
                    }
                    if item.hasPendingQualityWarning {
                        HStack(spacing: 8) {
                            Button("接受并标记淘汰") { model.resolveSuggestion(accepted: true, assetID: item.id) }
                                .buttonStyle(.borderedProminent)
                            Button("忽略") { model.resolveSuggestion(accepted: false, assetID: item.id) }
                        }
                        .controlSize(.small)
                    } else if item.suggestionState == .accepted || item.suggestionState == .ignored {
                        Text(item.suggestionState == .accepted ? "人工审核：已接受（重算保留）" : "人工审核：已忽略（重算保留）")
                    }
                    Button(item.analysisError == nil ? "重新分析这张照片…" : "重试分析…") {
                        model.prepareQualityReanalysis(assetID: item.id)
                    }
                    .controlSize(.small)
                    .disabled(model.isWorking)
                }

                if let exposure = item.diagnostic?.exposure {
                    darkroomCard(title: "明暗统计 · 仅供参考") {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                            GridRow {
                                Text("暗部（0–12）")
                                Text("\(exposure.shadows * 100, specifier: "%.1f")%").monospacedDigit()
                            }
                            GridRow {
                                Text("高亮（243–255）")
                                Text("\(exposure.highlights * 100, specifier: "%.1f")%").monospacedDigit()
                            }
                            GridRow {
                                Text("接近纯黑（0–2）")
                                Text("\(exposure.nearBlack * 100, specifier: "%.1f")%").monospacedDigit()
                            }
                            GridRow {
                                Text("接近纯白（253–255）")
                                Text("\(exposure.nearWhite * 100, specifier: "%.1f")%").monospacedDigit()
                            }
                        }
                        Text("基于解码预览统计，不代表 RAW 传感器曝光或细节可恢复性。")
                            .foregroundStyle(DarkroomPalette.textMuted)
                    }
                }

                if item.similarGroupID != nil || item.issues.contains(.similarBurst) {
                    darkroomCard(title: "相似连拍") {
                        Label("属于相似连拍组，仅作整理参考，不计入质量问题。", systemImage: "square.stack.3d.up")
                        if let id = item.similarGroupID {
                            Button("查看并对比这一组") { model.compareSimilarGroup(id) }
                                .controlSize(.small)
                                .disabled(model.operationBlockReason(.browse) != nil)
                        }
                    }
                }
            }
        }
    }

    private func darkroomCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DarkroomPalette.textPrimary)
            content()
                .font(.caption2)
                .foregroundStyle(DarkroomPalette.textSecondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DarkroomPalette.canvasDeep.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1))
    }
}

struct QualityReanalysisSheet: View {
    @EnvironmentObject private var model: AppModel
    let plan: QualityReanalysisPlan

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "范围：\(plan.title)（跳过视频）",
            title: plan.title,
            safetyNote: "开始前自动创建图库在线备份。逐项重算并持久化进度，支持暂停、取消与重启后继续；绝不修改原照片、人工审核状态、评分、旗标、关键词或相册关系。新模糊报警在完成独立校准前默认保持关闭。",
            metrics: [
                ManifestMetric(label: "固定重算照片数", value: "\(plan.assetIDs.count) 张", tone: .accent)
            ],
            width: 580,
            onCancel: { model.qualityReanalysisPlan = nil },
            confirmTitle: "备份并开始重算",
            confirmDisabled: plan.assetIDs.isEmpty,
            onConfirm: { model.confirmQualityReanalysis(plan) },
            controls: { EmptyView() },
            manifestBody: { EmptyView() },
            leadingFooter: { EmptyView() }
        )
    }
}
