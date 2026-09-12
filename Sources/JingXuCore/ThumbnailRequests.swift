import Foundation

/// Coalesces equal renders while cancellation belongs to each subscriber.
public actor ThumbnailRequests {
    private struct Request {
        let id: UUID
        var waiters: [UUID: CheckedContinuation<Data, any Error>]
        var task: Task<Void, Never>?
    }
    private var requests: [String: Request] = [:]
    public init() {}
    public func data(key: String, operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
        let subscriber = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var request = requests[key] {
                    request.waiters[subscriber] = continuation; requests[key] = request
                } else {
                    let id = UUID()
                    requests[key] = Request(id: id, waiters: [subscriber: continuation])
                    requests[key]?.task = Task {
                        let result: Result<Data, any Error>
                        do { result = .success(try await operation()) } catch { result = .failure(error) }
                        self.finish(key: key, id: id, result: result)
                    }
                }
            }
        } onCancel: { Task { await self.cancel(key: key, subscriber: subscriber) } }
    }
    private func cancel(key: String, subscriber: UUID) {
        guard var request = requests[key], let waiter = request.waiters.removeValue(forKey: subscriber) else { return }
        waiter.resume(throwing: CancellationError())
        if request.waiters.isEmpty { request.task?.cancel(); requests.removeValue(forKey: key) }
        else { requests[key] = request }
    }
    private func finish(key: String, id: UUID, result: Result<Data, any Error>) {
        guard let request = requests[key], request.id == id else { return }
        requests.removeValue(forKey: key)
        for waiter in request.waiters.values { waiter.resume(with: result) }
    }
}
