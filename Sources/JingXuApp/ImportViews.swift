import JingXuCore
import SwiftUI

struct ImportPlanView: View {
    @EnvironmentObject private var model: AppModel
    let plan: ImportPlan

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "来源：\(plan.sourceRoot.pathHint)",
            title: "确认安全导入固定清单",
            safetyNote: "目标目录：\(plan.destination.path)\n源文件绝不会被移动、重命名或删除；同名或相同内容文件自动跳过不覆盖。" +
                (plan.issues.isEmpty ? "" : " 存在不可读项目，确认后仅导入以下可处理清单并标记为部分完成。"),
            metrics: [
                ManifestMetric(label: "可导入文件（\(plan.groups.count) 组）", value: "\(plan.totalFiles) 个", tone: .accent),
                ManifestMetric(label: "待复制体积", value: ByteCountFormatter.string(fromByteCount: plan.bytesToCopy, countStyle: .file)),
                ManifestMetric(label: "相同跳过／异常", value: "\(plan.duplicateFiles) / \(plan.issues.count)", tone: plan.issues.isEmpty ? .neutral : .warning)
            ],
            width: 760,
            manifestMaxHeight: 280,
            onCancel: { model.importPlan = nil },
            confirmTitle: plan.issues.isEmpty ? "确认导入" : "确认导入可处理部分",
            confirmDisabled: plan.groups.isEmpty,
            onConfirm: { model.confirmImport() }
        ) {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(plan.groups) { group in
                    Text(group.id).font(.caption.weight(.semibold))
                    ForEach(group.files.indices, id: \.self) { i in
                        let file = group.files[i]
                        Text("  \(file.relativePath) → \(file.destinationName)\(file.isDuplicate ? "（相同，跳过）" : "")")
                            .foregroundStyle(file.isDuplicate ? .secondary : .primary)
                    }
                }
                ImportIssuesView(issues: plan.issues)
            }
        }
    }
}

struct ImportResultView: View {
    @EnvironmentObject private var model: AppModel
    let report: ImportReport

    var body: some View {
        let pending = max(0, report.session.totalFiles - report.session.completedFiles - report.session.skippedFiles - report.session.failedFiles)
        ManifestConfirmationSheet(
            scopeBadge: "导入批次结果 · \(report.destination.lastPathComponent)",
            title: report.outcome.rawValue,
            safetyNote: "目标目录：\(report.destination.path)\n重试会重新枚举并核对原来源，沿用此目标批次目录；再次确认固定清单后才开始复制。" +
                (pending > 0 ? "（尚未处理 \(pending) 个文件）" : ""),
            metrics: [
                ManifestMetric(label: "成功复制", value: "\(report.session.completedFiles) 个", tone: .accent),
                ManifestMetric(label: "相同跳过", value: "\(report.session.skippedFiles) 个"),
                ManifestMetric(label: "失败项目", value: "\(report.session.failedFiles) 个", tone: report.session.failedFiles == 0 ? .neutral : .warning)
            ],
            width: 720,
            cancelTitle: "关闭",
            onCancel: { model.isShowingImportReport = false },
            confirmTitle: "重新预检并重试",
            confirmDisabled: model.isWorking,
            onConfirm: { model.retryImport() }
        ) {
            if report.issues.isEmpty {
                Text("本次导入无异常记录，全部文件已校验完成。")
                    .foregroundStyle(.secondary)
            } else {
                if report.issues.contains(where: { $0.stage == .directory }) {
                    Text("注意：不可读目录中的文件数量未知，不计入清单总数。")
                        .foregroundStyle(DarkroomPalette.warningAmber)
                }
                ImportIssuesView(issues: report.issues)
            }
        }
    }
}

private struct ImportIssuesView: View {
    let issues: [ImportIssue]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(issues.indices, id: \.self) { i in
                Text("\(issues[i].stage.rawValue) · \(issues[i].path)：\(issues[i].reason)")
                    .foregroundStyle(DarkroomPalette.warningAmber)
            }
        }
    }
}
