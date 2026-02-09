import Foundation
import MCP
import Network
import os

// MARK: - Types

/// MCP Server 工厂闭包，每个会话创建独立的 Server 实例
public typealias McpServerFactory = @Sendable () async -> Server

// MARK: - ResponseQueue

/// 管理单个 session 的响应流，将 InMemoryTransport 的 receive stream
/// 转换为可被多个请求消费的队列。
///
/// Session 创建时启动后台 Task 持续读取 transport 消息，
/// 每个 `waitForNext()` 调用按 FIFO 顺序获取下一条响应。
actor ResponseQueue {
    /// Waiter entry with unique ID to safely handle timeout cancellation
    private struct WaiterEntry {
        let id: UUID
        let continuation: CheckedContinuation<Data, Error>
    }

    private var waiters: [WaiterEntry] = []
    private var buffered: [Data] = []
    private var readTask: Task<Void, Never>?
    private let maxBufferSize = 1000
    private var droppedCount = 0

    /// 启动后台读取循环
    func start(transport: InMemoryTransport) {
        readTask = Task { [weak self] in
            let stream = await transport.receive()
            do {
                for try await data in stream {
                    guard !Task.isCancelled else { break }
                    await self?.enqueue(data)
                }
            } catch {
                await self?.cancelAll(error: error)
            }
        }
    }

    /// 停止读取
    func stop() {
        readTask?.cancel()
        readTask = nil
        let pending = waiters
        waiters.removeAll()
        for entry in pending {
            entry.continuation.resume(throwing: BridgeError.internalError("Session closed"))
        }
        // Clear buffer
        buffered.removeAll()
    }

    /// 获取队列指标（用于诊断）
    func getMetrics() -> (buffered: Int, dropped: Int) {
        (buffered: buffered.count, dropped: droppedCount)
    }

    /// 等待下一条响应
    func waitForNext(timeoutSeconds: Int) async throws -> Data {
        // 先检查缓冲区
        if !buffered.isEmpty {
            return buffered.removeFirst()
        }

        let waiterId = UUID()

        return try await withCheckedThrowingContinuation { continuation in
            let entry = WaiterEntry(id: waiterId, continuation: continuation)
            waiters.append(entry)

            // 超时任务
            Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                self.timeoutWaiter(id: waiterId, timeoutSeconds: timeoutSeconds)
            }
        }
    }

    // MARK: - Private

    /// 超时处理：安全移除并 resume waiter
    private func timeoutWaiter(id: UUID, timeoutSeconds: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return // Already consumed by enqueue
        }
        let entry = waiters.remove(at: index)
        entry.continuation.resume(throwing: BridgeError.timeout(
            "MCP server did not respond within \(timeoutSeconds)s",
            timeoutMs: timeoutSeconds * 1000))
    }

    private func enqueue(_ data: Data) {
        if !waiters.isEmpty {
            let entry = waiters.removeFirst()
            entry.continuation.resume(returning: data)
        } else {
            if buffered.count >= maxBufferSize {
                // Drop oldest message
                buffered.removeFirst()
                droppedCount += 1
            }
            buffered.append(data)
        }
    }

    private func cancelAll(error: Error) {
        let pending = waiters
        waiters.removeAll()
        for entry in pending {
            entry.continuation.resume(throwing: error)
        }
    }
}

// MARK: - HTTPServer

