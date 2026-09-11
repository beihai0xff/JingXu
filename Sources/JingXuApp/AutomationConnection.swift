import AppKit
import Combine
import Foundation
import JingXuAutomation
import JingXuCore

@MainActor final class AutomationConnection: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var changing = false
    @Published var port: Int
    @Published private(set) var status = "连接已关闭"
    private var token: String?
    private var server: MCPHTTPServer?
    private var controller: ColorAutomationController?
    private let makeController: () throws -> ColorAutomationController
    private let defaults: UserDefaults
    private let credentialService: String
    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    init(defaults: UserDefaults = .standard, credentialService: String = "app.jingxu.desktop.mcp", makeController: @escaping () throws -> ColorAutomationController) {
        self.defaults = defaults; self.credentialService = credentialService; self.makeController = makeController
        let saved = defaults.integer(forKey: "AIConnectionPort")
        port = (1024...65535).contains(saved) ? saved : 52831
        if defaults.bool(forKey: "AIConnectionEnabled") { setEnabled(true) }
    }
    func setEnabled(_ value: Bool, resetKey: Bool = false) {
        guard !changing else { return }
        changing = true
        Task {
            defer { changing = false }
            await shutdown()
            guard value else { return }
            do {
                guard (1024...65535).contains(port) else { throw ColorEditError("端口需为 1024–65535") }
                let token = try resetKey ? AutomationCredential.reset(service: credentialService) : AutomationCredential.loadOrCreate(service: credentialService)
                let controller = try makeController()
                let server = MCPHTTPServer(port: port, token: token, handler: { name, args, client in
                    try await controller.call(name, arguments: args, client: client)
                }, disconnected: { client in await controller.disconnect(client: client) })
                do { try await server.start() }
                catch { await controller.shutdown(); await server.stop(); throw error }
                self.token = token; self.server = server; self.controller = controller
                enabled = true; status = "已启用，等待 Codex 连接"
                defaults.set(true, forKey: "AIConnectionEnabled"); defaults.set(port, forKey: "AIConnectionPort")
            } catch { status = "启动失败：\(error.localizedDescription)。请检查端口占用或连接密钥权限。" }
        }
    }
    func shutdown(preservePreference: Bool = false) async {
        enabled = false
        if !preservePreference { defaults.set(false, forKey: "AIConnectionEnabled") }
        let server = server, controller = controller
        self.server = nil; self.controller = nil; token = nil
        await server?.stop(); await controller?.shutdown()
        status = "连接已关闭"
    }
    func copyConfiguration() {
        guard enabled, let token else { return }
        let config = """
        [mcp_servers.jingxu]
        url = "\(endpoint)"
        http_headers = { Authorization = "Bearer \(token)" }
        tool_timeout_sec = 120
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config, forType: .string)
        status = "连接配置已复制，包含密钥，请仅粘贴到本机 Codex 配置"
    }
    func cancelCurrentJob() { controller?.cancelCurrentJob() }
}

extension AppModel: ColorAutomationHost {
    var automationSelection: AutomationSelection {
        let photos = colorTargetIDs.compactMap { id -> AutomationPhoto? in
            guard let item = previewAsset?.id == id ? previewAsset : assets.first(where: { $0.id == id }) else { return nil }
            return AutomationPhoto(id: id, name: item.fileName)
        }
        let current = previewAsset?.id ?? (photos.contains(where: { $0.id == selectedAssetID }) ? selectedAssetID : photos.first?.id)
        return AutomationSelection(token: automationSelectionToken.uuidString, currentID: current, photos: photos)
    }
    var automationEditor: ColorEditSession? { colorEditor }
    var automationBusy: Bool {
        isStarting || startupFailure != nil || !canStartColorAction || isShowingColorPresets || isSavingFlag ||
        NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil
    }
    func automationBeginOperation() async throws {
        guard !automationBusy, !automationOwnsOperation, store != nil else { throw ColorEditError("镜序当前无法开始 AI 操作") }
        automationOwnsOperation = true; isWorking = true
        do { try await checkDeletionRecovery() }
        catch { automationEndOperation(); throw error }
    }
    func automationEndOperation() {
        guard automationOwnsOperation else { return }
        automationOwnsOperation = false; isWorking = false
    }
    func automationOpenEditor(assetID: String) async throws -> ColorEditSession {
        guard automationOwnsOperation, let store else { throw ColorEditError("没有取得调色操作权限") }
        if let editor = colorEditor {
            guard editor.snapshot.asset.id == assetID else { throw ColorEditError("当前编辑照片已变化") }
            return editor
        }
        guard let item = assets.first(where: { $0.id == assetID }) ?? (previewAsset?.id == assetID ? previewAsset : nil) else { throw ColorEditError("照片已不在当前范围") }
        let selection = automationSelectionToken
        let snapshot = try await store.colorSnapshot(assetID: assetID)
        guard automationSelectionToken == selection else { throw ColorEditError("打开编辑会话时选择已变化") }
        let editor = try makeColorSession(snapshot)
        // Opening the editor intentionally changes the visible selection; subsequent replies return the new token.
        if previewAsset == nil { presentPreview(item) }
        attachColorSession(editor)
        return editor
    }
    func automationFinishEditor() async throws {
        guard let editor = colorEditor else { return }
        guard await editor.flush() else { throw ColorEditError(editor.saveError ?? "保存调色失败") }
        editor.dispose(); colorEditor = nil; colorEditorObservation = nil
    }
    func automationReload() async { await reloadAssets(); colorPresets = (try? await store?.colorPresets()) ?? [] }
    func automationBackupURL() throws -> URL { try backupURL() }
    func automationChooseDirectory() async throws -> URL {
        let panel = NSOpenPanel()
        automationDirectoryPanel = panel
        defer { automationDirectoryPanel = nil }
        panel.title = "为 AI 助手选择成片导出目录"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
        guard response == .OK, let url = panel.url else { throw ColorEditError("已取消目录授权") }
        return url
    }
    func automationCancelDirectorySelection() { automationDirectoryPanel?.cancel(nil) }
}
