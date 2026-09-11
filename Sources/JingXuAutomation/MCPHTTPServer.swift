import Foundation
import JingXuCore
import MCP
import NIOCore
import NIOPosix
import NIOHTTP1

/// Owns network sessions only. All photo operations are delegated to the application.
public actor MCPHTTPServer {
    public typealias Handler = @Sendable (String, [String: Value], String) async throws -> CallTool.Result
    private let port: Int
    private let token: String
    private let handler: Handler
    private let disconnected: @Sendable (String) async -> Void
    private var listener: Channel?
    private var children: [ObjectIdentifier: Channel] = [:]
    private var group: MultiThreadedEventLoopGroup?
    private var running = false
    private var sessions: [String: (Server, StatefulHTTPServerTransport)] = [:]
    private var cleanup: Task<Void, Never>?
    private var lastAccess: [String: Date] = [:]

    public init(port: Int, token: String, handler: @escaping Handler,
                disconnected: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.port = port; self.token = token; self.handler = handler; self.disconnected = disconnected
    }
    public func start() async throws {
        guard !running, group == nil, (0...65535).contains(port), token.utf8.count >= 32 else { throw MCPError.invalidRequest("连接设置无效") }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.group = group; running = true
        do {
            listener = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMap {
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(MCPHTTPHandler(server: self))
                        }
                    }
                }.bind(host: "127.0.0.1", port: port).get()
            cleanup = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    await self?.expireSessions()
                }
            }
        } catch {
            running = false; self.group = nil; try? await group.shutdownGracefully()
            if let error = error as? IOError, error.errnoCode == EADDRINUSE {
                throw ColorEditError("本机端口 \(port) 已被占用，请修改端口后重新启用")
            }
            throw error
        }
    }
    public var boundPort: Int? { listener?.localAddress?.port }
    public func stop() async {
        running = false; cleanup?.cancel(); cleanup = nil
        try? await listener?.close(); listener = nil
        for id in Array(sessions.keys) { await closeSession(id) }
        for channel in children.values { try? await channel.close() }
        children.removeAll()
        if let group { try? await group.shutdownGracefully() }
        group = nil
    }
    fileprivate func track(_ channel: Channel) async {
        guard running else { try? await channel.close(); return }
        let id = ObjectIdentifier(channel); children[id] = channel
        Task { [weak self] in try? await channel.closeFuture.get(); await self?.removeChild(id) }
    }
    private func removeChild(_ id: ObjectIdentifier) { children[id] = nil }
    private func closeSession(_ id: String) async {
        guard let (server, transport) = sessions.removeValue(forKey: id) else { return }
        lastAccess[id] = nil
        await transport.disconnect(); await server.stop(); await disconnected(id)
    }
    private func expireSessions() async {
        for (id, date) in lastAccess where Date().timeIntervalSince(date) > 3600 { await closeSession(id) }
    }
    private struct SessionID: SessionIDGenerator { let value: String; func generateSessionID() -> String { value } }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard running else { return .error(statusCode: 503, .internalError("镜序连接已关闭")) }
        guard request.path == "/mcp" else { return .error(statusCode: 404, .invalidRequest("未知端点")) }
        let authority = "127.0.0.1:\(boundPort ?? port)"
        guard request.header("Host") == authority else { return .error(statusCode: 403, .invalidRequest("Host 无效")) }
        if let origin = request.header("Origin"), origin != "http://" + authority { return .error(statusCode: 403, .invalidRequest("Origin 无效")) }
        let supplied = Array((request.header("Authorization") ?? "").utf8), expected = Array("Bearer \(token)".utf8)
        guard supplied.count == expected.count,
              zip(supplied, expected).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            return .error(statusCode: 401, .invalidRequest("连接密钥无效"))
        }
        guard (request.body?.count ?? 0) <= 1_048_576 else { return .error(statusCode: 413, .invalidRequest("请求过大")) }
        if let id = request.header("MCP-Session-Id") {
            guard let (_, transport) = sessions[id] else { return .error(statusCode: 404, .invalidRequest("连接已失效，请重新连接")) }
            lastAccess[id] = Date()
            let response = await transport.handleRequest(request)
            if request.method == "DELETE", response.statusCode == 200 { await closeSession(id) }
            return response
        }
        guard request.method == "POST", let data = request.body,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["method"] as? String == "initialize" else {
            return .error(statusCode: 400, .invalidRequest("请先初始化 MCP 连接"))
        }
        guard sessions.count < 16 else { return .error(statusCode: 429, .invalidRequest("连接数已达上限")) }
        let id = UUID().uuidString, handler = handler
        let transport = StatefulHTTPServerTransport(sessionIDGenerator: SessionID(value: id))
        let server = Server(name: "jingxu", version: "1.0.0", capabilities: .init(tools: .init()))
        // Reserve before suspension so concurrent initializations cannot exceed the session limit.
        sessions[id] = (server, transport); lastAccess[id] = Date()
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: AutomationTools.definitions) }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let arguments = params.arguments ?? [:]
                try AutomationTools.validate(name: params.name, arguments: arguments)
                return try await handler(params.name, arguments, id)
            } catch {
                return AutomationTools.failure(error)
            }
        }
        do {
            guard running, sessions[id] != nil else { throw MCPError.connectionClosed }
            try await server.start(transport: transport)
            let response = await transport.handleRequest(request)
            if response.statusCode >= 400 { await closeSession(id) }
            return response
        } catch { await closeSession(id); return .error(statusCode: 500, .internalError("MCP 初始化失败")) }
    }
}

/// NIO owns parsing/framing; state below is accessed only on the channel's event loop.
private final class MCPHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let server: MCPHTTPServer
    private var head: HTTPRequestHead?
    private var bytes = Data()
    private var processing = false
    private var task: Task<Void, Never>?
    init(server: MCPHTTPServer) { self.server = server }
    func channelActive(context: ChannelHandlerContext) {
        let channel = context.channel, server = server
        Task { await server.track(channel) }
        context.fireChannelActive()
    }
    func channelInactive(context: ChannelHandlerContext) { task?.cancel(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let value):
            guard !processing, head == nil else { context.close(promise: nil); return }
            head = value; bytes.removeAll(keepingCapacity: true)
        case .body(let value):
            guard head != nil, bytes.count + value.readableBytes <= 1_048_576 else { context.close(promise: nil); return }
            bytes.append(contentsOf: value.readableBytesView)
        case .end:
            guard let head, !processing else { context.close(promise: nil); return }
            processing = true; self.head = nil
            var headers: [String: String] = [:]
            for (name, value) in head.headers {
                let key = name.lowercased()
                headers[key] = headers[key].map { $0 + "," + value } ?? value
            }
            let request = HTTPRequest(method: head.method.rawValue, headers: headers, body: bytes, path: head.uri)
            let channel = context.channel, server = server
            task = Task {
                let response = await server.handle(request)
                do {
                    var outputHeaders = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
                    outputHeaders.replaceOrAdd(name: "Connection", value: "close")
                    outputHeaders.replaceOrAdd(name: "Cache-Control", value: "no-store")
                    let output = HTTPResponseHead(version: .http1_1, status: .init(statusCode: response.statusCode), headers: outputHeaders)
                    try await channel.writeAndFlush(HTTPServerResponsePart.head(output)).get()
                    if case .stream(let stream, _) = response {
                        for try await data in stream {
                            try Task.checkCancellation()
                            try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: data)))).get()
                        }
                    } else if let data = response.bodyData {
                        try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: data)))).get()
                    }
                    try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
                } catch { /* Disconnecting a client does not cancel an already submitted edit. */ }
                try? await channel.close()
            }
        }
    }
}
