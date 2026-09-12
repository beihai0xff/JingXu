import JingXuCore
import SwiftUI

struct QualityInspector: View {
    @EnvironmentObject private var model: AppModel
    let item: AssetListItem

    var body: some View {
        if item.kind == .photo {
            GroupBox("质量诊断") {
                VStack(alignment: .leading, spacing: 9) {
                    Text(item.qualityStatus?.title ?? "尚未分析")
                        .font(.subheadline)
                        .foregroundStyle(item.hasPendingQualityWarning ? Color.orange : Color.primary)
                    if item.algorithmVersion == 1 {
                        Text("旧版结果不参与新版警告，也不代表质量正常。重算不会改变评分、旗标或标签。")
                    }
                    if let error = item.analysisError { Text(error).textSelection(.enabled) }
                    if let summary = item.diagnostic {
                        ForEach(summary.reasons, id: \.self) { Text($0) }
                        Text("预览：" + summary.scales.map { "\($0.width)×\($0.height)" }.joined(separator: " / "))
                        DisclosureGroup("查看局部指标") {
                            ForEach(Array(summary.scales.enumerated()), id: \.offset) { _, scale in
                                Text("\(scale.width)×\(scale.height)：有效区块 \(scale.validBlocks)/64；对比度 \(scale.contrast, specifier: "%.4f")；Sobel \(scale.sobelEnergy, specifier: "%.5f")；Laplacian \(scale.laplacianVariance, specifier: "%.5f")")
                            }
                            Text("指标未校准为准确率；不判断主体是否合焦。")
                        }
                        DisclosureGroup("算法信息") { Text("算法 v\(item.algorithmVersion ?? 2) · \(summary.parameterVersion)") }
                        if let reason = summary.featurePrintFailure { Text(reason) }
                    }
                    if item.hasPendingQualityWarning {
                        HStack {
                            Button("接受并标记淘汰") { model.resolveSuggestion(accepted: true, assetID: item.id) }
                            Button("忽略") { model.resolveSuggestion(accepted: false, assetID: item.id) }
                        }
                    } else if item.suggestionState == .accepted || item.suggestionState == .ignored {
                        Text(item.suggestionState == .accepted ? "人工审核：已接受（重算保留）" : "人工审核：已忽略（重算保留）")
                    }
                    Button(item.analysisError == nil ? "重新分析这张照片…" : "重试分析…") {
                        model.prepareQualityReanalysis(assetID: item.id)
                    }.disabled(model.isWorking)
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let exposure = item.diagnostic?.exposure {
                GroupBox("明暗统计 · 仅供参考") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("暗部（0–12）：\(exposure.shadows * 100, specifier: "%.1f")%")
                        Text("高亮（243–255）：\(exposure.highlights * 100, specifier: "%.1f")%")
                        Text("接近纯黑（0–2）：\(exposure.nearBlack * 100, specifier: "%.1f")%")
                        Text("接近纯白（253–255）：\(exposure.nearWhite * 100, specifier: "%.1f")%")
                        Text("基于解码预览，不代表 RAW 传感器曝光或细节可恢复性。")
                    }.font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if item.similarGroupID != nil || item.issues.contains(.similarBurst) {
                GroupBox("相似连拍") {
                    VStack(alignment: .leading, spacing: 8) {
                    Label("属于相似连拍，仅作整理参考，不计入质量问题。", systemImage: "square.stack.3d.up")
                        .font(.caption).foregroundStyle(.secondary)
                    if let id = item.similarGroupID {
                        Button("查看这一组") { model.compareSimilarGroup(id) }.disabled(model.operationBlockReason(.browse) != nil)
                    }
                    }
                }
            }
        }
    }
}

struct QualityReanalysisSheet: View {
    @EnvironmentObject private var model: AppModel
    let plan: QualityReanalysisPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(plan.title).font(.title2)
            Text("共 \(plan.assetIDs.count) 张照片，包含范围内未在网格显示的照片，跳过视频。")
            Text("开始前创建图库在线备份。逐项重算并保存进度，可暂停、取消和重启后继续；不会修改原照片、评分、旗标、标签或相册关系。")
            Text("真实照片人工校准与独立验证尚未通过，新模糊报警默认关闭；本次只展示指标和待校准状态。")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { model.qualityReanalysisPlan = nil }.keyboardShortcut(.cancelAction)
                Button("备份并开始重算") { model.confirmQualityReanalysis(plan) }.disabled(plan.assetIDs.isEmpty)
            }
        }.padding(24).frame(width: 560)
    }
}
