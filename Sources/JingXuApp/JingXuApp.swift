import SwiftUI

@main
struct JingXuApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("镜序") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .commands {
            CommandGroup(after: .importExport) {
                Button("添加照片文件夹…") { model.chooseAndAddFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("从相机卡导入…") { model.isShowingImport = true }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("导出所选 XMP") { model.exportSelectedXMP() }
                    .disabled(model.selectedAssetID == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("重新扫描当前来源") { model.rescanSelectedSource() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 520, height: 280)
        }
    }
}
