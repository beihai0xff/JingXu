import SwiftUI
import JingXuCore

struct ImportPlanView: View {
    @EnvironmentObject private var model: AppModel
    let plan: ImportPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("确认导入清单").font(.title2)
            Text("来源：\(plan.sourceRoot.pathHint)")
            Text("目标：\(plan.destination.path)")
            Text("\(plan.groups.count) 组 · \(plan.totalFiles) 个照片及配套文件 · 已有相同文件 \(plan.duplicateFiles) 个")
            Text("待复制 \(ByteCountFormatter.string(fromByteCount: plan.bytesToCopy, countStyle: .file))，原文件保持不变。")
            if !plan.issues.isEmpty {
                Text("存在无法处理的项目。不可读目录内的照片数量未知；确认后仅导入以下清单，结果会标为部分完成。").foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(plan.groups) { group in
                        Text(group.id).font(.headline)
                        ForEach(group.files.indices, id: \.self) { i in
                            let file = group.files[i]
                            Text("\(file.relativePath) → \(file.destinationName)\(file.isDuplicate ? "（相同，跳过）" : "")").font(.caption)
                        }
                    }
                    ImportIssuesView(issues: plan.issues)
                }.textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("取消") { model.importPlan = nil }.keyboardShortcut(.cancelAction)
                Button(plan.issues.isEmpty ? "确认导入" : "确认导入可处理部分") { model.confirmImport() }
                    .buttonStyle(.borderedProminent).disabled(plan.groups.isEmpty)
            }
        }.padding(24).frame(width: 760, height: 550)
    }
}
struct ImportResultView: View {
    @EnvironmentObject private var model: AppModel
    let report: ImportReport
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(report.outcome.rawValue).font(.title2)
            Text(report.destination.path).textSelection(.enabled)
            Text("清单 \(report.session.totalFiles) 个文件 · 已复制 \(report.session.completedFiles) · 相同跳过 \(report.session.skippedFiles) · 失败 \(report.session.failedFiles)")
            let pending = max(0, report.session.totalFiles - report.session.completedFiles - report.session.skippedFiles - report.session.failedFiles)
            if pending > 0 { Text("尚未处理 \(pending) 个文件") }
            if report.issues.contains(where: { $0.stage == .directory }) { Text("不可读目录中的文件数量未知，不计入清单总数。").foregroundStyle(.orange) }
            ScrollView { ImportIssuesView(issues: report.issues).textSelection(.enabled) }
            Text("重试会重新枚举和核对原来源，沿用此目标批次目录；再次确认清单后才开始复制。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("关闭") { model.isShowingImportReport = false }.keyboardShortcut(.cancelAction)
                Button("重新预检并重试") { model.retryImport() }.disabled(model.isWorking)
            }
        }.padding(24).frame(width: 720, height: 470)
    }
}
private struct ImportIssuesView: View {
    let issues: [ImportIssue]
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(issues.indices, id: \.self) { i in
                Text("\(issues[i].stage.rawValue) · \(issues[i].path)：\(issues[i].reason)").font(.caption).foregroundStyle(.orange)
            }
        }
    }
}
