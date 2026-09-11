import Foundation
import ImageIO
import UniformTypeIdentifiers
import JingXuCore
import JingXuAutomation
import MCP
import GRDB

@MainActor enum AutomationChecks {
    final class Host: ColorAutomationHost {
        let store: CatalogStore
        let directory: URL
        var automationSelection: AutomationSelection
        var automationEditor: ColorEditSession?
        var automationBusy = false
        var failBackup = false
        var failAuthorization = false
        var beforeOpen: (() -> Void)?
        var opening: (() async -> Void)?
        var shutdownObserved = false
        init(store: CatalogStore, directory: URL, photos: [ColorEditSnapshot]) {
            self.store = store; self.directory = directory
            automationSelection = .init(token: UUID().uuidString, currentID: photos.first?.asset.id,
                photos: photos.map { .init(id: $0.asset.id, name: $0.asset.fileName) })
        }
        func automationBeginOperation() async throws {
            guard !automationBusy else { throw ColorEditError("busy") }; automationBusy = true
        }
        func automationEndOperation() { automationBusy = false }
        func automationOpenEditor(assetID: String) async throws -> ColorEditSession {
            beforeOpen?()
            await opening?()
            if let automationEditor { return automationEditor }
            let editor = try ColorEditSession(store: store, snapshot: await store.colorSnapshot(assetID: assetID), saved: {})
            automationEditor = editor
            return editor
        }
        func automationFinishEditor() async throws {
            guard let editor = automationEditor else { return }
            guard await editor.flush() else { throw ColorEditError("save failed") }
            editor.dispose(); automationEditor = nil
        }
        func automationReload() async {}
        func automationChooseDirectory() async throws -> URL {
            if failAuthorization { throw ColorEditError("cancelled") }; return directory
        }
        func automationCancelDirectorySelection() { shutdownObserved = true }
        func automationBackupURL() throws -> URL {
            if failBackup { throw ColorEditError("injected backup failure") }
            return directory.appendingPathComponent("backup-\(UUID()).sqlite")
        }
        func changeSelection() {
            automationSelection = .init(token: UUID().uuidString, currentID: automationSelection.currentID, photos: automationSelection.photos)
        }
    }
    static func object(_ reply: CallTool.Result) throws -> [String: Value] {
        guard let object = reply.structuredContent?.objectValue else { throw ColorEditError("missing structured response") }; return object
    }
    static func editArguments(_ reply: CallTool.Result) throws -> [String: Value] {
        let context = try object(reply)
        guard let current = context["current"]?.objectValue else { throw ColorEditError("missing current") }
        return ["selectionToken": context["selectionToken"]!, "assetID": current["assetID"]!, "editVersion": current["editVersion"]!]
    }
    static func rejected(_ work: () async throws -> Void) async throws {
        do { try await work(); throw ColorChecks.Failure(description: "应拒绝的自动化操作被接受") } catch is ColorEditError {}
    }
    static func poll(_ controller: ColorAutomationController, _ reply: CallTool.Result, client: String = "test") async throws -> [String: Value] {
        let id = try object(reply)["jobID"]!
        for _ in 0..<500 {
            let result = try object(await controller.call("get_job", arguments: ["jobID": id], client: client))
            if result["status"] != "running" { return result }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ColorEditError("任务未完成")
    }
    static func run() async throws {
        let root = try ColorChecks.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        let source = SourceRoot(name: "automation", bookmarkData: nil, pathHint: root.path)
        try await store.upsertSource(source)
        let one = try await metadataFixture(store: store, source: source)
        let two = try await ColorChecks.fixture(store: store, source: source, name: "two.png")
        let originalHash = try FileHasher.sha256(of: root.appendingPathComponent("one.jpg"))
        // The same authorized directory can arrive without URL's trailing-directory hint.
        let host = Host(store: store, directory: URL(fileURLWithPath: root.path, isDirectory: false), photos: [one, two])
        let controller = ColorAutomationController(host: host, store: store)
        func call(_ name: String, _ args: [String: Value] = [:]) async throws -> CallTool.Result {
            try await controller.call(name, arguments: args, client: "test")
        }
        var args = try editArguments(await call("get_context"))
        let preview = try await call("get_preview", args)
        guard case .image(let encoded, _, _, _) = preview.content.last, let image = Data(base64Encoded: encoded),
              let decoded = CGImageSourceCreateWithData(image as CFData, nil),
              let metadata = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any] else { throw ColorEditError("预览图片内容缺失") }
        // ImageIO synthesizes output dimensions and sRGB ColorSpace in its decoded EXIF view.
        let exif = metadata[kCGImagePropertyExifDictionary] as? [String: Any] ?? [:]
        try ColorChecks.check(metadata[kCGImagePropertyGPSDictionary] == nil && Set(exif.keys).isSubset(of: ["ColorSpace", "PixelXDimension", "PixelYDimension"]), "预览包含原片 EXIF 或 GPS")
        try ColorChecks.check(try object(preview)["width"] == .int(80), "MCP 预览方向错误")
        // A rescan can replace a file's identity while preserving its photo ID and edit revision.
        let beforeRescan = args
        let originalURL = root.appendingPathComponent("one.jpg")
        let bytes = try Data(contentsOf: originalURL)
        try bytes.write(to: originalURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: one.asset.modifiedAt], ofItemAtPath: originalURL.path)
        _ = try await DefaultSourceScanner(repository: store).scan(source: source)
        let rescanned = try await store.colorSnapshot(assetID: one.asset.id)
        try ColorChecks.check(rescanned.revision == one.revision && rescanned.asset.fileIdentifier != one.asset.fileIdentifier,
                              "重扫检查未覆盖同修订的文件替换")
        try await rejected { _ = try await call("get_preview", beforeRescan) }
        try await rejected { _ = try await call("set_adjustments", beforeRescan.merging(["adjustments": ["exposure": 2]]) { _, b in b }) }
        args = try editArguments(await call("get_context"))
        _ = try await call("get_preview", args)
        let stale = args
        args["adjustments"] = ["exposure": 1, "shadows": 15]
        _ = try await call("set_adjustments", args)
        let saved = try await store.colorSnapshot(assetID: one.asset.id)
        try ColorChecks.check(try saved.adjustments.exposure == 1 && saved.adjustments.shadows == 15, "MCP 参数未保存")
        try await rejected { _ = try await call("set_adjustments", stale.merging(["adjustments": ["exposure": 2]]) { _, b in b }) }
        args = try editArguments(await call("get_context"))
        _ = try await call("undo", args)
        try ColorChecks.check(try await store.colorSnapshot(assetID: one.asset.id).adjustments.exposure == 0, "MCP 撤销失败")
        _ = try await call("redo", editArguments(await call("get_context")))
        args = try editArguments(await call("get_context"))
        host.automationEditor?.change(.contrast, value: 5)
        try await rejected { _ = try await call("set_adjustments", args.merging(["adjustments": ["exposure": 3]]) { _, b in b }) }
        _ = await host.automationEditor?.flush()
        args = try editArguments(await call("get_context"))
        host.beforeOpen = { host.automationEditor?.change(.contrast, value: 9) }
        try await rejected { _ = try await call("set_adjustments", args.merging(["adjustments": ["exposure": 3]]) { _, b in b }) }
        host.beforeOpen = nil
        try ColorChecks.check(host.automationEditor?.adjustments.contrast == 9, "打开编辑会话期间覆盖了手动调整")
        _ = await host.automationEditor?.flush()
        args = try editArguments(await call("get_context"))
        try await rejected { _ = try await call("set_adjustments", args.merging(["adjustments": ["exposure": 6]]) { _, b in b }) }
        try await rejected { _ = try await call("set_adjustments", args.merging(["adjustments": ["temperature": 10]]) { _, b in b }) }
        try await rejected { _ = try await call("set_adjustments", args.merging(["adjustments": ["whiteBalance": "raw", "temperature": 6500, "tint": 0]]) { _, b in b }) }
        try await rejected { _ = try await call("set_adjustments", args.merging(["adjustments": ["HSL": 10]]) { _, b in b }) }
        let database = try DatabaseQueue(path: root.appendingPathComponent("Catalog.sqlite").path)
        try await database.write { try $0.execute(sql: "CREATE TRIGGER fail_mcp BEFORE UPDATE ON colorEdits BEGIN SELECT RAISE(ABORT, 'injected MCP save failure'); END") }
        try await rejected { _ = try await call("set_adjustments", args.merging(["adjustments": ["exposure": 1.5]]) { _, b in b }) }
        try ColorChecks.check(host.automationEditor?.isDirty == true && host.automationEditor?.saveError != nil, "MCP 保存失败没有保留草稿")
        try ColorChecks.check(try await store.colorSnapshot(assetID: one.asset.id).adjustments.exposure == 1, "保存失败改变了已提交参数")
        try await database.write { try $0.execute(sql: "DROP TRIGGER fail_mcp") }
        try ColorChecks.check(await host.automationEditor?.flush() == true, "MCP 保存失败后无法在共享会话重试")
        try database.close()
        args = try editArguments(await call("get_context"))
        _ = try await call("save_preset", args.merging(["name": "MCP 测试预设"]) { _, b in b })
        try ColorChecks.check(try object(await call("list_presets"))["presets"]?.arrayValue?.count == 1, "预设未保存")
        let selection: [String: Value] = ["selectionToken": .string(host.automationSelection.token)]
        let batchArgs = selection.merging(["adjustments": ["exposure": 2]]) { _, b in b }
        let prepared = try await poll(controller, call("prepare_batch", batchArgs))
        let plan = prepared["result"]!.objectValue!
        try ColorChecks.check(prepared["status"] == "completed" && plan["items"]?.arrayValue?.count == 2, "批量清单未冻结选择")
        host.changeSelection()
        try await rejected { _ = try await call("execute_plan", ["planID": plan["planID"]!]) }
        let fresh = try await poll(controller, call("prepare_batch", ["selectionToken": .string(host.automationSelection.token), "adjustments": ["exposure": 2]]))
        let freshID = fresh["result"]!.objectValue!["planID"]!
        let execution = try await call("execute_plan", ["planID": freshID])
        let duplicate = try await call("execute_plan", ["planID": freshID])
        try ColorChecks.check(try object(execution) == object(duplicate), "重复执行未返回同一任务")
        let completed = try await poll(controller, execution)
        try ColorChecks.check(completed["status"] == "completed", "批量执行失败")
        try ColorChecks.check(try await store.colorSnapshot(assetID: two.asset.id).adjustments.exposure == 2, "所选第二张未应用")
        try await rejected { _ = try await controller.call("get_job", arguments: object(execution), client: "another-client") }
        let inverse = try object(await call("undo_batch", object(execution)))
        let reverted = try await poll(controller, call("execute_plan", ["planID": inverse["planID"]!]))
        try ColorChecks.check(reverted["status"] == "completed", "批量撤销失败")
        try ColorChecks.check(try await store.colorSnapshot(assetID: two.asset.id).adjustments.exposure == 0, "批量撤销结果错误")
        // Frozen revision must prevent a later manual save from being overwritten.
        let conflict = try await poll(controller, call("prepare_batch", ["selectionToken": .string(host.automationSelection.token), "adjustments": ["exposure": 3]]))
        let snap = try await store.colorSnapshot(assetID: two.asset.id)
        var manual = try snap.adjustments; manual.exposure = 0.75
        _ = try await store.saveColorAdjustments(manual, snapshot: snap)
        let failed = try await poll(controller, call("execute_plan", ["planID": conflict["result"]!.objectValue!["planID"]!]))
        try ColorChecks.check(failed["status"] == "failed", "过期修订清单没有失败")
        try ColorChecks.check(try await store.colorSnapshot(assetID: two.asset.id).adjustments.exposure == 0.75, "覆盖手动修改")
        let backupPlan = try await poll(controller, call("prepare_batch", ["selectionToken": .string(host.automationSelection.token), "adjustments": ["exposure": 4]]))
        host.failBackup = true
        let backupFailure = try await poll(controller, call("execute_plan", ["planID": backupPlan["result"]!.objectValue!["planID"]!]))
        host.failBackup = false
        try ColorChecks.check(backupFailure["status"] == "failed", "备份失败没有停止批量")
        try await rejected { _ = try await call("prepare_export", ["selectionToken": .string(host.automationSelection.token), "directoryID": "unapproved", "format": "jpeg"]) }
        let directory = try object(await call("choose_export_directory"))["directoryID"]!
        let exportArgs: [String: Value] = ["selectionToken": .string(host.automationSelection.token), "directoryID": directory, "format": "jpeg"]
        let exportPlan = try await poll(controller, call("prepare_export", exportArgs))
        let exportResult = try await poll(controller, call("execute_plan", ["planID": exportPlan["result"]!.objectValue!["planID"]!]))
        try ColorChecks.check(exportResult["result"]?.objectValue?["written"]?.arrayValue?.count == 2, "成片导出未完成")
        let duplicateExport = try await poll(controller, call("prepare_export", exportArgs))
        try ColorChecks.check(duplicateExport["status"] == "failed", "已有成片不应再次准备为覆盖写入")
        let cancellation = try await call("prepare_batch", ["selectionToken": .string(host.automationSelection.token), "adjustments": ["exposure": 1]])
        _ = try await call("cancel_job", object(cancellation))
        let cancelled = try await poll(controller, cancellation)
        try ColorChecks.check(cancelled["status"] == "cancelled" && !host.automationBusy, "取消未释放操作权限")
        try ColorChecks.check(try FileHasher.sha256(of: root.appendingPathComponent("one.jpg")) == originalHash, "MCP 修改了原片")
        // Hold an in-flight edit at an actual suspension: another command must fail,
        // and shutdown must drain the first command before releasing its operation gate.
        let closingArgs = try editArguments(await call("get_context")).merging(["adjustments": ["exposure": 0.25]]) { _, b in b }
        var resumeOpen: CheckedContinuation<Void, Never>?
        host.opening = { await withCheckedContinuation { resumeOpen = $0 } }
        let inFlight = Task { try await call("set_adjustments", closingArgs) }
        for _ in 0..<500 {
            if resumeOpen != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let resumeOpen else { throw ColorEditError("并发检查未进入编辑会话") }
        try await rejected { _ = try await call("set_adjustments", closingArgs) }
        var didShutdown = false
        let closing = Task { await controller.shutdown(); didShutdown = true }
        while !host.shutdownObserved { await Task.yield() }
        try ColorChecks.check(!didShutdown, "关闭没有等待正在提交的操作")
        resumeOpen.resume()
        try await rejected { _ = try await inFlight.value }
        await closing.value
        try ColorChecks.check(!host.automationBusy, "关闭后未释放操作权限")
        host.automationEditor?.dispose()
        try await rejected { _ = try await call("get_context") }
    }

