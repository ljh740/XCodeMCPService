import Foundation
import MCP

// MARK: - Result Types

/// Tool 调用结果
public struct ToolCallResult: Sendable {
    public let content: [Tool.Content]
    public let isError: Bool?
}

/// Resource 读取结果
public struct ResourceReadResult: Sendable {
    public let contents: [Resource.Content]
}

/// Prompt 获取结果
public struct PromptGetResult: Sendable {
    public let description: String?
    public let messages: [Prompt.Message]
}

// MARK: - TimeoutError

/// 超时错误
private struct TimeoutError: Error {}

// MARK: - RequestRouter

/// 将请求路由到正确的下游 MCP 服务器。
/// 解析前缀名称，找到目标服务器，通过 MCP Client 转发请求并返回结果。
public actor RequestRouter {
    // MARK: - Properties

    private let clientManager: any StdioClientManaging
    private let aggregator: CapabilityAggregator
    private let timeout: Int
    private let logger: BridgeLogger
    private var runtimeHealthReporter: (any RuntimeHealthReporting)?

    // MARK: - Init

    public init(
        clientManager: any StdioClientManaging,
        aggregator: CapabilityAggregator,
        timeout: Int = 30000,
        runtimeHealthReporter: (any RuntimeHealthReporting)? = nil
    ) {
        self.clientManager = clientManager
        self.aggregator = aggregator
        self.timeout = timeout
        self.logger = bridgeLogger.child(label: "request-router")
        self.runtimeHealthReporter = runtimeHealthReporter
    }

    public func setRuntimeHealthReporter(_ reporter: (any RuntimeHealthReporting)?) {
        self.runtimeHealthReporter = reporter
    }

    // MARK: - Route: Tool Call

    /// 路由 tool 调用到对应的下游服务器
    public func routeToolCall(
        toolName: String,
        args: [String: Value]?
    ) async -> RouteResult<ToolCallResult> {
        let resolution = await aggregator.resolveTool(toolName: toolName)
        let resolved: ResolvedName
        switch resolution {
        case .resolved(let value):
            resolved = value
        case .ambiguous(let message):
            logger.warning(message)
            return .failure(
                code: ErrorCodes.invalidParams,
                message: message
            )
        case .notFound:
            logger.warning("Tool not found: \(toolName)")
            return .failure(
                code: ErrorCodes.methodNotFound,
                message: "Tool not found: \(toolName)"
            )
        }

        // 获取 client
        guard let client = await getRunningClient(serverName: resolved.serverName) else {
            return .failure(
                code: ErrorCodes.serverNotFound,
                message: "Server not running: \(resolved.serverName)"
            )
        }
        let requestGeneration = await currentHealthGeneration(serverName: resolved.serverName)
        let logName = resolved.canonicalName
        let metadata = toolLogMetadata(
            canonicalName: logName,
            requestedName: toolName,
            serverName: resolved.serverName
        )

        // 带超时调用
        do {
            let result = try await withTimeout(timeout) {
                try await client.callTool(name: resolved.originalName, arguments: args)
            }
            logger.debug("Tool call succeeded", metadata: metadata)
            return .success(ToolCallResult(content: result.content, isError: result.isError))
        } catch is TimeoutError {
            var timeoutMetadata = metadata
            timeoutMetadata["timeoutMs"] = "\(timeout)"
            logger.error("Tool call timed out", metadata: timeoutMetadata)
            reportTimeout(
                serverName: resolved.serverName,
                operation: "tool:\(logName)",
                generation: requestGeneration
            )
            return .failure(
                code: ErrorCodes.timeout,
                message: "Tool call timed out after \(timeout)ms: \(toolName)"
            )
        } catch {
            var failureMetadata = metadata
            failureMetadata["error"] = "\(error)"
            logger.error("Tool call failed", metadata: failureMetadata)
            return .failure(
                code: ErrorCodes.bridgeError,
                message: "Tool call failed: \(error)"
            )
        }
    }

    // MARK: - Route: Resource Read

    /// 路由 resource 读取到对应的下游服务器
    public func routeResourceRead(
        prefixedUri: String
    ) async -> RouteResult<ResourceReadResult> {
        guard let resolved = await aggregator.resolveResourceServer(prefixedUri: prefixedUri) else {
            logger.warning("Resource not found: \(prefixedUri)")
            return .failure(
                code: ErrorCodes.methodNotFound,
                message: "Resource not found: \(prefixedUri)"
            )
        }

        guard let client = await getRunningClient(serverName: resolved.serverName) else {
            return .failure(
                code: ErrorCodes.serverNotFound,
                message: "Server not running: \(resolved.serverName)"
            )
        }
        let requestGeneration = await currentHealthGeneration(serverName: resolved.serverName)

        do {
            let contents = try await withTimeout(timeout) {
                try await client.readResource(uri: resolved.originalName)
            }
            logger.debug("Resource read succeeded", metadata: [
                "uri": prefixedUri,
                "server": resolved.serverName,
            ])
            return .success(ResourceReadResult(contents: contents))
        } catch is TimeoutError {
            logger.error("Resource read timed out", metadata: [
                "uri": prefixedUri,
                "server": resolved.serverName,
                "timeoutMs": "\(timeout)",
            ])
            reportTimeout(
                serverName: resolved.serverName,
                operation: "resource:\(prefixedUri)",
                generation: requestGeneration
            )
            return .failure(
                code: ErrorCodes.timeout,
                message: "Resource read timed out after \(timeout)ms: \(prefixedUri)"
            )
        } catch {
            logger.error("Resource read failed", metadata: [
                "uri": prefixedUri,
                "error": "\(error)",
            ])
            return .failure(
                code: ErrorCodes.bridgeError,
                message: "Resource read failed: \(error)"
            )
        }
    }

    // MARK: - Route: Prompt Get

    /// 路由 prompt 获取到对应的下游服务器
    public func routePromptGet(
        prefixedName: String,
        args: [String: String]?
    ) async -> RouteResult<PromptGetResult> {
        guard let resolved = await aggregator.resolvePromptServer(prefixedName: prefixedName) else {
            logger.warning("Prompt not found: \(prefixedName)")
            return .failure(
                code: ErrorCodes.methodNotFound,
                message: "Prompt not found: \(prefixedName)"
            )
        }

        guard let client = await getRunningClient(serverName: resolved.serverName) else {
            return .failure(
                code: ErrorCodes.serverNotFound,
                message: "Server not running: \(resolved.serverName)"
            )
        }
        let requestGeneration = await currentHealthGeneration(serverName: resolved.serverName)

        do {
            let result = try await withTimeout(timeout) {
                try await client.getPrompt(name: resolved.originalName, arguments: args)
            }
            logger.debug("Prompt get succeeded", metadata: [
                "prompt": prefixedName,
                "server": resolved.serverName,
            ])
            return .success(
                PromptGetResult(description: result.description, messages: result.messages))
        } catch is TimeoutError {
            logger.error("Prompt get timed out", metadata: [
                "prompt": prefixedName,
                "server": resolved.serverName,
                "timeoutMs": "\(timeout)",
            ])
            reportTimeout(
                serverName: resolved.serverName,
                operation: "prompt:\(prefixedName)",
                generation: requestGeneration
            )
            return .failure(
                code: ErrorCodes.timeout,
                message: "Prompt get timed out after \(timeout)ms: \(prefixedName)"
            )
        } catch {
            logger.error("Prompt get failed", metadata: [
                "prompt": prefixedName,
                "error": "\(error)",
            ])
            return .failure(
                code: ErrorCodes.bridgeError,
                message: "Prompt get failed: \(error)"
            )
        }
    }

    // MARK: - Private: Client Lookup

    /// 检查服务器运行状态并获取 client
    private func getRunningClient(serverName: String) async -> Client? {
        guard await clientManager.isServerRunning(name: serverName) else {
            logger.warning("Server not running: \(serverName)")
            return nil
        }
        guard let client = await clientManager.getClient(name: serverName) else {
            logger.warning("Client not found for running server: \(serverName)")
            return nil
        }
        return client
    }

    private func currentHealthGeneration(serverName: String) async -> UInt64? {
        guard let runtimeHealthReporter else { return nil }
        return await runtimeHealthReporter.currentHealthGeneration(serverName: serverName)
    }

    private func reportTimeout(serverName: String, operation: String, generation: UInt64?) {
        guard let runtimeHealthReporter else { return }
        Task {
            await runtimeHealthReporter.recordRequestTimeout(
                serverName: serverName,
                operation: operation,
                generation: generation
            )
        }
    }

    private func toolLogMetadata(
        canonicalName: String,
        requestedName: String,
        serverName: String
    ) -> [String: String] {
        var metadata = [
            "tool": canonicalName,
            "server": serverName,
        ]
        if requestedName != canonicalName {
            metadata["requestedTool"] = requestedName
        }
        return metadata
    }

    // MARK: - Private: Timeout

    /// 带超时执行异步操作，使用 TaskGroup 竞争
    private func withTimeout<T: Sendable>(
        _ timeoutMs: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            // 实际操作
            group.addTask {
                try await operation()
            }

            // 超时哨兵
            group.addTask {
                try await Task.sleep(for: .milliseconds(timeoutMs))
                throw TimeoutError()
            }

            // 第一个完成的结果决定胜负
            guard let result = try await group.next() else {
                throw TimeoutError()
            }

            // 取消剩余任务
            group.cancelAll()
            return result
        }
    }
}
