import Foundation
import MCP
import Security

// MARK: - SessionInfo

/// HTTP 会话信息，持有 MCP Server 和对应的 InMemoryTransport
public struct SessionInfo: Sendable {
    /// 该会话的 MCP Server 实例
    public let server: Server
    /// 用于向 server 发送消息的 client 端 transport
    public let clientTransport: InMemoryTransport
    /// 响应队列，管理 transport 的 receive stream
    let responseQueue: ResponseQueue
    /// 会话创建时间
    public let createdAt: Date
}

// MARK: - SessionManager

/// 管理 HTTP 会话的生命周期
actor SessionManager {
    private var sessions: [String: SessionInfo] = [:]
    private let logger = BridgeLogger(label: "mcp-forward.session")

    /// 获取所有活跃会话 ID
    func getActiveSessionIds() -> [String] {
        Array(sessions.keys)
    }

    /// 获取会话数量
    func getSessionCount() -> Int {
        sessions.count
    }

    /// 查找会话
    func getSession(id: String) -> SessionInfo? {
        sessions[id]
    }

    /// 创建新会话
    func createSession(factory: McpServerFactory) async throws -> (String, SessionInfo) {
        let sessionId = Self.generateSecureToken()
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await factory()

        try await clientTransport.connect()
        try await server.start(transport: serverTransport)

        let responseQueue = ResponseQueue(logger: logger.child(label: "response-queue"))
        await responseQueue.start(transport: clientTransport)

        let session = SessionInfo(
            server: server,
            clientTransport: clientTransport,
            responseQueue: responseQueue,
            createdAt: Date()
        )
        sessions[sessionId] = session

        logger.info("Session created", metadata: ["sessionId": sessionId])
        return (sessionId, session)
    }

    /// 关闭指定会话
    func closeSession(id: String) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.responseQueue.stop()
        await session.server.stop()
        await session.clientTransport.disconnect()
        logger.info("Session closed", metadata: ["sessionId": id])
    }

    /// 关闭所有会话
    func closeAll() async {
        let sessionIds = Array(sessions.keys)
        for id in sessionIds {
            await closeSession(id: id)
        }
    }

    // MARK: - Private

    /// 生成加密安全的 session token（32 字节，base64url 编码，256 位熵）
    private static func generateSecureToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
