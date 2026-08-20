import Foundation
import MCP

// MARK: - Aggregated Types

/// 聚合后的 Tool。
/// `name` 用于对外暴露，`canonicalName` 用于桥接层内部稳定路由。
public struct AggregatedTool: Sendable {
    /// 对外暴露的名称。单下游时保留原名，多下游时使用 `serverName__originalName`。
    public let name: String
    /// 内部稳定路由键，始终使用 `serverName__originalName`。
    public let canonicalName: String
    public let originalName: String
    public let serverName: String
    public let description: String?
    public let inputSchema: Value
}

/// 聚合后的 Resource，带有服务器名称前缀
public struct AggregatedResource: Sendable {
    /// 带前缀: serverName__originalUri
    public let uri: String
    public let originalUri: String
    public let serverName: String
    public let name: String?
    public let description: String?
    public let mimeType: String?
}

/// 聚合后的 Prompt，带有服务器名称前缀
public struct AggregatedPrompt: Sendable {
    /// 带前缀: serverName__originalName
    public let name: String
    public let originalName: String
    public let serverName: String
    public let description: String?
    public let arguments: [Prompt.Argument]?
}

/// 从带前缀名称解析出的服务器名和原始名
public struct ResolvedName: Sendable {
    public let serverName: String
    public let originalName: String
    public let canonicalName: String
}

enum ToolResolution: Sendable {
    case resolved(ResolvedName)
    case ambiguous(String)
    case notFound
}

/// 一次 capability 聚合的结果，用于区分“空能力”与“所有请求均失败”。
public struct CapabilityRefreshSummary: Sendable, Equatable {
    public let activeServerCount: Int
    public let successfulFetchCount: Int
    public let successfulServers: Set<String>
    public let toolCount: Int
    public let resourceCount: Int
    public let promptCount: Int
    public let failures: [String: String]

    public var hasSuccessfulFetch: Bool { successfulFetchCount > 0 }

    public func hasSuccessfulFetch(for serverName: String) -> Bool {
        successfulServers.contains(serverName)
    }
}

private enum CapabilityFetchResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
}

private struct ServerCapabilityResult: Sendable {
    let serverName: String
    let tools: [AggregatedTool]
    let resources: [AggregatedResource]
    let prompts: [AggregatedPrompt]
    let successfulFetchCount: Int
    let failures: [String: String]
}

// MARK: - CapabilityAggregator

