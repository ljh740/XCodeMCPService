import Foundation
import MCP
import Network
import os

// MARK: - Types

/// MCP Server 工厂闭包，每个会话创建独立的 Server 实例
public typealias McpServerFactory = @Sendable () async -> Server

// MARK: - HTTPServer

/// MCP Streamable HTTP Transport 服务器
///
/// 基于 `NWListener` 实现的轻量 HTTP 服务器，提供单一 `/mcp` endpoint。
/// 每个会话通过 `InMemoryTransport` 连接到独立的 MCP Server 实例。
public actor HTTPServer {
    static let responseTimeoutGraceMs = 5_000

    let port: Int
    let host: String
    let endpoint: String
    let responseTimeoutMs: Int

    /// MCP Server 工厂，由外部设置以注入 handler 配置
    var mcpServerFactory: McpServerFactory?

    /// 设置 MCP Server 工厂闭包
    public func setMcpServerFactory(_ factory: McpServerFactory?) {
        self.mcpServerFactory = factory
    }

    private var listener: NWListener?
    let sessionManager = SessionManager()

    let logger = BridgeLogger(label: "mcp-forward.http")

    // MARK: - Init

    public init(
        port: Int,
        host: String = "127.0.0.1",
        endpoint: String = "/mcp",
        responseTimeoutMs: Int = 35_000
    ) {
        self.port = port
        self.host = host
        self.endpoint = endpoint
        self.responseTimeoutMs = responseTimeoutMs
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

        let requestStart = ContinuousClock.now

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

            let elapsed = ContinuousClock.now - requestStart
            logger.info("Request completed", metadata: [
                "method": request.method,
                "path": request.path,
                "status": "\(response.statusCode)",
                "elapsedMs": "\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)",
                "clientIP": clientIP ?? "unknown",
            ])

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

    // MARK: - Session Cleanup

    /// 获取当前活跃会话数量
    public func getSessionCount() async -> Int {
        await sessionManager.getSessionCount()
    }
}