    static func metadataFixture(store: CatalogStore, source: SourceRoot) async throws -> ColorEditSnapshot {
        let url = URL(fileURLWithPath: source.pathHint).appendingPathComponent("one.jpg")
        let image = try QualityV2Checks.image(width: 128, height: 80) { x, y in (UInt8(x), UInt8(y), 120, 255) }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw ColorEditError("fixture encode failed") }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2001:01:01 01:01:01", kCGImagePropertyExifUserComment: "private fixture metadata"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 1.25, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 2.5, kCGImagePropertyGPSLongitudeRef: "E"]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ColorEditError("fixture encode failed") }
        let fingerprint = try AnalysisFingerprint(url: url)
        let asset = MediaAsset(sourceID: source.id, relativePath: url.lastPathComponent, fileIdentifier: fingerprint.identifier,
            fileName: url.lastPathComponent, uniformType: "public.jpeg", kind: .photo, fileSize: fingerprint.size, modifiedAt: fingerprint.modifiedAt)
        _ = try await store.upsertAsset(asset)
        return try await store.colorSnapshot(assetID: asset.id)
    }

    static func verifyFile(_ file: URL, output: URL) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw ColorEditError("输出目录已存在") }
        var parent = output.standardizedFileURL.resolvingSymlinksInPath()
        while parent.path != "/" {
            guard !FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) else { throw ColorEditError("验证产物不能写入 Git 仓库") }
            parent.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = try CatalogStore(databaseURL: output.appendingPathComponent("Catalog.sqlite"))
        let source = SourceRoot(name: "read-only file", bookmarkData: nil, pathHint: file.deletingLastPathComponent().path)
        try await store.upsertSource(source)
        let fingerprint = try AnalysisFingerprint(url: file), hash = try FileHasher.sha256(of: file)
        let asset = MediaAsset(sourceID: source.id, relativePath: file.lastPathComponent, fileIdentifier: fingerprint.identifier,
            fileName: file.lastPathComponent, uniformType: nil, kind: .photo, fileSize: fingerprint.size, modifiedAt: fingerprint.modifiedAt)
        _ = try await store.upsertAsset(asset)
        let host = Host(store: store, directory: output, photos: [try await store.colorSnapshot(assetID: asset.id)])
        let controller = ColorAutomationController(host: host, store: store)
        func call(_ name: String, _ args: [String: Value] = [:]) async throws -> CallTool.Result { try await controller.call(name, arguments: args, client: "test") }
        var args = try editArguments(await call("get_context"))
        let before = try await call("get_preview", args)
        if case .image(let data, _, _, _) = before.content.last { try Data(base64Encoded: data)!.write(to: output.appendingPathComponent("before.png")) }
        args["adjustments"] = ["exposure": 0.5, "shadows": 15, "vibrance": 12]
        _ = try await call("set_adjustments", args)
        _ = try await call("undo", editArguments(await call("get_context")))
        _ = try await call("redo", editArguments(await call("get_context")))
        let after = try await call("get_preview", editArguments(await call("get_context")))
        if case .image(let data, _, _, _) = after.content.last { try Data(base64Encoded: data)!.write(to: output.appendingPathComponent("after.png")) }
        let directory = try object(await call("choose_export_directory"))["directoryID"]!
        let plan = try await poll(controller, call("prepare_export", ["selectionToken": .string(host.automationSelection.token), "directoryID": directory, "format": "jpeg"]))
        let result = try await poll(controller, call("execute_plan", ["planID": plan["result"]!.objectValue!["planID"]!]))
        try ColorChecks.check(result["result"]?.objectValue?["written"]?.arrayValue?.count == 1, "真实文件 MCP 导出失败：\(result)")
        let destination = URL(fileURLWithPath: result["result"]!.objectValue!["written"]!.arrayValue!.first!.stringValue!)
        let decoded = try await ImagePreviewLoader().load(url: destination)
        let snapshot = try await store.colorSnapshot(assetID: asset.id)
        let expected = try await ColorImageRenderer.shared.render(snapshot, adjustments: snapshot.adjustments)
        try ColorChecks.check(decoded.image.width == expected.image.width && decoded.image.height == expected.image.height, "导出尺寸错误")
        try ColorChecks.check(try FileHasher.sha256(of: file) == hash, "真实原片改变")
        await controller.shutdown()
        print("真实文件 MCP 调色、预览、撤销、导出及原片哈希通过：\(decoded.image.width) × \(decoded.image.height)")
    }

    static func networking() async throws {
        let token = String(repeating: "test-only-", count: 5)
        let server = MCPHTTPServer(port: 0, token: token) { name, _, client in
            AutomationTools.reply(["name": .string(name), "client": .string(client)])
        }
        try await server.start()
        guard let port = await server.boundPort else { throw ColorEditError("未监听端口") }
        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        do {
            func status(token header: String?, origin: String? = nil, host: String? = nil) async throws -> Int {
                var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.timeoutInterval = 5
                request.setValue(header, forHTTPHeaderField: "Authorization")
                request.setValue(origin, forHTTPHeaderField: "Origin")
                if let host { request.setValue(host, forHTTPHeaderField: "Host") }
                request.httpBody = Data("{}".utf8)
                let (_, response) = try await URLSession.shared.data(for: request)
                return (response as! HTTPURLResponse).statusCode
            }
            try ColorChecks.check(try await status(token: nil) == 401, "未认证请求被接受")
            try ColorChecks.check(try await status(token: "Bearer wrong") == 401, "错误密钥被接受")
            try ColorChecks.check(try await status(token: "Bearer \(token)", origin: "https://example.com") == 403, "非法 Origin 被接受")
            try ColorChecks.check(try await status(token: "Bearer \(token)", host: "example.com") == 403, "非法 Host 被接受")
            let second = MCPHTTPServer(port: port, token: token) { _, _, _ in AutomationTools.reply([:]) }
            do {
                try await second.start(); await second.stop()
                throw ColorChecks.Failure(description: "端口冲突未报错")
            } catch is ColorChecks.Failure { throw ColorChecks.Failure(description: "端口冲突未报错") }
            catch {
                try ColorChecks.check(error.localizedDescription.contains("端口 \(port) 已被占用"), "端口冲突没有给出明确提示")
            }
            let client = Client(name: "JingXuChecks", version: "1.0")
            let transport = HTTPClientTransport(endpoint: endpoint, configuration: .ephemeral, requestModifier: { @Sendable request in
                var request = request; request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); return request
            })
            _ = try await client.connect(transport: transport)
            let (tools, _) = try await client.listTools()
            try ColorChecks.check(tools.count == AutomationTools.definitions.count, "MCP 工具列表不完整")
            let first = try await client.callTool(name: "get_context", arguments: [:])
            try ColorChecks.check(first.isError != true && !first.content.isEmpty, "MCP 工具实连失败")
            await client.disconnect()
            await server.stop()
            try ColorChecks.check(await server.boundPort == nil, "关闭后仍监听")
        } catch { await server.stop(); throw error }
    }

    /// Bounded, isolated endpoint for a real Codex client; never opens the user's catalog.
    static func serveFile(_ file: URL) async throws {
        guard let token = ProcessInfo.processInfo.environment["JINGXU_MCP_TEST_TOKEN"], token.count >= 32 else { throw ColorEditError("缺少独立测试密钥") }
        let root = try ColorChecks.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        let source = SourceRoot(name: "read-only fixture", bookmarkData: nil, pathHint: file.deletingLastPathComponent().path)
        try await store.upsertSource(source)
        let fingerprint = try AnalysisFingerprint(url: file), hash = try FileHasher.sha256(of: file)
        let asset = MediaAsset(sourceID: source.id, relativePath: file.lastPathComponent, fileIdentifier: fingerprint.identifier,
            fileName: file.lastPathComponent, uniformType: nil, kind: .photo, fileSize: fingerprint.size, modifiedAt: fingerprint.modifiedAt)
        _ = try await store.upsertAsset(asset)
        let host = Host(store: store, directory: root, photos: [try await store.colorSnapshot(assetID: asset.id)])
        let controller = ColorAutomationController(host: host, store: store)
        let server = MCPHTTPServer(port: 52832, token: token, handler: { name, args, client in
            try await controller.call(name, arguments: args, client: client)
        }, disconnected: { client in await controller.disconnect(client: client) })
        do {
            try await server.start()
            print("隔离 MCP 样本服务已就绪：127.0.0.1:52832；最长运行 10 分钟；停止文件：\(root.appendingPathComponent("stop").path)")
            // A client may request early completion without leaving a background process.
            for _ in 0..<600 {
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) { break }
                try await Task.sleep(for: .seconds(1))
            }
            await server.stop(); await controller.shutdown()
            try ColorChecks.check(try FileHasher.sha256(of: file) == hash, "实连验证修改了原片")
        } catch { await server.stop(); await controller.shutdown(); throw error }
    }
}