/// 聚合多个下游 MCP 服务器的 capabilities（tools, resources, prompts）。
/// Tool 在多下游场景下添加 `serverName__` 前缀避免冲突，单下游场景下对外暴露原始名称。
public actor CapabilityAggregator {

    private enum ToolNameExposureMode {
        case original
        case namespaced

        static func from(configuredServerCount: Int) -> Self {
            configuredServerCount == 1 ? .original : .namespaced
        }

        func publicName(originalName: String, canonicalName: String) -> String {
            switch self {
            case .original:
                originalName
            case .namespaced:
                canonicalName
            }
        }
    }

    // MARK: - Properties

    private let prefixSeparator = "__"
    private var aggregatedTools: [AggregatedTool] = []
    private var aggregatedResources: [AggregatedResource] = []
    private var aggregatedPrompts: [AggregatedPrompt] = []
    private let clientManager: any StdioClientManaging
    private let capabilityRequestTimeoutMs: Int

    private let logger = bridgeLogger.child(label: "capability-aggregator")

    // MARK: - Init

    public init(
        clientManager: any StdioClientManaging,
        capabilityRequestTimeoutMs: Int = 15000
    ) {
        self.clientManager = clientManager
        self.capabilityRequestTimeoutMs = max(capabilityRequestTimeoutMs, 1)
    }

    // MARK: - Public Query

    /// 获取所有聚合后的 Tools
    public func getAggregatedTools() -> [AggregatedTool] {
        aggregatedTools
    }

    /// 获取所有聚合后的 Resources
    public func getAggregatedResources() -> [AggregatedResource] {
        aggregatedResources
    }

    /// 获取所有聚合后的 Prompts
    public func getAggregatedPrompts() -> [AggregatedPrompt] {
        aggregatedPrompts
    }

    /// 解析 tool 名称，兼容对外暴露名与内部 canonical name。
    public func resolveToolServer(toolName: String) -> ResolvedName? {
        guard case let .resolved(resolved) = resolveTool(toolName: toolName) else {
            return nil
        }
        return resolved
    }

    /// 从带前缀的 resource URI 解析出服务器名和原始 URI
    public func resolveResourceServer(prefixedUri: String) -> ResolvedName? {
        guard let resolved = parsePrefix(prefixedUri),
            aggregatedResources.contains(where: { $0.uri == prefixedUri })
        else {
            return nil
        }
        return resolved
    }

    /// 从带前缀的 prompt 名称解析出服务器名和原始名
    public func resolvePromptServer(prefixedName: String) -> ResolvedName? {
        guard let resolved = parsePrefix(prefixedName),
            aggregatedPrompts.contains(where: { $0.name == prefixedName })
        else {
            return nil
        }
        return resolved
    }

    // MARK: - Refresh

    /// 并发获取所有活跃服务器的 capabilities，跳过失败的服务器
    @discardableResult
    public func refresh() async -> CapabilityRefreshSummary {
        aggregatedTools = []
        aggregatedResources = []
        aggregatedPrompts = []

        let activeServers = await clientManager.getActiveServers()
        let toolNameMode = await currentToolNameExposureMode()

        guard !activeServers.isEmpty else {
            logger.info("No active servers to aggregate")
            return CapabilityRefreshSummary(
                activeServerCount: 0,
                successfulFetchCount: 0,
                successfulServers: [],
                toolCount: 0,
                resourceCount: 0,
                promptCount: 0,
                failures: [:]
            )
        }

        logger.info("Refreshing capabilities from \(activeServers.count) server(s)")

        let results = await withTaskGroup(
            of: ServerCapabilityResult.self,
            returning: [ServerCapabilityResult].self
        ) { group in
            for serverName in activeServers {
                group.addTask {
                    await self.fetchServerCapabilities(
                        serverName: serverName,
                        toolNameMode: toolNameMode
                    )
                }
            }

            var collected: [ServerCapabilityResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // 合并所有结果
        var successfulFetchCount = 0
        var successfulServers: Set<String> = []
        var failures: [String: String] = [:]
        for result in results {
            aggregatedTools.append(contentsOf: result.tools)
            aggregatedResources.append(contentsOf: result.resources)
            aggregatedPrompts.append(contentsOf: result.prompts)
            successfulFetchCount += result.successfulFetchCount
            if result.successfulFetchCount > 0 {
                successfulServers.insert(result.serverName)
            }
            failures.merge(result.failures, uniquingKeysWith: { _, latest in latest })
        }

        logger.info("Aggregated capabilities", metadata: [
            "tools": "\(aggregatedTools.count)",
            "resources": "\(aggregatedResources.count)",
            "prompts": "\(aggregatedPrompts.count)",
            "successfulFetches": "\(successfulFetchCount)",
            "failures": "\(failures.count)",
        ])

        return CapabilityRefreshSummary(
            activeServerCount: activeServers.count,
            successfulFetchCount: successfulFetchCount,
            successfulServers: successfulServers,
            toolCount: aggregatedTools.count,
            resourceCount: aggregatedResources.count,
            promptCount: aggregatedPrompts.count,
            failures: failures
        )
    }

    // MARK: - Private: Fetch

    /// 获取单个服务器的 capabilities，任一类别失败则 warn 并跳过该类别
    private func fetchServerCapabilities(
        serverName: String,
        toolNameMode: ToolNameExposureMode
    ) async -> ServerCapabilityResult {
        guard let client = await clientManager.getClient(name: serverName) else {
            logger.warning("Client not found for server '\(serverName)', skipping")
            return ServerCapabilityResult(
                serverName: serverName,
                tools: [],
                resources: [],
                prompts: [],
                successfulFetchCount: 0,
                failures: ["\(serverName)/client": "Client not found"]
            )
        }

        async let toolsResult = fetchAggregatedTools(
            client: client,
            serverName: serverName,
            toolNameMode: toolNameMode
        )
        async let resourcesResult = fetchAggregatedResources(client: client, serverName: serverName)
        async let promptsResult = fetchAggregatedPrompts(client: client, serverName: serverName)

        let (resolvedTools, resolvedResources, resolvedPrompts) = await (
            toolsResult,
            resourcesResult,
            promptsResult
        )

        var tools: [AggregatedTool] = []
        var resources: [AggregatedResource] = []
        var prompts: [AggregatedPrompt] = []
        var successfulFetchCount = 0
        var failures: [String: String] = [:]

        switch resolvedTools {
        case .success(let value):
            tools = value
            successfulFetchCount += 1
        case .failure(let message):
            failures["\(serverName)/tools"] = message
        }

        switch resolvedResources {
        case .success(let value):
            resources = value
            successfulFetchCount += 1
        case .failure(let message):
            failures["\(serverName)/resources"] = message
        }

        switch resolvedPrompts {
        case .success(let value):
            prompts = value
            successfulFetchCount += 1
        case .failure(let message):
            failures["\(serverName)/prompts"] = message
        }

        return ServerCapabilityResult(
            serverName: serverName,
            tools: tools,
            resources: resources,
            prompts: prompts,
            successfulFetchCount: successfulFetchCount,
            failures: failures
        )
    }

    func resolveTool(toolName: String) -> ToolResolution {
        let publicMatches = aggregatedTools.filter { $0.name == toolName }
        if publicMatches.count > 1 {
            return .ambiguous("Tool name is ambiguous: \(toolName)")
        }
        if let tool = publicMatches.first {
            let aliasMatches = aggregatedTools.filter {
                $0.canonicalName == toolName && $0.name != toolName
            }
            if !aliasMatches.isEmpty {
                logger.warning(
                    "Legacy tool alias conflicts with a public tool name; public tool takes precedence",
                    metadata: [
                        "tool": toolName,
                        "server": tool.serverName,
                    ])
            }
            return .resolved(makeResolvedName(from: tool))
        }

        let legacyAliasMatches = aggregatedTools.filter {
            $0.canonicalName == toolName && $0.name != toolName
        }
        if legacyAliasMatches.count > 1 {
            return .ambiguous("Legacy tool alias is ambiguous: \(toolName)")
        }
        if let tool = legacyAliasMatches.first {
            return .resolved(makeResolvedName(from: tool))
        }
        return .notFound
    }

    // MARK: - Private: Prefix

    /// 为名称添加服务器前缀
    private func addPrefix(_ serverName: String, _ name: String) -> String {
        serverName + prefixSeparator + name
    }

    private func makeResolvedName(from tool: AggregatedTool) -> ResolvedName {
        ResolvedName(
            serverName: tool.serverName,
            originalName: tool.originalName,
            canonicalName: tool.canonicalName
        )
    }

    private func currentToolNameExposureMode() async -> ToolNameExposureMode {
        let configuredServerCount = await clientManager.getConfiguredServerCount()
        return ToolNameExposureMode.from(configuredServerCount: configuredServerCount)
    }

    private func fetchAggregatedTools(
        client: Client,
        serverName: String,
        toolNameMode: ToolNameExposureMode
    ) async -> CapabilityFetchResult<[AggregatedTool]> {
        do {
            let result = try await asyncWithTimeout(capabilityRequestTimeoutMs) {
                try await client.listTools()
            }
            return .success(result.tools.map { tool in
                makeAggregatedTool(
                    serverName: serverName,
                    tool: tool,
                    toolNameMode: toolNameMode
                )
            })
        } catch {
            let message = capabilityFailureMessage(error)
            logger.warning("Failed to list tools from '\(serverName)'", metadata: [
                "error": message
            ])
            return .failure(message)
        }
    }

    private func fetchAggregatedResources(
        client: Client,
        serverName: String
    ) async -> CapabilityFetchResult<[AggregatedResource]> {
        do {
            let result = try await asyncWithTimeout(capabilityRequestTimeoutMs) {
                try await client.listResources()
            }
            return .success(result.resources.map { resource in
                AggregatedResource(
                    uri: addPrefix(serverName, resource.uri),
                    originalUri: resource.uri,
                    serverName: serverName,
                    name: resource.name,
                    description: resource.description,
                    mimeType: resource.mimeType
                )
            })
        } catch {
            let message = capabilityFailureMessage(error)
            logger.warning("Failed to list resources from '\(serverName)'", metadata: [
                "error": message
            ])
            return .failure(message)
        }
    }

    private func fetchAggregatedPrompts(
        client: Client,
        serverName: String
    ) async -> CapabilityFetchResult<[AggregatedPrompt]> {
        do {
            let result = try await asyncWithTimeout(capabilityRequestTimeoutMs) {
                try await client.listPrompts()
            }
            return .success(result.prompts.map { prompt in
                AggregatedPrompt(
                    name: addPrefix(serverName, prompt.name),
                    originalName: prompt.name,
                    serverName: serverName,
                    description: prompt.description,
                    arguments: prompt.arguments
                )
            })
        } catch {
            let message = capabilityFailureMessage(error)
            logger.warning("Failed to list prompts from '\(serverName)'", metadata: [
                "error": message
            ])
            return .failure(message)
        }
    }

    private func capabilityFailureMessage(_ error: any Error) -> String {
        if error is AsyncTimeoutError {
            return "Timed out after \(capabilityRequestTimeoutMs)ms"
        }
        return String(describing: error)
    }

    /// 构造 tool 的对外名称和内部 canonical 名称。
    private func makeAggregatedTool(
        serverName: String,
        tool: Tool,
        toolNameMode: ToolNameExposureMode
    ) -> AggregatedTool {
        let canonicalName = addPrefix(serverName, tool.name)
        let publicName = toolNameMode.publicName(
            originalName: tool.name,
            canonicalName: canonicalName
        )
        return AggregatedTool(
            name: publicName,
            canonicalName: canonicalName,
            originalName: tool.name,
            serverName: serverName,
            description: tool.description,
            inputSchema: tool.inputSchema
        )
    }

    /// 从带前缀的名称中解析出服务器名和原始名
    private func parsePrefix(_ prefixedName: String) -> ResolvedName? {
        guard let separatorRange = prefixedName.range(of: prefixSeparator) else {
            return nil
        }
        let serverName = String(prefixedName[..<separatorRange.lowerBound])
        let originalName = String(prefixedName[separatorRange.upperBound...])

        guard !serverName.isEmpty, !originalName.isEmpty else {
            return nil
        }

        return ResolvedName(
            serverName: serverName,
            originalName: originalName,
            canonicalName: prefixedName
        )
    }
}
