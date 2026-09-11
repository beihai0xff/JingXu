import JingXuCore
import SwiftUI

struct ScanReportView: View {
    let report: ScanReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.isPartial ? "扫描部分完成" : "扫描完成").font(.headline)
            Text("发现媒体 \(report.discoveredFiles) 项；新增或更新 \(report.assetIDs.count) 项，未变化 \(report.unchangedFiles) 项。")
            Text("跳过不支持的文件 \(report.skippedFiles) 项；读取或解析文件失败 \(report.failedFiles) 项，目录读取失败 \(report.failedDirectories) 项。")
            if report.isPartial {
                Text("不可读目录内的文件数量未知；失败计数不代表遗漏照片总数。请根据下方原因检查权限或文件后重新扫描。元数据解析失败的文件可能已索引。上次完整扫描时间保持不变。")
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(report.failures.indices, id: \.self) { index in
                            let failure = report.failures[index]
                            Text("\(failure.path) · \(failure.stage.rawValue)\n\(failure.reason)").font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }.frame(maxHeight: 240)
                if report.failedFiles + report.failedDirectories > report.failures.count {
                    Text("仅显示前 \(report.failures.count) 条失败详情，以上计数包含全部失败。").font(.caption)
                }
            }
            Text("此结果仅对应最近一次扫描；后续质量分析及当前筛选数量另行显示。").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 460)
    }
}
