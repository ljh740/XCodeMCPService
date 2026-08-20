import Foundation
import MCP

struct LLDBToolResponse: Sendable {
    var content: [Tool.Content]
    var isError: Bool?
}

protocol LLDBMCPClient: Actor, Sendable {
    func start() async throws
    func stop() async
    func isRunning() async -> Bool
    func listTools() async throws -> [Tool]
    func callTool(name: String, arguments: [String: Value]?) async throws -> LLDBToolResponse
    func listResources() async throws -> [Resource]
    func readResource(uri: String) async throws -> [Resource.Content]
}

typealias LLDBMCPClientFactory = @Sendable (XcodeRuntime) -> any LLDBMCPClient

actor StdioLLDBMCPClient: LLDBMCPClient {
    private static let serverName = "lldb"

    private let manager: StdioClientManager

    init(runtime: XcodeRuntime) {
        let config = ServerConfig(
            name: Self.serverName,
            command: "xcrun",
            args: ["lldb-mcp"],
            env: ["DEVELOPER_DIR": runtime.developerDirectoryURL.path]
        )
        manager = StdioClientManager(configs: [config])
    }

    func start() async throws {
        try await manager.startServer(name: Self.serverName)
    }

    func stop() async {
        await manager.stopAll()
    }

    func isRunning() async -> Bool {
        await manager.isServerRunning(name: Self.serverName)
    }

    func listTools() async throws -> [Tool] {
        let client = try await runningClient()
        return try await client.listTools().tools
    }

    func callTool(name: String, arguments: [String: Value]?) async throws -> LLDBToolResponse {
        let client = try await runningClient()
        let result = try await client.callTool(name: name, arguments: arguments)
        return LLDBToolResponse(content: result.content, isError: result.isError)
    }

    func listResources() async throws -> [Resource] {
        let client = try await runningClient()
        return try await client.listResources().resources
    }

    func readResource(uri: String) async throws -> [Resource.Content] {
        let client = try await runningClient()
        return try await client.readResource(uri: uri)
    }

    private func runningClient() async throws -> Client {
        guard await manager.isServerRunning(name: Self.serverName),
              let client = await manager.getClient(name: Self.serverName)
        else {
            throw BridgeError.serverNotFound("LLDB MCP adapter is not running")
        }
        return client
    }
}
