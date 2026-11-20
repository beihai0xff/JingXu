import JingXuCore
import SwiftUI

struct ManifestMetric: Identifiable {
    enum Tone {
        case neutral
        case accent
        case warning
        case destructive
    }

    let id = UUID()
    let label: String
    let value: String
    var tone: Tone = .neutral
}

/// Unified 3-section preflight & result sheet for all file, catalog, and PhotoKit mutations.
struct ManifestConfirmationSheet<Controls: View, ManifestBody: View, LeadingFooter: View>: View {
    let scopeBadge: String
    let title: String
    let safetyNote: String
    var metrics: [ManifestMetric] = []
    var width: CGFloat = 640
    var manifestMaxHeight: CGFloat? = 230
    var cancelTitle: String? = "取消"
    var onCancel: (() -> Void)? = nil
    var confirmTitle: String
    var isDestructive: Bool = false
    var confirmDisabled: Bool = false
    let onConfirm: () -> Void
    @ViewBuilder var controls: () -> Controls
    @ViewBuilder var manifestBody: () -> ManifestBody
    @ViewBuilder var leadingFooter: () -> LeadingFooter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Section 1: Scope & Safety Guarantee Header
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: isDestructive ? "exclamationmark.shield.fill" : "checkmark.shield.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(isDestructive ? DarkroomPalette.rejectCoral : Color.accentColor)
                    Text(scopeBadge)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isDestructive ? DarkroomPalette.rejectCoral : Color.accentColor)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(
                    (isDestructive ? DarkroomPalette.rejectCoral : Color.accentColor).opacity(0.14),
                    in: Capsule()
                )

                Text(title)
                    .font(.title3.weight(.bold))

                Text(safetyNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            // Section 2: Controls, Metrics & Fixed Manifest
            controls()

            if !metrics.isEmpty {
                HStack(spacing: 10) {
                    ForEach(metrics) { metric in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(metric.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(metric.value)
                                .font(.callout.weight(.semibold).monospacedDigit())
                                .foregroundStyle(metricColor(metric.tone))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DarkroomPalette.elevatedControl.opacity(0.75), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1)
                        )
                    }
                }
            }

            if !(ManifestBody.self == EmptyView.self) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        manifestBody()
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .textSelection(.enabled)
                }
                .frame(minHeight: 110, maxHeight: manifestMaxHeight)
                .background(DarkroomPalette.canvasDeep.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1)
                )
            }

            Divider().overlay(DarkroomPalette.subtleDivider)

            // Section 3: Sticky Action Footer
            HStack(spacing: 10) {
                leadingFooter()
                Spacer(minLength: 8)
                if let cancelTitle, let onCancel {
                    Button(cancelTitle, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                }
                if isDestructive {
                    Button(confirmTitle, role: .destructive, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .tint(DarkroomPalette.rejectCoral)
                        .disabled(confirmDisabled)
                } else {
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(confirmDisabled)
                }
            }
        }
        .padding(22)
        .frame(width: width)
    }

    private func metricColor(_ tone: ManifestMetric.Tone) -> Color {
        switch tone {
        case .neutral: .primary
        case .accent: Color.accentColor
        case .warning: DarkroomPalette.warningAmber
        case .destructive: DarkroomPalette.rejectCoral
        }
    }
}

extension ManifestConfirmationSheet where Controls == EmptyView, LeadingFooter == EmptyView {
    init(
        scopeBadge: String,
        title: String,
        safetyNote: String,
        metrics: [ManifestMetric] = [],
        width: CGFloat = 640,
        manifestMaxHeight: CGFloat? = 230,
        cancelTitle: String? = "取消",
        onCancel: (() -> Void)? = nil,
        confirmTitle: String,
        isDestructive: Bool = false,
        confirmDisabled: Bool = false,
        onConfirm: @escaping () -> Void,
        @ViewBuilder manifestBody: @escaping () -> ManifestBody
    ) {
        self.scopeBadge = scopeBadge
        self.title = title
        self.safetyNote = safetyNote
        self.metrics = metrics
        self.width = width
        self.manifestMaxHeight = manifestMaxHeight
        self.cancelTitle = cancelTitle
        self.onCancel = onCancel
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.confirmDisabled = confirmDisabled
        self.onConfirm = onConfirm
        self.controls = { EmptyView() }
        self.manifestBody = manifestBody
        self.leadingFooter = { EmptyView() }
    }
}

