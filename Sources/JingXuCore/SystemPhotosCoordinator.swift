import Foundation

public actor SystemPhotosCoordinator {
    public let client: any PhotoLibraryClient
    public let store: SystemPhotosStore
    private let localStore: CatalogStore
    private let temporaryRoot: URL
    private let analyzer: any QualityAnalyzer
    private var busy = false
    public init(client: any PhotoLibraryClient, store: SystemPhotosStore, localStore: CatalogStore,
                temporaryRoot: URL, analyzer: any QualityAnalyzer = DefaultQualityAnalyzer()) {
        self.client = client; self.store = store; self.localStore = localStore
        self.temporaryRoot = temporaryRoot; self.analyzer = analyzer
    }
    private func acquire() throws {
        guard !busy else { throw ColorEditError("系统照片已有任务正在执行") }
        busy = true
    }
    public func prepareUpload(snapshots: [ColorEditSnapshot], mode: PhotoShareMode, album: SystemPhotoAlbum?,
                              progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> SystemPhotoUpload {
        try acquire(); defer { busy = false }
        guard !snapshots.isEmpty else { throw ColorEditError("请先选择本地照片") }
        let workspace = try PhotoWorkspace(parent: temporaryRoot)
        var files: [SystemPhotoUploadFile] = [], paths = Set<URL>()
        for (index, snapshot) in snapshots.enumerated() {
            try Task.checkCancellation()
            try await localStore.validatePhotoShareSnapshot(snapshot, includeAdjustments: mode == .jpeg)
            let access = try ColorSourceAccess(snapshot, checkAdjustment: mode == .jpeg)
            guard paths.insert(access.url.standardizedFileURL).inserted else { continue }
            let ext = mode == .jpeg ? "jpg" : access.url.pathExtension
            let target = workspace.directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            if mode == .jpeg {
                try await ColorImageRenderer.shared.encode(snapshot, adjustments: snapshot.adjustments, format: .jpeg, to: target)
                await ColorImageRenderer.shared.release()
            } else {
                try FileManager.default.copyItem(at: access.url, to: target)
                guard try FileHasher.sha256(of: target) == FileHasher.sha256(of: access.url) else { throw ColorEditError("准备期间原片内容发生变化") }
            }
            try access.revalidate()
            try await localStore.validatePhotoShareSnapshot(snapshot, includeAdjustments: mode == .jpeg)
            let name = mode == .jpeg ? access.url.deletingPathExtension().lastPathComponent + "-调色.jpg" : snapshot.asset.fileName
            files.append(try SystemPhotoUploadFile(url: target, name: name))
            await progress(index + 1, snapshots.count)
        }
        try Task.checkCancellation()
        return SystemPhotoUpload(files: files, album: album, workspace: workspace, sources: snapshots, mode: mode)
    }
    public func upload(_ plan: SystemPhotoUpload) async throws {
        try acquire(); defer { busy = false }
        guard !plan.files.isEmpty, !plan.sources.isEmpty else { throw ColorEditError("上传清单为空") }
        for snapshot in plan.sources {
            try await localStore.validatePhotoShareSnapshot(snapshot, includeAdjustments: plan.mode == .jpeg)
            try ColorSourceAccess(snapshot, checkAdjustment: plan.mode == .jpeg).revalidate()
        }
        for file in plan.files { try file.validate() }
        try Task.checkCancellation()
        try await store.beginWrite(id: plan.id, title: "上传照片", names: plan.files.map(\.name))
        var committed = false
        do {
            _ = try await client.upload(plan) { [store] ids in try store.recordCreated(id: plan.id, ids: ids) }
            committed = true
            try await store.finishWrite(id: plan.id, state: "completed")
        } catch { throw await recordFailure(id: plan.id, error: error, committed: committed) }
    }
    public func mutate(_ plan: SystemPhotoMutationPlan) async throws {
        try acquire(); defer { busy = false }
        guard Set(plan.photos.map(\.id)).count == plan.photos.count else { throw ColorEditError("操作清单包含重复照片") }
        for photo in plan.photos { try await client.validate(photo: photo) }
        try Task.checkCancellation()
        let names: [String]
        if case .createAlbum(let name) = plan.operation { names = [name] }
        else { names = plan.photos.map(\.name) + [plan.albumName].compactMap { $0 } }
        try await store.beginWrite(id: plan.id, title: plan.operation.title, names: names,
                                  targetIDs: plan.photos.map(\.id))
        var committed = false
        do {
            try await client.mutate(plan)
            committed = true
            try await store.finishWrite(id: plan.id, state: "completed")
        } catch { throw await recordFailure(id: plan.id, error: error, committed: committed) }
    }
    public func saveEdit(_ snapshot: ColorEditingSnapshot) async throws {
        try acquire(); defer { busy = false }
        guard case .systemPhoto(let input) = snapshot.origin else { throw ColorEditError("不是系统照片编辑会话") }
        try await store.validateDraft(snapshot)
        try await client.validate(photo: input.photo)
        let workspace = try PhotoWorkspace(parent: temporaryRoot)
        let output = workspace.directory.appendingPathComponent("rendered.jpg")
        try await ColorImageRenderer.shared.encode(snapshot.input, adjustments: snapshot.adjustments, format: .jpeg, to: output)
        try Task.checkCancellation()
        try await store.validateDraft(snapshot)
        let id = UUID()
        try await store.beginWrite(id: id, title: "保存系统照片调色", names: [input.photo.name], targetIDs: [input.photo.id])
        do {
            try await client.saveEdit(input: input, adjustments: snapshot.adjustments, renderedURL: output)
            // Once PhotoKit reports success, any subsequent readback error is an unknown result,
            // not permission to submit the same edit again.
            do {
                guard let photo = try await client.photos(ids: [snapshot.id], albumID: nil).first else { throw ColorEditError("提交后照片暂不可读取") }
                let saved = try await client.editingInput(photo: photo)
                await client.releaseEditingInput(token: saved.token)
                guard saved.adjustments == snapshot.adjustments else { throw ColorEditError("提交后的调整参数尚未核对一致") }
                try await store.completeEdit(writeID: id, photoID: snapshot.id, revision: snapshot.revision)
            } catch { throw SystemPhotosError.commitUnknown("系统已保存，但回读尚未确认：\(error.localizedDescription)。草稿已保留") }
        } catch { throw await recordFailure(id: id, error: error) }
    }
    private func recordFailure(id: UUID, error: Error, committed: Bool = false) async -> Error {
        let unknown: Bool
        if case SystemPhotosError.commitUnknown = error { unknown = true } else { unknown = committed }
        do { try await store.finishWrite(id: id, state: unknown ? "unknown" : "failed", detail: error.localizedDescription) }
        catch { return SystemPhotosError.commitUnknown("本机提交记录无法更新，已保留待核对状态，请勿重复提交：\(error.localizedDescription)") }
        return unknown ? SystemPhotosError.commitUnknown("系统操作结果需要核对，请勿重复提交：\(error.localizedDescription)") : error
    }
    public func analyze(_ initial: SystemPhotoAnalysisJob,
                        progress: @Sendable (SystemPhotoAnalysisJob, String) async -> Void = { _, _ in }) async throws {
        try acquire(); defer { busy = false }
        guard !initial.ended, !initial.photos.isEmpty, Set(initial.photos.map(\.id)).count == initial.photos.count else {
            throw ColorEditError("分析清单为空或包含重复照片")
        }
        var job = initial; job.cancelled = false; job.groupingComplete = false
        try await store.saveJob(job)
        do {
            for photo in job.remaining {
                try Task.checkCancellation()
                await progress(job, photo.name)
                do {
                    let input = try await client.original(photo: photo)
                    let metadata = await DefaultMetadataExtractor().extract(from: input.url, kind: .photo)
                    let result = try await analyzer.analyze(assetID: photo.id, at: input.url)
                    try await client.validate(photo: photo)
                    try input.revalidate(); try Task.checkCancellation()
                    try await store.saveAnalysis(result, sourceVersion: FileHasher.sha256(of: input.url))
                    job.completed.insert(photo.id); job.failures.removeValue(forKey: photo.id)
                    job.cameras[photo.id] = metadata.cameraModel
                } catch is CancellationError { throw CancellationError() }
                catch { job.failures[photo.id] = error.localizedDescription }
                try await store.saveJob(job); await progress(job, photo.name)
            }
            try await groupSimilar(job)
            job.groupingComplete = true
            try await store.saveJob(job); await progress(job, job.remaining.isEmpty ? "本批分析已完成" : "有未完成项，可继续重试")
        } catch is CancellationError {
            job.cancelled = true; try await store.saveJob(job); await progress(job, "已暂停"); throw CancellationError()
        }
    }
    private func groupSimilar(_ job: SystemPhotoAnalysisJob) async throws {
        let photos = job.photos.filter { job.completed.contains($0.id) }
        var items: [SimilarBurstItem] = []
        for photo in photos {
            let result = try await store.analysis(id: photo.id)
            // Missing capture dates must not group unrelated iCloud assets at an invented time.
            if let date = photo.capturedAt {
                items.append(SimilarBurstItem(id: photo.id, date: date, camera: job.cameras[photo.id], feature: result?.featurePrint))
            }
        }
        let groups = try SimilarBurstGrouping.groups(items, distance: analyzer.featureDistance)
        try Task.checkCancellation()
        try await store.setSimilarGroups(groups, ids: photos.map(\.id))
    }
}

public struct SimilarBurstItem: Sendable {
    public let id: String
    public let date: Date
    public let camera: String?
    public let feature: Data?
    public init(id: String, date: Date, camera: String?, feature: Data?) {
        self.id = id; self.date = date; self.camera = camera; self.feature = feature
    }
}

public enum SimilarBurstGrouping {
    public static func groups(_ items: [SimilarBurstItem], distance: (Data, Data) throws -> Float) throws -> [[String]] {
        let sorted = items.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
        var result: [[String]] = [], current: [String] = []
        for index in 1..<max(1, sorted.count) {
            try Task.checkCancellation()
            let previous = sorted[index - 1], next = sorted[index]
            guard previous.camera == next.camera, next.date.timeIntervalSince(previous.date) <= 2,
                  let left = previous.feature, let right = next.feature,
                  let value = try? distance(left, right), value < 0.35 else {
                if !current.isEmpty { result.append(current); current = [] }; continue
            }
            if current.isEmpty { current.append(previous.id) }; current.append(next.id)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
