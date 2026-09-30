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
    private let toolTimeouts: [String: Int]
    private let logger: BridgeLogger
    private var runtimeHealthReporter: (any RuntimeHealthReporting)?
    private var deviceLockMonitor: DeviceLockMonitor?
    private var deviceUseGate: any DeviceUseGate = DerivedDataBuildGate()
    /// 查询运行目标的超时，避免拖慢真正的工具调用
    private let destinationLookupTimeoutMs = 3000

    // MARK: - Init

    public init(
        clientManager: any StdioClientManaging,
        aggregator: CapabilityAggregator,
        timeout: Int = 30000,
        toolTimeouts: [String: Int] = BridgeConfig.defaultToolTimeouts,
        runtimeHealthReporter: (any RuntimeHealthReporting)? = nil
    ) {
        self.clientManager = clientManager
        self.aggregator = aggregator
        self.timeout = timeout
        self.toolTimeouts = toolTimeouts
        self.logger = bridgeLogger.child(label: "request-router")
        self.runtimeHealthReporter = runtimeHealthReporter
    }

    public func setRuntimeHealthReporter(_ reporter: (any RuntimeHealthReporting)?) {
        self.runtimeHealthReporter = reporter
    }

    public func setDeviceLockMonitor(
        _ monitor: DeviceLockMonitor?,
        deviceUseGate: any DeviceUseGate = DerivedDataBuildGate()
    ) {
        self.deviceLockMonitor = monitor
        self.deviceUseGate = deviceUseGate
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

        let lockWatch = await startDeviceLockWatch(
            originalToolName: resolved.originalName,
            args: args,
            client: client
        )
        let result = await forwardToolCall(
            resolved: resolved,
            requestedName: toolName,
            args: args,
            client: client
        )
        if let lockWatch {
            lockWatch.cancel()
            if let token = await lockWatch.value, let deviceLockMonitor {
                await deviceLockMonitor.unregister(token)
            }
        }
        return result
    }

    /// 带超时转发 tool 调用到下游 client
    private func forwardToolCall(
        resolved: ResolvedName,
        requestedName toolName: String,
        args: [String: Value]?,
        client: Client
    ) async -> RouteResult<ToolCallResult> {
        let requestGeneration = await currentHealthGeneration(serverName: resolved.serverName)
        let logName = resolved.canonicalName
        let toolTimeout = toolTimeouts[logName] ?? timeout
        let metadata = toolLogMetadata(
            canonicalName: logName,
            requestedName: toolName,
            serverName: resolved.serverName
        )

        // 带超时调用
        do {
            let logger = self.logger
            let result = try await withTimeout(toolTimeout) {
                try await Self.callToolCancellable(client: client, name: resolved.originalName, args: args, logger: logger)
            }
            logger.debug("Tool call succeeded", metadata: metadata)
            return .success(ToolCallResult(content: result.content, isError: result.isError))
        } catch is TimeoutError {
            var timeoutMetadata = metadata
            timeoutMetadata["timeoutMs"] = "\(toolTimeout)"
            logger.error("Tool call timed out", metadata: timeoutMetadata)
            reportTimeout(
                serverName: resolved.serverName,
                operation: "tool:\(logName)",
                generation: requestGeneration
            )
            return .failure(
                code: ErrorCodes.timeout,
                message: "Tool call timed out after \(toolTimeout)ms: \(toolName)"
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

    /// 调用下游 tool；所在任务被取消（客户端取消或超时）时立即结束等待，并通知下游取消该请求。
    ///
    /// SDK 的 `callTool` 等待不响应任务取消，直接使用会一直等到下游自行返回。
    private static func callToolCancellable(
        client: Client,
        name: String,
        args: [String: Value]?,
        logger: BridgeLogger
    ) async throws -> CallTool.Result {
        let context: RequestContext<CallTool.Result> = try await client.callTool(name: name, arguments: args)
        return try await withTaskCancellationHandler {
            try await context.value
        } onCancel: {
            Task {
                do {
                    try await client.cancelRequest(context.requestID, reason: "Request cancelled by bridge")
                } catch {
                    logger.warning("Failed to notify downstream cancellation", metadata: [
                        "tool": name,
                        "error": "\(error)",
                    ])
                }
            }
        }
    }

    // MARK: - Private: Device Lock Watch

    /// 需要真机的工具调用前，查询 Xcode 活跃运行目标与 workspace 路径；目标是真机时，
    /// 返回与调用并行的任务：等到构建完成、Xcode 真正需要设备后才开始关注锁屏状态。
    ///
    /// 查询在转发前完成，避免排在长时间运行的调用之后；返回任务的结果为 `unregister` 用的 token。
    private func startDeviceLockWatch(
        originalToolName: String,
        args: [String: Value]?,
        client: Client
    ) async -> Task<UUID?, Never>? {
        guard let deviceLockMonitor,
            DeviceRunDestination.watchedToolNames.contains(originalToolName)
        else {
            return nil
        }

        let since = Date()
        // 与本次调用指向同一 workspace，才能拿到同一个运行目标
        let workspaceArg = args?["workspaceIdentifier"]
        let listArgs = workspaceArg.map { ["workspaceIdentifier": $0] } ?? [:]
        guard let destinations = await callListTool(DeviceRunDestination.listToolName, args: listArgs, client: client),
            let deviceName = DeviceRunDestination.activePhysicalDeviceName(fromListOutput: destinations)
        else {
            return nil
        }

        // 标识可以直接是路径；否则通过 workspace 列表换算，失败时由 gate 退化为立即关注
        let workspaceIdentifier = workspaceArg?.stringValue
        var workspacePath = workspaceIdentifier.flatMap { $0.hasPrefix("/") ? $0 : nil }
        if workspacePath == nil,
            let workspaces = await callListTool(DeviceRunDestination.listWorkspacesToolName, args: [:], client: client)
        {
            workspacePath = DeviceRunDestination.workspacePath(identifier: workspaceIdentifier, fromListOutput: workspaces)
        }

        logger.debug("Watching device lock state after build completes", metadata: [
            "tool": originalToolName,
            "device": deviceName,
            "workspace": workspacePath ?? "unknown",
        ])
        let gate = deviceUseGate
        return Task { [workspacePath] in
            do {
                try await gate.waitUntilDeviceNeeded(workspacePath: workspacePath, since: since)
            } catch {
                // 只会因调用结束、任务被取消而抛出：构建未完成，无需关注
                return nil
            }
            return await deviceLockMonitor.register(deviceName: deviceName)
        }
    }

    /// 调用上游查询类工具，返回第一段文本；失败或超时返回 nil。
    private func callListTool(_ name: String, args: [String: Value], client: Client) async -> String? {
        do {
            let logger = self.logger
            let result = try await withTimeout(destinationLookupTimeoutMs) {
                try await Self.callToolCancellable(client: client, name: name, args: args, logger: logger)
            }
            guard result.isError != true else { return nil }
            return result.content.lazy.compactMap { content -> String? in
                guard case .text(let text, _, _) = content else { return nil }
                return text
            }.first
        } catch {
            logger.debug("Device lock lookup failed", metadata: [
                "tool": name,
                "error": "\(error)",
            ])
            return nil
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
