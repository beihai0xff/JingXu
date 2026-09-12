import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import JingXuCore
import MCP

public struct AutomationPhoto: Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public struct AutomationSelection: Sendable {
    public let token: String
    public let currentID: String?
    public let photos: [AutomationPhoto]
    public init(token: String, currentID: String?, photos: [AutomationPhoto]) {
        self.token = token; self.currentID = currentID; self.photos = photos
    }
}

@MainActor public protocol ColorAutomationHost: AnyObject {
    var automationSelection: AutomationSelection { get async throws }
    var automationEditor: ColorEditSession? { get }
    var automationBusy: Bool { get }
    func automationBeginOperation() async throws
    func automationEndOperation()
    func automationOpenEditor(assetID: String) async throws -> ColorEditSession
    func automationFinishEditor() async throws
    func automationReload() async
    func automationChooseDirectory() async throws -> URL
    func automationCancelDirectorySelection()
    func automationBackupURL() throws -> URL
}

/// Shares the application's editor and its operation gate; never opens a second catalog connection.
@MainActor public final class ColorAutomationController {
    private weak var host: (any ColorAutomationHost)?
    private let store: CatalogStore
    private let exporter: ColorExportCoordinator
    private var active = false
    private var enabled = true
    private var plans: [String: Plan] = [:]
    private var jobs: [String: Job] = [:]
    private var directories: [String: Directory] = [:]
    private var revokedClients = Set<String>()
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    private enum Operation { case batch(ColorBatchPlan), export(ColorExportPlan) }
    private struct Plan {
        let owner: String
        let scope: String
        let operation: Operation
        let presentation: [String: Value]
        var jobID: String?
    }
    @MainActor private final class Job {
        let owner: String
        var status = "running"
        var result: [String: Value] = [:]
        var completed = 0
        var total = 0
        var task: Task<Void, Never>?
        var undo: ColorBatchPlan?
        init(owner: String) { self.owner = owner }
        var value: [String: Value] {
            ["status": .string(status), "completed": .int(completed), "total": .int(total), "result": .object(result)]
        }
    }
    private struct Directory {
        let owner: String
        let url: URL
        let identity: SourceIdentity
        let lease: PreviewAccessLease
    }