// MARK: - Local Catalog Manifest Sheets

struct XMPExportPlanSheet: View {
    @EnvironmentObject private var model: AppModel
    let plan: XMPExportPlan

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "范围：已确认的所选照片固定清单",
            title: "导出新 XMP 侧车文件",
            safetyNote: "仅在原照片同目录原子创建新的 .xmp 文件；原照片与已有 XMP 文件始终保留，绝不覆盖。",
            metrics: [
                ManifestMetric(label: "可创建 XMP", value: "\(plan.items.count) 项", tone: .accent),
                ManifestMetric(label: "已存在跳过", value: "\(plan.skipped.count) 项", tone: plan.skipped.isEmpty ? .neutral : .warning),
                ManifestMetric(label: "校验失败", value: "\(plan.failed.count) 项", tone: plan.failed.isEmpty ? .neutral : .destructive)
            ],
            width: 660,
            onCancel: { model.xmpPlan = nil },
            confirmTitle: "确认创建 \(plan.items.count) 项",
            confirmDisabled: plan.items.isEmpty,
            onConfirm: { model.confirmXMP() }
        ) {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(plan.items) { item in
                    Text(item.destination.path)
                }
                ForEach(Array((plan.skipped + plan.failed).enumerated()), id: \.offset) { _, reason in
                    Text("跳过／警告：\(reason)")
                        .foregroundStyle(DarkroomPalette.warningAmber)
                }
            }
        }
    }
}

struct ArchivePlanSheet: View {
    @EnvironmentObject private var model: AppModel
    let plan: ArchivePlan

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: plan.isBatchMove == true ? "范围：已确认的所选照片及明确配套文件" : "范围：整个本地图库（不受当前筛选影响）",
            title: plan.isBatchMove == true ? "批量移动所选照片" : "按拍摄日期重新归档",
            safetyNote: "同一磁盘直接移动，不复制、不覆盖同名文件；视频保留原位。执行前自动创建图库备份，照片 ID、评分、标签、调色与相册关系完整保留。",
            metrics: [
                ManifestMetric(label: "待移动文件", value: "\(plan.count) 个", tone: .accent),
                ManifestMetric(label: "文件总大小", value: ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)),
                ManifestMetric(label: "跳过／提示", value: "\(plan.warnings.count) 条", tone: plan.warnings.isEmpty ? .neutral : .warning)
            ],
            width: 740,
            manifestMaxHeight: 270,
            onCancel: { model.archivePlan = nil },
            confirmTitle: "授权并执行移动",
            confirmDisabled: plan.count == 0,
            onConfirm: { model.confirmArchive() }
        ) {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(plan.groups.indices, id: \.self) { i in
                    Text("来源：\(plan.groups[i].source.pathHint)")
                        .font(.caption.weight(.semibold))
                    if let destination = plan.groups[i].destination {
                        Text("目标来源：\(destination.pathHint)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    ForEach(plan.groups[i].files.indices, id: \.self) { j in
                        Text("\(plan.groups[i].files[j].from) → \(plan.groups[i].files[j].to)")
                    }
                }
                ForEach(plan.warnings.indices, id: \.self) { idx in
                    Text("提示：\(plan.warnings[idx])")
                        .foregroundStyle(DarkroomPalette.warningAmber)
                }
            }
        }
    }
}