/// MCP Streamable HTTP Transport 服务器
///
/// 基于 `NWListener` 实现的轻量 HTTP 服务器，提供单一 `/mcp` endpoint。
/// 每个会话通过 `InMemoryTransport` 连接到独立的 MCP Server 实例。
public actor HTTPServer {
    private let port: Int
    private let host: String
    private let endpoint: String

    /// MCP Server 工厂，由外部设置以注入 handler 配置
    public var mcpServerFactory: McpServerFactory?

    /// 设置 MCP Server 工厂闭包
    public func setMcpServerFactory(_ factory: McpServerFactory?) {
        self.mcpServerFactory = factory
    }

    private var listener: NWListener?
    private let sessionManager = SessionManager()

    private let logger = BridgeLogger(label: "mcp-forward.http")

    // MARK: - Init

    public init(
        port: Int,
        host: String = "127.0.0.1",
        endpoint: String = "/mcp"
    ) {
        self.port = port
        self.host = host
        self.endpoint = endpoint
    }

    // MARK: - Lifecycle

    /// 启动 HTTP 服务器
    public func start() async throws {
        guard mcpServerFactory != nil else {
            throw BridgeError.configError("mcpServerFactory must be set before starting HTTPServer")
        }

        let params: NWParameters = .tcp
        let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: UInt16(port)))

        // 绑定到指定 host（统一路径，包括 0.0.0.0）
        listener.parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: UInt16(port))
        )

        self.listener = listener

        // 使用 continuation 等待 listener 就绪
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)

            listener.stateUpdateHandler = { [logger] state in
                let alreadyResumed = resumed.withLock { value -> Bool in
                    if value { return true }
                    value = true
                    return false
                }
                guard !alreadyResumed else { return }

                switch state {
                case .ready:
                    logger.info("HTTP server listening", metadata: [
                        "host": self.host,
                        "port": String(self.port),
                        "endpoint": self.endpoint,
                    ])
                    continuation.resume()
                case .failed(let error):
                    logger.error("HTTP server failed to start", metadata: ["error": "\(error)"])
                    continuation.resume(throwing: error)
                case .cancelled:
                    continuation.resume(
                        throwing: BridgeError.internalError("Listener cancelled during startup"))
                default:
                    // 未就绪，重置标志以等待后续状态
                    resumed.withLock { $0 = false }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                Task {
                    await self.handleConnection(connection)
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// 停止 HTTP 服务器，关闭所有会话
    public func stop() async {
        listener?.cancel()
        listener = nil

        // 关闭所有活跃会话
        await sessionManager.closeAll()

        logger.info("HTTP server stopped")
    }

    // MARK: - Session Management

    /// 获取所有活跃会话 ID
    public func getActiveSessionIds() async -> [String] {
        await sessionManager.getActiveSessionIds()
    }

    /// 关闭指定会话
    public func closeSession(id: String) async {
        await sessionManager.closeSession(id: id)
    }

    // MARK: - Connection Handling

    /// 处理新的 TCP 连接
    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, logger] state in
            switch state {
            case .ready:
                Task { [weak self] in
                    await self?.receiveHTTPRequest(on: connection)
                }
            case .failed(let error):
                logger.error("Connection failed", metadata: ["error": "\(error)"])
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    /// 从连接中接收并处理 HTTP 请求
    private func receiveHTTPRequest(on connection: NWConnection) async {
        // 提取客户端 IP
        let clientIP: String? = {
            guard let endpoint = connection.currentPath?.remoteEndpoint else { return nil }
            switch endpoint {
            case .hostPort(let host, _):
                return "\(host)"
            default:
                return nil
            }
        }()

        do {
            let data = try await TCPConnectionHelper.receiveAllData(on: connection)
            let parsed = try HTTPParser.parseHTTPRequest(data)
            // 附加 clientIP
            let request = HTTPRequest(
                method: parsed.method,
                path: parsed.path,
                headers: parsed.headers,
                body: parsed.body,
                clientIP: clientIP
            )
            let response = await routeRequest(request)
            let rawResponse = HTTPParser.serializeHTTPResponse(response)
            try await TCPConnectionHelper.sendData(rawResponse, on: connection)
        } catch {
            logger.error("Request handling error", metadata: ["error": "\(error)"])
            let errorResponse = HTTPResponse(
                statusCode: 500,
                statusText: "Internal Server Error",
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"internal server error"}"#.utf8)
            )
            let raw = HTTPParser.serializeHTTPResponse(errorResponse)
            try? await TCPConnectionHelper.sendData(raw, on: connection)
        }
        connection.cancel()
    }

    // MARK: - Request Routing

    /// 路由 HTTP 请求到对应处理逻辑
    private func routeRequest(_ request: HTTPRequest) async -> HTTPResponse {
        // 检查路径
        guard request.path == endpoint || request.path.hasPrefix(endpoint + "?") else {
            return HTTPResponse(
                statusCode: 404,
                statusText: "Not Found",
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"not found"}"#.utf8)
            )
        }

        switch request.method {
        case "POST":
            return await handlePost(request)
        case "DELETE":
            return await handleDelete(request)
        case "GET":
            // SSE 暂不支持
            return HTTPResponse(
                statusCode: 405,
                statusText: "Method Not Allowed",
                headers: [
                    "Content-Type": "application/json",
                    "Allow": "POST, DELETE",
                ],
                body: Data(#"{"error":"GET not supported, SSE not implemented"}"#.utf8)
            )
        default:
            return HTTPResponse(
                statusCode: 405,
                statusText: "Method Not Allowed",
                headers: [
                    "Content-Type": "application/json",
                    "Allow": "POST, DELETE",
                ],
                body: Data(#"{"error":"method not allowed"}"#.utf8)
            )
        }
    }

    // MARK: - POST Handler

    /// 处理 POST 请求：发送 JSON-RPC 到 MCP Server，等待响应
    private func handlePost(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body, !body.isEmpty else {
            return HTTPResponse(
                statusCode: 400,
                statusText: "Bad Request",
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"empty request body"}"#.utf8)
            )
        }

        // 确定会话
        let sessionId: String
        let session: SessionInfo

        if let existingId = request.headers["mcp-session-id"],
            let existingSession = await sessionManager.getSession(id: existingId)
        {
            // 已有会话
            sessionId = existingId
            session = existingSession
        } else {
            // 创建新会话
            guard let factory = mcpServerFactory else {
                return HTTPResponse(
                    statusCode: 500,
                    statusText: "Internal Server Error",
                    headers: ["Content-Type": "application/json"],
                    body: Data(#"{"error":"mcpServerFactory not set"}"#.utf8)
                )
            }
            do {
                let (newId, newSession) = try await sessionManager.createSession(
                    factory: factory)
                sessionId = newId
                session = newSession
            } catch {
                logger.error("Failed to create session", metadata: ["error": "\(error)"])
                return HTTPResponse(
                    statusCode: 500,
                    statusText: "Internal Server Error",
                    headers: ["Content-Type": "application/json"],
                    body: Data(
                        #"{"error":"failed to create session: \#(error.localizedDescription)"}"#
                            .utf8)
                )
            }
        }

        // 检测是否为 notification（没有 "id" 字段的 JSON-RPC 消息）
        let isNotification = HTTPParser.isJSONRPCNotification(body)

        // 通过 clientTransport 发送 JSON-RPC 消息给 MCP Server
        do {
            try await session.clientTransport.send(body)
        } catch {
            logger.error("Failed to send to MCP server", metadata: [
                "sessionId": sessionId, "error": "\(error)",
            ])
            return HTTPResponse(
                statusCode: 502,
                statusText: "Bad Gateway",
                headers: [
                    "Content-Type": "application/json",
                    "Mcp-Session-Id": sessionId,
                ],
                body: Data(#"{"error":"failed to send to MCP server"}"#.utf8)
            )
        }

        // Notification 不需要等待响应，直接返回 202 Accepted
        if isNotification {
            return HTTPResponse(
                statusCode: 202,
                statusText: "Accepted",
                headers: [
                    "Content-Type": "application/json",
                    "Mcp-Session-Id": sessionId,
                ],
                body: nil
            )
        }

        // 等待 MCP Server 响应（通过 ResponseQueue 接收）
        do {
            let responseData = try await session.responseQueue.waitForNext(timeoutSeconds: 30)
            return HTTPResponse(
                statusCode: 200,
                statusText: "OK",
                headers: [
                    "Content-Type": "application/json",
                    "Mcp-Session-Id": sessionId,
                ],
                body: responseData
            )
        } catch {
            logger.error("Timeout or error waiting for MCP response", metadata: [
                "sessionId": sessionId, "error": "\(error)",
            ])
            return HTTPResponse(
                statusCode: 504,
                statusText: "Gateway Timeout",
                headers: [
                    "Content-Type": "application/json",
                    "Mcp-Session-Id": sessionId,
                ],
                body: Data(#"{"error":"MCP server response timeout"}"#.utf8)
            )
        }
    }

    // MARK: - DELETE Handler

    /// 处理 DELETE 请求：关闭会话
    private func handleDelete(_ request: HTTPRequest) async -> HTTPResponse {
        guard let sessionId = request.headers["mcp-session-id"] else {
            return HTTPResponse(
                statusCode: 400,
                statusText: "Bad Request",
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"missing Mcp-Session-Id header"}"#.utf8)
            )
        }

        guard await sessionManager.getSession(id: sessionId) != nil else {
            return HTTPResponse(
                statusCode: 404,
                statusText: "Not Found",
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"session not found"}"#.utf8)
            )
        }

        await sessionManager.closeSession(id: sessionId)

        return HTTPResponse(
            statusCode: 200,
            statusText: "OK",
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"status":"session closed"}"#.utf8)
        )
    }

    // MARK: - Session Cleanup

    /// 获取当前活跃会话数量
    public func getSessionCount() async -> Int {
        await sessionManager.getSessionCount()
    }

}
