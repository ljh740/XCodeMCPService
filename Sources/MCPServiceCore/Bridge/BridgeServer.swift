import Foundation
import MCP

// MARK: - BridgeServer

/// MCP 桥接服务器 Facade，串联所有组件实现完整的 MCP 桥接功能。
///
/// 按顺序启动：配置加载 → 子进程管理 → 能力聚合 → 请求路由 → HTTP 服务 → 生命周期监控。
/// 关闭时按逆序清理所有资源。
public actor BridgeServer {

    // MARK: - Constants

    private let version = "1.0.6"

    /// initialize 响应中的 server instructions。
    ///
    /// 只描述 bridge 自身新增的能力：LLDB 工具组既不存在于上游 Xcode MCP，
    /// 也不在 Xcode 注入宿主提示词的 AgentSystemPromptAddition 模板中，
    /// 因此除本 bridge 外没有任何地方会说明它们。
    ///
    /// 上游 Xcode 工具的用法引导由 Apple 的模板和宿主侧提示词负责，此处不重复。
    /// 在 tool search 的 deferred 模式下该字段会常驻模型上下文，保持精简。
    static let serverInstructions = """
        Bridges the local Xcode MCP server for the currently selected Xcode installation, \
        and adds LLDB debugging tools that the Xcode server does not provide.

        LLDB tools reach debug sessions in the running Xcode: lldb__sessions_list enumerates \
        them, lldb__command runs a command against one. If an expected session is missing, \
        call lldb_refresh_sessions first. lldb__session_create and lldb__session_close depend \
        on the selected Xcode's lldb-mcp and may report the capability as unavailable; \
        sessions attached from Xcode still work.
        """

    // MARK: - Properties

    private let configPath: String?
    private let configManager: ConfigManager

    private var clientManager: StdioClientManager?
    private var aggregator: CapabilityAggregator?
    private var router: RequestRouter?
    private var httpServer: HTTPServer?
    private var lifecycleManager: ProcessLifecycleManager?

    private var running = false
    private let logger: BridgeLogger

    /// 生命周期事件回调，供上层（BridgeManager）监听重连状态
    private var onLifecycleEvent: (@Sendable (LifecycleEvent) -> Void)?

    // MARK: - Init

    public init(configPath: String? = nil) {
        self.configPath = configPath
        self.configManager = ConfigManager()
        self.logger = bridgeLogger.child(label: "bridge-server")
    }

    // MARK: - Public API

    /// 服务器是否正在运行
    public var isRunning: Bool { running }

    /// 设置生命周期事件回调
    public func setLifecycleEventHandler(_ handler: (@Sendable (LifecycleEvent) -> Void)?) {
        self.onLifecycleEvent = handler
    }

    /// 启动桥接服务器
    ///
    /// 按顺序执行：加载配置 → 启动子进程 → 聚合能力 → 创建路由 → 启动 HTTP → 监控进程
    public func start() async throws {
        // 1. 加载配置
        let config = try await configManager.loadConfig(from: configPath)
        logger.info("Configuration loaded", metadata: [
            "port": "\(config.bridge.port)",
            "host": config.bridge.host,
        ])

        // 2. 获取 enabled servers
        let enabledServers = try await configManager.getEnabledServers()
        guard !enabledServers.isEmpty else {
            throw BridgeError.configError("No enabled servers found in configuration")
        }
        logger.info("Enabled servers", metadata: ["count": "\(enabledServers.count)"])

        // 3. 创建 StdioClientManager 并启动所有子进程
        let clientManager = StdioClientManager(configs: enabledServers)
        self.clientManager = clientManager
        do {
            try await clientManager.startAll()
        } catch {
            await clientManager.stopAll()
            self.clientManager = nil
            throw error
        }

        // 4. 创建 CapabilityAggregator 并刷新
        let aggregator = CapabilityAggregator(
            clientManager: clientManager,
            capabilityRequestTimeoutMs: config.bridge.capabilityTimeout
        )
        let capabilitySummary = await aggregator.refresh()
        self.aggregator = aggregator

        guard capabilitySummary.hasSuccessfulFetch else {
            let failureDetails = capabilitySummary.failures
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "; ")
            await clientManager.stopAll()
            self.aggregator = nil
            self.clientManager = nil
            throw BridgeError.internalError(
                "All capability requests failed\(failureDetails.isEmpty ? "" : ": \(failureDetails)")"
            )
        }

        // 5. 日志输出聚合结果
        let tools = await aggregator.getAggregatedTools()
        let resources = await aggregator.getAggregatedResources()
        let prompts = await aggregator.getAggregatedPrompts()
        logger.info("Capabilities aggregated", metadata: [
            "tools": "\(tools.count)",
            "resources": "\(resources.count)",
            "prompts": "\(prompts.count)",
        ])

        // 6. 创建 RequestRouter
        let router = RequestRouter(
            clientManager: clientManager,
            aggregator: aggregator,
            timeout: config.bridge.timeout
        )
        self.router = router

        // 7. 创建 HTTPServer
        let httpServer = HTTPServer(
            port: config.bridge.port,
            host: config.bridge.host,
            responseTimeoutMs: config.bridge.timeout + HTTPServer.responseTimeoutGraceMs
        )
        self.httpServer = httpServer

        // 8. 设置 mcpServerFactory — 闭包 capture local let 避免 actor self 逃逸
        let serverVersion = version
        let serverInstructions = Self.serverInstructions
        let lldbDeveloperDirectoryOverride = enabledServers.first(where: { server in
            URL(fileURLWithPath: server.command).lastPathComponent == "xcrun"
                && server.args.first == "mcpbridge"
        })?.env?["DEVELOPER_DIR"]
        let factory: McpServerFactory = { [aggregator, router] in
            let lldbController = LLDBSessionController(
                developerDirectoryOverride: lldbDeveloperDirectoryOverride
            )
            let server = Server(
                name: "mcp-forward-bridge",
                version: serverVersion,
                instructions: serverInstructions,
                capabilities: .init(
                    prompts: .init(),
                    resources: .init(),
                    tools: .init()
                )
            )
            await BridgeServer.registerHandlers(
                on: server,
                aggregator: aggregator,
                router: router,
                lldbController: lldbController
            )
            return McpServerSession(
                server: server,
                onClose: {
                    await lldbController.shutdown()
                }
            )
        }
        await httpServer.setMcpServerFactory(factory)

        // 9. 启动 HTTP 服务器
        do {
            try await httpServer.start()
        } catch {
            await httpServer.stop()
            await clientManager.stopAll()
            self.httpServer = nil
            self.router = nil
            self.aggregator = nil
            self.clientManager = nil
            throw error
        }
        logger.info("HTTP server started", metadata: [
            "port": "\(config.bridge.port)",
            "host": config.bridge.host,
        ])

        // 10. 创建 ProcessLifecycleManager 并监控
        let policy = RestartPolicy()
        let lifecycleLogger = logger
        let eventHandler = self.onLifecycleEvent
        let callbacks = LifecycleCallbacks(
            onRestarting: { name, attempt in
                lifecycleLogger.info("Server restarting", metadata: [
                    "server": name,
                    "attempt": "\(attempt)",
                ])
                eventHandler?(.serverRestarting(name: name, attempt: attempt))
            },
            onRestarted: { [aggregator] name in
                lifecycleLogger.info("Server restarted, refreshing capabilities", metadata: [
                    "server": name,
                ])
                Task {
                    let summary = await aggregator.refresh()
                    if summary.hasSuccessfulFetch(for: name) {
                        eventHandler?(.serverRestarted(name: name))
                    } else {
                        let failure = summary.failures
                            .filter { $0.key.hasPrefix("\(name)/") }
                            .sorted(by: { $0.key < $1.key })
                            .map { "\($0.key): \($0.value)" }
                            .joined(separator: "; ")
                        eventHandler?(.serverRestartFailed(
                            name: name,
                            error: "Capability refresh failed\(failure.isEmpty ? "" : ": \(failure)")"
                        ))
                    }
                }
            },
            onRestartFailed: { name, error in
                lifecycleLogger.error("Server restart failed", metadata: [
                    "server": name,
                    "error": "\(error)",
                ])
                eventHandler?(.serverRestartFailed(name: name, error: "\(error)"))
            },
            onMaxRestartsReached: { [aggregator] name in
                lifecycleLogger.error("Max restarts reached, server permanently down", metadata: [
                    "server": name,
                ])
                Task { await aggregator.refresh() }
                eventHandler?(.serverPermanentlyDown(name: name))
            },
            onHangDetected: { name in
                lifecycleLogger.warning("Server hang detected", metadata: [
                    "server": name,
                ])
                eventHandler?(.serverHangDetected(name: name))
            },
            onHealthCheckFailed: { name, failures in
                lifecycleLogger.warning("Health check failed", metadata: [
                    "server": name,
                    "consecutiveFailures": "\(failures)",
                ])
            }
        )
        let lifecycleManager = ProcessLifecycleManager(
            clientManager: clientManager,
            policy: policy,
            callbacks: callbacks
        )
        await clientManager.setServerExitHandler { name in
            Task {
                await lifecycleManager.handleCrash(serverName: name)
            }
        }
        await router.setRuntimeHealthReporter(lifecycleManager)
        await lifecycleManager.monitorAll()
        self.lifecycleManager = lifecycleManager

        // 11. 标记运行中
        running = true
        logger.info("BridgeServer started successfully")
    }

    /// 停止桥接服务器，按逆序清理所有资源
    public func stop() async {
        logger.info("BridgeServer stopping...")

        // 1. 生命周期管理器
        if let lifecycleManager {
            await lifecycleManager.gracefulShutdownAll()
            await lifecycleManager.dispose()
        }

        // 2. HTTP 服务器
        if let httpServer {
            await httpServer.stop()
        }

        // 3. 子进程管理器
        if let clientManager {
            await clientManager.stopAll()
        }

        // 4. 清空所有引用
        self.lifecycleManager = nil
        self.httpServer = nil
        self.router = nil
        self.aggregator = nil
        self.clientManager = nil

        // 5. 标记停止
        running = false
        logger.info("BridgeServer stopped")
    }

    // MARK: - Handler Registration

    /// 在 MCP Server 上注册所有 handler
    private static func registerHandlers(
        on server: Server,
        aggregator: CapabilityAggregator,
        router: RequestRouter,
        lldbController: LLDBSessionController
    ) async {
        // ListTools
        await server.withMethodHandler(ListTools.self) { _ in
            let lldbTools = LLDBSessionController.advertisedTools()
            let reservedToolNames = Set(lldbTools.map(\.name))
            let tools = await aggregator.getAggregatedTools()
                .filter { !reservedToolNames.contains($0.name) }
            return ListTools.Result(
                tools: tools.map { tool in
                    Tool(
                        name: tool.name,
                        description: tool.description,
                        inputSchema: tool.inputSchema
                    )
                } + lldbTools
            )
        }

        // CallTool
        await server.withMethodHandler(CallTool.self) { params in
            if let lldbResult = await lldbController.routeToolCall(
                toolName: params.name,
                args: params.arguments
            ) {
                guard lldbResult.success, let data = lldbResult.data else {
                    throw MCPError.internalError(lldbResult.error?.message ?? "LLDB tool call failed")
                }
                return CallTool.Result(content: data.content, isError: data.isError)
            }

            let result = await router.routeToolCall(
                toolName: params.name,
                args: params.arguments
            )
            guard result.success, let data = result.data else {
                throw MCPError.internalError(result.error?.message ?? "Tool call failed")
            }
            return CallTool.Result(content: data.content, isError: data.isError)
        }

        // ListResources
        await server.withMethodHandler(ListResources.self) { _ in
            async let lldbResources = lldbController.listResources()
            let resources = await aggregator.getAggregatedResources()
            let serviceResources = await lldbResources
            return ListResources.Result(
                resources: resources.map { resource in
                    Resource(
                        name: resource.name ?? resource.uri,
                        uri: resource.uri,
                        description: resource.description,
                        mimeType: resource.mimeType
                    )
                } + serviceResources
            )
        }

        // ReadResource
        await server.withMethodHandler(ReadResource.self) { params in
            if let lldbResult = await lldbController.routeResourceRead(prefixedURI: params.uri) {
                guard lldbResult.success, let data = lldbResult.data else {
                    throw MCPError.internalError(lldbResult.error?.message ?? "LLDB resource read failed")
                }
                return ReadResource.Result(contents: data.contents)
            }

            let result = await router.routeResourceRead(prefixedUri: params.uri)
            guard result.success, let data = result.data else {
                throw MCPError.internalError(result.error?.message ?? "Resource read failed")
            }
            return ReadResource.Result(contents: data.contents)
        }

        // ListPrompts
        await server.withMethodHandler(ListPrompts.self) { _ in
            let prompts = await aggregator.getAggregatedPrompts()
            return ListPrompts.Result(
                prompts: prompts.map { prompt in
                    Prompt(
                        name: prompt.name,
                        description: prompt.description,
                        arguments: prompt.arguments
                    )
                }
            )
        }

        // GetPrompt
        await server.withMethodHandler(GetPrompt.self) { params in
            let result = await router.routePromptGet(
                prefixedName: params.name,
                args: params.arguments
            )
            guard result.success, let data = result.data else {
                throw MCPError.internalError(result.error?.message ?? "Prompt get failed")
            }
            return GetPrompt.Result(description: data.description, messages: data.messages)
        }
    }
}
