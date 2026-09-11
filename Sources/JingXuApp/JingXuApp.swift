import SwiftUI

@main
struct JingXuApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(ColorApplicationDelegate.self) private var applicationDelegate

    var body: some Scene {
        WindowGroup("镜序") {
            Group {
                if model.isStarting {
                    ProgressView("正在检查图库…")
                } else if let failure = model.startupFailure {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("图库未打开").font(.title)
                        Text(failure).textSelection(.enabled)
                        Text("原数据库：\(model.catalogLocation)\n升级备份：\(model.upgradeBackupLocation)")
                            .font(.caption).textSelection(.enabled)
                        Text("未创建替代图库，也未启动扫描、分析或删除恢复。")
                        HStack {
                            Button("重试") { Task { await model.initializeCatalog() } }
                            Button("从升级备份恢复…") { model.restoreUpgradeBackup() }
                            Button("退出") { NSApplication.shared.terminate(nil) }
                        }
                    }.padding(32)
                } else { ContentView().environmentObject(model) }
            }.frame(minWidth: 1_080, minHeight: 680)
                .background(ColorWindowGuard(model: model))
                .onAppear { applicationDelegate.model = model }
        }
        .commands {
            CommandGroup(after: .importExport) {
                Button("添加照片文件夹…") { model.chooseAndAddFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("从相机卡导入…") { model.isShowingImport = true }.disabled(model.colorEditor != nil || !model.canStartColorAction)
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("照片调色") { model.beginColorEditing() }.disabled(model.previewAsset == nil || !model.canStartColorAction)
                Button("复制调色参数") { model.copyColorAdjustments() }.keyboardShortcut("c", modifiers: [.command, .option]).disabled(model.colorTargetIDs.isEmpty || !model.canStartColorAction)
                Button("预设与调色…") { model.showColorPresets() }.disabled(model.colorTargetIDs.isEmpty || !model.canStartColorAction)
                Button("导出成片…") { model.showColorExport() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.colorTargetIDs.isEmpty || !model.canStartColorAction)
                Button("撤销调色") { model.colorEditor?.undo() }.keyboardShortcut("z", modifiers: [.command, .option]).disabled(model.colorEditor?.history.canUndo != true || model.isPreviewTransitioning)
                Button("重做调色") { model.colorEditor?.redo() }.keyboardShortcut("z", modifiers: [.command, .option, .shift]).disabled(model.colorEditor?.history.canRedo != true || model.isPreviewTransitioning)
                Divider()
                Button("导出所选 XMP") { model.exportSelectedXMP() }
                    .disabled(model.selectedAssetID == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("淘汰并下一张（Delete）") { model.flagFromMenu(.rejected) }
                    .disabled(model.isDeleting || model.isSavingFlag)
                Button("取消淘汰标记（U）") { model.flagFromMenu(.none) }
                    .disabled(model.isDeleting || model.isSavingFlag)
                Divider()
                Button("重新分析当前范围…") { model.prepareQualityReanalysis() }.disabled(model.isWorking)
                Button("重新分析全部旧结果…") { model.prepareQualityReanalysis(legacyOnly: true) }.disabled(model.isWorking)
                Button("暂停质量重算") { model.pauseQualityReanalysis() }.disabled(!model.isReanalyzing)
                Button("继续质量重算") { model.resumeQualityReanalysis() }.disabled(model.isWorking || model.resumableQualityJob == nil)
                Divider()
                Button("整理重复来源…") { model.prepareSourceMerge() }.disabled(model.isWorking)
                Button("重新扫描整个来源…") { model.rescanSelectedSource() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 560, height: 480)
        }
    }
}
