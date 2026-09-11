import Combine
import Foundation

public enum PhotoShareEvent: Sendable {
    case chosen(String), cancelled, completed, failed(String)
}

@MainActor public protocol PhotoSharePresenting: AnyObject {
    func show(files: [URL], event: @escaping @MainActor (PhotoShareEvent) -> Void) throws
    func dismiss()
}

/// Observable UI gates are independent of AppKit's unobservable modal window state.
@MainActor public final class PhotoShareSession: ObservableObject {
    public enum Phase: Equatable { case idle, ready, choosing, sharing, finished }
    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var prepared: PreparedPhotoShare?
    @Published public private(set) var message = ""
    @Published public var acceptsPartial = false
    private let presenter: any PhotoSharePresenting
    private var coordinator: PhotoShareCoordinator?
    private var token: UUID?
    private var generation = UUID()
    private var handedToSystem = false
    private var cleanupTask: Task<Void, Never>?
    public var isActive: Bool { prepared != nil }
    public var blocksFileChanges: Bool { prepared?.mode == .original }
    public var requiresExitConfirmation: Bool { blocksFileChanges }
    public var canPresent: Bool {
        phase == .ready && prepared?.files.isEmpty == false && (prepared?.issues.isEmpty == true || acceptsPartial)
    }

    public init(presenter: any PhotoSharePresenting) { self.presenter = presenter }
    public func install(_ prepared: PreparedPhotoShare, coordinator: PhotoShareCoordinator) throws {
        guard !isActive else { throw ColorEditError("请先结束已有分享会话") }
        self.prepared = prepared; self.coordinator = coordinator; token = prepared.id
        generation = UUID()
        handedToSystem = false; acceptsPartial = false; message = ""; phase = .ready
    }
    public func present() {
        guard canPresent, let prepared, let token else { return }
        do {
            // Small durable retention marker precedes any handoff to the system.
            try prepared.retainCacheForSystem()
            phase = .choosing
            try presenter.show(files: prepared.files.map(\.url)) { [weak self] event in
                self?.receive(event, token: token)
            }
        } catch { finish(message: "无法打开系统分享：\(error.localizedDescription)") }
    }
    private func receive(_ event: PhotoShareEvent, token: UUID) {
        guard self.token == token, phase == .choosing || phase == .sharing else { return }
        switch event {
        case .chosen(let service):
            guard phase == .choosing else { return }
            handedToSystem = true; phase = .sharing; message = "已交给\(service)处理；不代表收件人已收到"
        case .cancelled:
            finish(message: handedToSystem ? "分享服务已取消" : "已关闭系统分享")
        case .completed:
            guard phase == .sharing else { return }
            finish(message: "系统分享服务已完成处理；不代表收件人已收到")
        case .failed(let reason): finish(message: "分享未完成：\(reason)")
        }
    }
    /// Ends our ownership, not an external app's sending operation.
    public func end() { finish(message: "本次分享会话已结束；不能撤回或停止外部应用发送") }
    public func discardPreparation() {
        guard phase == .ready else { return }
        finish(message: "", finalPhase: .idle)
    }
    private func finish(message: String, finalPhase: Phase = .finished) {
        guard let prepared else { return }
        let id = prepared.id, directory = prepared.cacheDirectory, handed = handedToSystem
        let generation = self.generation
        token = nil; self.prepared = nil; phase = finalPhase; self.message = message
        presenter.dismiss()
        let coordinator = self.coordinator
        self.coordinator = nil
        cleanupTask = Task { [weak self] in
            do { try await coordinator?.finish(id: id, cacheDirectory: directory, handedToSystem: handed) }
            catch {
                if self?.generation == generation { self?.message += "；分享缓存清理失败：\(error.localizedDescription)" }
            }
        }
    }
    public func waitForCleanup() async { await cleanupTask?.value }
}