    public init(host: any ColorAutomationHost, store: CatalogStore, exporter: ColorExportCoordinator? = nil) {
        self.host = host; self.store = store; self.exporter = exporter ?? ColorExportCoordinator(store: store)
    }
    public func shutdown() async {
        enabled = false
        host?.automationCancelDirectorySelection()
        let tasks = jobs.values.compactMap(\.task)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        if active { await withCheckedContinuation { shutdownWaiters.append($0) } }
        plans.removeAll(); directories.removeAll(); jobs.removeAll()
    }
    public func disconnect(client: String) {
        revokedClients.insert(client)
        plans = plans.filter { $0.value.owner != client }
        directories = directories.filter { $0.value.owner != client }
        for job in jobs.values where job.owner == client { job.task?.cancel() }
        jobs = jobs.filter { $0.value.owner != client || $0.value.task != nil }
    }
    public func cancelCurrentJob() { for job in jobs.values where job.status == "running" { job.task?.cancel() } }
    private func requireHost() throws -> any ColorAutomationHost {
        guard enabled, let host else { throw ColorEditError("镜序 AI 连接已关闭") }
        return host
    }
    private func scope(_ arguments: [String: Value]) async throws -> AutomationSelection {
        let selection = try await requireHost().automationSelection
        guard selection.token == (try arguments.requiredString("selectionToken")), !selection.photos.isEmpty else {
            throw ColorEditError("选择已变化或为空，请重新读取 get_context")
        }
        return selection
    }
    private func acquire() async throws {
        let host = try requireHost()
        guard !active, !host.automationBusy else { throw ColorEditError("镜序正在执行其他操作，请稍后重试") }
        active = true
        do { try await host.automationBeginOperation(); guard enabled else { throw ColorEditError("连接已关闭") } }
        catch { release(); throw error }
    }
    private func release() {
        active = false; host?.automationEndOperation()
        let waiters = shutdownWaiters; shutdownWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    private func version(_ snapshot: ColorEditSnapshot) throws -> String {
        struct Version: Encodable {
            let asset: MediaAsset
            let source: SourceRoot
            let revision: Int
            let draft: UUID?
        }
        let editor = host?.automationEditor
        let value = Version(asset: snapshot.asset, source: snapshot.source, revision: snapshot.revision,
                            draft: editor?.snapshot.asset.id == snapshot.asset.id ? editor?.editVersion : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    private func current(_ args: [String: Value]) async throws -> ColorEditSnapshot {
        let selected = try await scope(args), id = try args.requiredString("assetID")
        guard selected.currentID == id, selected.photos.contains(where: { $0.id == id }) else { throw ColorEditError("只能调整当前照片；批量请选择 prepare_batch") }
        let snapshot = try await store.colorSnapshot(assetID: id)
        _ = try await scope(args)
        guard try version(snapshot) == args.requiredString("editVersion") else { throw ColorEditError("照片、来源或调整已变化，请重新读取 get_context") }
        return snapshot
    }
    private func context() async throws -> CallTool.Result {
        let host = try requireHost(), selected = try await host.automationSelection
        var photos: [Value] = []
        for photo in selected.photos {
            let snapshot = try await store.colorSnapshot(assetID: photo.id)
            photos.append(["assetID": .string(photo.id), "name": .string(photo.name),
                           "editVersion": .string(try version(snapshot)), "isRAW": .bool(snapshot.isRAW)])
        }
        var value: [String: Value] = ["selectionToken": .string(selected.token), "busy": .bool(active || host.automationBusy),
            "selected": .array(photos),
            "selectedCount": .int(selected.photos.count), "current": .null]
        if let id = selected.currentID, selected.photos.contains(where: { $0.id == id }) {
            let snapshot = try await store.colorSnapshot(assetID: id)
            let editor = host.automationEditor
            let values = try editor?.snapshot.asset.id == id ? editor!.adjustments : snapshot.adjustments
            let ranges = Dictionary(uniqueKeysWithValues: ColorParameter.allCases.map { p in
                (p.rawValue, Value.array([.double(p.range(isRAW: snapshot.isRAW).lowerBound), .double(p.range(isRAW: snapshot.isRAW).upperBound)]))
            })
            value["current"] = ["assetID": .string(id), "name": .string(snapshot.asset.fileName), "isRAW": .bool(snapshot.isRAW),
                "editVersion": .string(try version(snapshot)), "savedRevision": .int(snapshot.revision), "adjustments": AutomationTools.adjustments(values),
                "ranges": .object(ranges), "dirty": .bool(editor?.isDirty ?? false),
                "canUndo": .bool(editor?.history.canUndo ?? false), "canRedo": .bool(editor?.history.canRedo ?? false),
                "saveError": editor?.saveError.map(Value.string) ?? .null]
        }
        guard try await host.automationSelection.token == selected.token else { throw ColorEditError("选择已变化，请重读上下文") }
        return AutomationTools.reply(value)
    }

    public func call(_ name: String, arguments args: [String: Value], client: String) async throws -> CallTool.Result {
        try AutomationTools.validate(name: name, arguments: args)
        let host = try requireHost()
        guard !revokedClients.contains(client) else { throw ColorEditError("连接已失效") }
        switch name {
        case "get_context": return try await context()
        case "get_preview":
            guard !active, !host.automationBusy else { throw ColorEditError("镜序正在操作，请稍后读取预览") }
            let selected = try await scope(args), id = try args.requiredString("assetID")
            guard selected.photos.contains(where: { $0.id == id }) else { throw ColorEditError("照片不在当前选择范围") }
            let snapshot = try await store.colorSnapshot(assetID: id)
            guard try version(snapshot) == args.requiredString("editVersion") else { throw ColorEditError("照片、来源或调整已变化，请重读上下文") }
            let original = args["original"]?.boolValue ?? false
            let values = try original ? ColorAdjustments() : (host.automationEditor?.snapshot.asset.id == id ? host.automationEditor!.adjustments : snapshot.adjustments)
            let result = try await ColorImageRenderer.shared.render(snapshot, adjustments: values, maximumDimension: 2048)
            try await store.validateColorSnapshot(snapshot)
            _ = try await scope(args)
            guard try version(snapshot) == args.requiredString("editVersion"), enabled else { throw ColorEditError("渲染期间调整已变化，请重新读取预览") }
            // Encode the CGImage only: never copy EXIF, GPS, thumbnails or source metadata.
            let data = try await Self.encodePreview(result)
            _ = try await scope(args)
            guard enabled, try version(snapshot) == args.requiredString("editVersion") else { throw ColorEditError("预览已过期") }
            let histogram = result.histogram
            return AutomationTools.reply(["assetID": .string(id), "editVersion": .string(try version(snapshot)), "original": .bool(original),
                "width": .int(result.image.width), "height": .int(result.image.height), "colorSpace": "sRGB",
                "histogram": ["red": .array(histogram.red.map(Value.int)), "green": .array(histogram.green.map(Value.int)),
                              "blue": .array(histogram.blue.map(Value.int)), "luminance": .array(histogram.luminance.map(Value.int))]], image: data)
        case "set_adjustments", "undo", "redo", "save_preset":
            try await acquire(); defer { release() }
            let snapshot = try await current(args)
            try await store.validateColorSnapshot(snapshot)
            _ = try await current(args)
            let previousEditor = host.automationEditor
            let previousVersion = previousEditor?.editVersion
            let editor = try await host.automationOpenEditor(assetID: snapshot.asset.id)
            guard enabled, !revokedClients.contains(client),
                  editor.snapshot.asset.id == snapshot.asset.id,
                  (previousEditor == nil ? editor.snapshot.revision == snapshot.revision : (previousEditor === editor && editor.editVersion == previousVersion)) else {
                throw ColorEditError("编辑会话或连接已变化，请重新读取上下文")
            }
            if name == "save_preset" {
                let title = try args.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, title.count <= 120 else { throw ColorEditError("预设名称需为 1–120 个字符") }
                let preset = try ColorPreset(name: title, patch: ColorPatch(editor.adjustments))
                try await store.saveColorPreset(preset); await host.automationReload()
                return AutomationTools.reply(["presetID": .string(preset.id), "name": .string(preset.name)])
            }
            let change: ColorEditSession.ExternalChange
            if name == "set_adjustments" {
                guard let object = args["adjustments"]?.objectValue else { throw ColorEditError("缺少调整参数") }
                change = .set(try AutomationTools.patch(object).applying(to: editor.adjustments, groups: Set(ColorGroup.allCases), isRAW: editor.isRAW))
            } else { change = name == "undo" ? .undo : .redo }
            try await editor.applyExternal(change, expectedVersion: editor.editVersion)
            return try await context()
        case "list_presets":
            let presets = try await store.colorPresets()
            return AutomationTools.reply(["presets": .array(try presets.map { preset in
                let patch = try preset.patch
                var parameters = Dictionary(uniqueKeysWithValues: patch.values.map { ($0.key.rawValue, Value.double($0.value)) })
                parameters["whiteBalance"] = patch.whiteBalance.map { .string($0.rawValue) }
                return ["presetID": .string(preset.id), "name": .string(preset.name), "target": .string(patch.target.rawValue), "adjustments": .object(parameters)]
            })])
        case "choose_export_directory":
            try await acquire(); defer { release() }
            guard directories.count < 32 else { throw ColorEditError("已授权目录过多，请重新连接") }
            let url = try await host.automationChooseDirectory()
            guard enabled, !revokedClients.contains(client) else { throw ColorEditError("连接已关闭") }
            let lease = PreviewAccessLease(url: url), id = UUID().uuidString
            directories[id] = Directory(owner: client, url: url, identity: try SourceIdentity.resolve(url), lease: lease)
            return AutomationTools.reply(["directoryID": .string(id), "path": .string(url.path)])
        case "prepare_batch", "prepare_export":
            _ = try await scope(args)
            try await acquire()
            do {
                _ = try await scope(args)
                try await host.automationFinishEditor()
                let selected = try await scope(args)
                let ids = selected.photos.map(\.id)
                let operation: @MainActor () async throws -> Operation
                if name == "prepare_batch" {
                    guard (args["adjustments"] != nil) != (args["presetID"] != nil) else { throw ColorEditError("adjustments 与 presetID 必须二选一") }
                    let patch: ColorPatch
                    if let presetID = args["presetID"]?.stringValue {
                        guard let preset = try await store.colorPresets().first(where: { $0.id == presetID }) else { throw ColorEditError("预设不存在") }
                        patch = try preset.patch
                    } else { patch = try AutomationTools.patch(args["adjustments"]!.objectValue!) }
                    let rawGroups = args["groups"]?.arrayValue ?? ColorGroup.allCases.map { .string($0.rawValue) }
                    let groups = try Set(rawGroups.map { value -> ColorGroup in
                        guard let raw = value.stringValue, let group = ColorGroup(rawValue: raw) else { throw ColorEditError("参数分组无效") }; return group
                    })
                    guard !groups.isEmpty, groups.count == rawGroups.count else { throw ColorEditError("参数分组为空或重复") }
                    operation = { .batch(try await self.store.prepareColorBatch(assetIDs: ids, patch: patch, groups: groups)) }
                } else {
                    let id = try args.requiredString("directoryID")
                    guard let directory = directories[id], directory.owner == client,
                          try SourceIdentity.resolve(directory.url) == directory.identity else { throw ColorEditError("导出目录未授权、已变化或连接已失效") }
                    guard let format = ColorExportFormat(rawValue: try args.requiredString("format")) else { throw ColorEditError("导出格式无效") }
                    operation = { .export(try await self.exporter.prepare(assetIDs: ids, directory: directory.url, format: format)) }
                }
                return try startJob(client: client) { job in
                    let operation = try await operation()
                    try Task.checkCancellation()
                    guard try await self.host?.automationSelection.token == selected.token else { throw ColorEditError("准备期间选择已变化，请重新准备") }
                    let presentation = try self.makePlan(operation, owner: client, scope: selected.token)
                    job.result = presentation
                }
            } catch { release(); throw error }
        case "execute_plan":
            let id = try args.requiredString("planID")
            guard var plan = plans[id], plan.owner == client else { throw ColorEditError("清单不存在或已失效") }
            if let jobID = plan.jobID { return AutomationTools.reply(["jobID": .string(jobID)]) }
            guard try await host.automationSelection.token == plan.scope else { throw ColorEditError("选择已变化，请重新生成清单") }
            try await acquire()
            do {
                guard try await host.automationSelection.token == plan.scope else { throw ColorEditError("选择已变化") }
                // A manual draft must never be discarded by a batch commit.
                try await host.automationFinishEditor()
                let operation = plan.operation
                let reply = try startJob(client: client) { job in
                    switch operation {
                    case .batch(let batch):
                        job.total = batch.items.count
                        job.undo = try await self.store.applyColorBatch(batch, backupURL: host.automationBackupURL())
                        job.completed = job.total
                        job.result = ["applied": .int(batch.items.count), "skipped": .array(batch.warnings.map(Value.string))]
                    case .export(let export):
                        job.total = export.items.count
                        let report = try await self.exporter.execute(export) { done, total in
                            await MainActor.run { job.completed = done; job.total = total }
                        }
                        if report.cancelled { job.status = "cancelled" }
                        else { job.completed = job.total; if !report.failed.isEmpty { job.status = "failed" } }
                        job.result = ["written": .array(report.written.map { .string($0.path) }), "skipped": .array(report.skipped.map(Value.string)),
                                      "failed": .array(report.failed.map(Value.string)), "cancelled": .bool(report.cancelled)]
                    }
                    await host.automationReload()
                }
                plan.jobID = reply.structuredContent?.objectValue?["jobID"]?.stringValue
                plans[id] = plan
                return reply
            } catch { release(); throw error }
        case "get_job", "cancel_job":
            let id = try args.requiredString("jobID")
            guard let job = jobs[id], job.owner == client else { throw ColorEditError("任务不存在或不属于当前连接") }
            if name == "cancel_job" { job.task?.cancel() }
            return AutomationTools.reply(job.value.merging(["jobID": .string(id)]) { _, b in b })
        case "undo_batch":
            let id = try args.requiredString("jobID")
            guard let job = jobs[id], job.owner == client, job.status == "completed", let undo = job.undo else { throw ColorEditError("该任务没有可撤销的批量调色") }
            return AutomationTools.reply(try makePlan(.batch(undo), owner: client, scope: try await host.automationSelection.token))
        default: throw ColorEditError("未知工具")
        }
    }

    /// Caller has acquired the host operation gate. The job releases it on every exit path.
    private func startJob(client: String, work: @escaping @MainActor (Job) async throws -> Void) throws -> CallTool.Result {
        guard jobs.count < 128 else { throw ColorEditError("任务记录已达上限，请重新连接") }
        let id = UUID().uuidString, job = Job(owner: client)
        jobs[id] = job
        job.task = Task {
            defer {
                job.task = nil; self.release()
                if self.revokedClients.contains(client) { self.jobs[id] = nil }
            }
            do {
                try Task.checkCancellation()
                try await work(job)
                if job.status == "running" { job.status = "completed" }
            } catch is CancellationError { job.status = "cancelled" }
            catch { job.status = "failed"; job.result = ["error": .string(error.localizedDescription)] }
        }
        return AutomationTools.reply(["jobID": .string(id)])
    }
    private func makePlan(_ operation: Operation, owner: String, scope: String) throws -> [String: Value] {
        guard enabled, !revokedClients.contains(owner), plans.count < 128 else { throw ColorEditError("连接或清单已失效，请重新连接") }
        let id = UUID().uuidString
        var result: [String: Value] = ["planID": .string(id), "requiresConfirmation": true]
        switch operation {
        case .batch(let plan):
            guard !plan.items.isEmpty else { throw ColorEditError("没有可应用的照片：" + plan.warnings.joined(separator: "；")) }
            result["kind"] = "batch"
            result["items"] = .array(plan.items.map { ["assetID": .string($0.id), "name": .string($0.snapshot.asset.fileName),
                "path": .string(URL(fileURLWithPath: $0.snapshot.source.pathHint).appendingPathComponent($0.snapshot.asset.relativePath).path),
                "revision": .int($0.snapshot.revision), "adjustments": AutomationTools.adjustments($0.adjustments)] })
            result["skipped"] = .array(plan.warnings.map(Value.string))
        case .export(let plan):
            guard !plan.items.isEmpty else { throw ColorEditError("没有可导出的照片：" + plan.skipped.joined(separator: "；")) }
            result["kind"] = "export"; result["format"] = .string(plan.format.rawValue)
            result["directory"] = .string(plan.directory.path)
            result["items"] = .array(plan.items.map { ["assetID": .string($0.id), "name": .string($0.snapshot.asset.fileName),
                "revision": .int($0.snapshot.revision), "destination": .string($0.destination.path), "adjustments": AutomationTools.adjustments($0.adjustments)] })
            result["skipped"] = .array(plan.skipped.map(Value.string))
        }
        plans[id] = Plan(owner: owner, scope: scope, operation: operation, presentation: result)
        return result
    }

    nonisolated private static func encodePreview(_ result: ColorRenderedImage) async throws -> Data {
        try await Task.detached {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ColorEditError("预览编码失败") }
            CGImageDestinationAddImage(destination, result.image, nil)
            guard CGImageDestinationFinalize(destination) else { throw ColorEditError("预览编码失败") }
            return data as Data
        }.value
    }
}
