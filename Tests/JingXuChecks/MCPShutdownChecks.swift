import Foundation
import JingXuCore
import JingXuAutomation

@MainActor enum MCPShutdownChecks {
    static func run() async throws {
        for index in 0..<100 {
            let server = MCPHTTPServer(port: 0, token: String(repeating: "test", count: 10)) { _, _, _ in AutomationTools.reply([:]) }
            try await server.start()
            guard let port = await server.boundPort else { throw ColorChecks.Failure(description: "未监听") }
            let request = Task {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
                request.httpMethod = "POST"; request.httpBody = Data("{}".utf8); request.timeoutInterval = 2
                _ = try? await URLSession.shared.data(for: request)
            }
            if index % 2 == 0 { try await Task.sleep(for: .milliseconds(3)) }
            async let first: Void = server.stop()
            async let second: Void = server.stop()
            _ = await (first, second)
            await request.value
            try ColorChecks.check(await server.boundPort == nil, "关闭后仍监听")
            try await server.start(); await server.stop()
        }
        try await streaming()
        print("MCP 100 次并发请求／关闭／重启通过（SWIFTNIO_STRICT=1）")
        // stop must also join a bind that has not returned yet.
        let server = MCPHTTPServer(port: 0, token: String(repeating: "test", count: 10)) { _, _, _ in AutomationTools.reply([:]) }
        let startup = Task { try? await server.start() }
        await Task.yield(); await server.stop(); await startup.value; await server.stop()
        try ColorChecks.check(await server.boundPort == nil, "初始化关闭竞争泄漏监听")
    }
    private static func streaming() async throws {
        let token = String(repeating: "test", count: 10)
        let server = MCPHTTPServer(port: 0, token: token) { _, _, _ in AutomationTools.reply([:]) }
        try await server.start()
        guard let port = await server.boundPort else { throw ColorChecks.Failure(description: "未监听") }
        let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
        func request(_ method: String, body: String? = nil, session: String? = nil) -> URLRequest {
            var request = URLRequest(url: endpoint); request.httpMethod = method; request.timeoutInterval = 5
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version")
            request.setValue(session, forHTTPHeaderField: "MCP-Session-Id")
            request.httpBody = body.map { Data($0.utf8) }; return request
        }
        let initialization = request("POST", body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"shutdown-check","version":"1"}}}"#)
        do {
            let (_, response) = try await URLSession.shared.data(for: initialization)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let session = response.value(forHTTPHeaderField: "MCP-Session-Id") else { throw ColorChecks.Failure(description: "流测试初始化失败") }
            _ = try await URLSession.shared.data(for: request("POST", body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#, session: session))
            var opened = false
            let stream = Task {
                let (bytes, response) = try await URLSession.shared.bytes(for: request("GET", session: session))
                try ColorChecks.check((response as? HTTPURLResponse)?.statusCode == 200, "SSE 流未打开")
                opened = true
                for try await _ in bytes { try Task.checkCancellation() }
            }
            for _ in 0..<500 { if opened { break }; try await Task.sleep(for: .milliseconds(10)) }
            guard opened else { stream.cancel(); _ = await stream.result; throw ColorChecks.Failure(description: "SSE 等待超时") }
            await server.beginShutdown()
            await server.stop(); _ = await stream.result
        } catch { await server.stop(); throw error }
    }

}