struct SourceMergePlanSheet: View {
    @EnvironmentObject private var model: AppModel
    let plan: SourceMergePlan

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "范围：本地图库重复注册来源",
            title: "整理重复来源",
            safetyNote: "保留最早注册来源，合并标签与相册成员关系；评分与旗标采用最近修改记录。执行前自动备份图库，绝不改动磁盘原文件。",
            metrics: [
                ManifestMetric(label: "可合并来源组", value: "\(plan.groups.count) 组", tone: .accent),
                ManifestMetric(label: "标注冲突（取最新）", value: "\(plan.conflicts) 项", tone: plan.conflicts == 0 ? .neutral : .warning),
                ManifestMetric(label: "跳过提示", value: "\(plan.warnings.count) 条", tone: plan.warnings.isEmpty ? .neutral : .warning)
            ],
            width: 640,
            onCancel: { model.sourceMergePlan = nil },
            confirmTitle: "备份并合并来源",
            confirmDisabled: plan.groups.isEmpty,
            onConfirm: { model.confirmSourceMerge(plan) }
        ) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(plan.groups.indices, id: \.self) { index in
                    Text("保留：\(plan.groups[index][0].name) · \(plan.groups[index][0].pathHint)")
                        .font(.caption.weight(.semibold))
                    ForEach(Array(plan.groups[index].dropFirst())) { source in
                        Text("  ↳ 并入：\(source.name) · \(source.pathHint)")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(plan.warnings, id: \.self) { warning in
                    Text("跳过：\(warning)")
                        .foregroundStyle(DarkroomPalette.warningAmber)
                }
            }
        }
    }
}

struct DeletionPlanSheet: View {
    @EnvironmentObject private var model: AppModel
    let plan: DeletionPlan

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "范围：当前完整筛选范围内的已淘汰照片",
            title: "将淘汰照片移到系统废纸篓",
            safetyNote: "仅通过 macOS 系统废纸篓移除文件（失败绝不退化为永久删除），不会删除视频、RAW/JPEG 配对文件或 XMP。文件可在访达废纸篓中恢复；图库中的评分、标签、调色与相册关系不会自动恢复。",
            metrics: [
                ManifestMetric(label: "移入废纸篓", value: "\(plan.files.count) 张", tone: .destructive),
                ManifestMetric(label: "释放空间", value: ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))
            ],
            width: 640,
            onCancel: { model.deletionPlan = nil },
            confirmTitle: "移到废纸篓",
            isDestructive: true,
            confirmDisabled: plan.files.isEmpty,
            onConfirm: { model.confirmDeletion(plan) }
        ) {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(plan.files) { file in
                    Text((plan.sourcePaths[file.sourceID].map { $0 + "/" } ?? "") + file.relativePath)
                }
            }
        }
    }
}

struct MissingAssetCleanupSheet: View {
    @EnvironmentObject private var model: AppModel
    let plan: MissingAssetPlan

    var body: some View {
        ManifestConfirmationSheet(
            scopeBadge: "范围：当前来源、目录、相册与筛选完整范围（含视频）",
            title: "清理已缺失文件的失效索引",
            safetyNote: "仅清理确认缺失文件的数据库记录及对应评分、标签、调色与相册关系，不操作任何磁盘文件。执行前创建图库备份并二次复核；离线卷或权限异常项目一律跳过保留。",
            metrics: [
                ManifestMetric(label: "确认缺失记录", value: "\(plan.files.count) 项", tone: .destructive),
                ManifestMetric(label: "身份未确认跳过", value: "\(plan.warnings.count) 项", tone: plan.warnings.isEmpty ? .neutral : .warning)
            ],
            width: 650,
            onCancel: { model.missingAssetPlan = nil },
            confirmTitle: "备份并移除失效索引",
            isDestructive: true,
            confirmDisabled: plan.files.isEmpty || model.isWorking,
            onConfirm: { model.confirmMissingAssetCleanup(plan) }
        ) {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(plan.files) { file in
                    Text((plan.sources[file.sourceID]?.pathHint ?? "") + "/" + file.relativePath)
                }
                ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                    Text("保留跳过：\(warning)")
                        .foregroundStyle(DarkroomPalette.warningAmber)
                }
            }
        }
    }
}
