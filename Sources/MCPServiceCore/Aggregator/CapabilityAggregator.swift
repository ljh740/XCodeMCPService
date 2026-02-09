import Foundation
import MCP

// MARK: - Aggregated Types

/// 聚合后的 Tool，带有服务器名称前缀
public struct AggregatedTool: Sendable {
    /// 带前缀: serverName__originalName
    public let name: String
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
}

// MARK: - CapabilityAggregator

/// 聚合多个下游 MCP 服务器的 capabilities（tools, resources, prompts），
/// 为每个条目添加 `serverName__` 前缀避免名称冲突。
public actor CapabilityAggregator {

    // MARK: - Properties

    private let prefixSeparator = "__"
    private var aggregatedTools: [AggregatedTool] = []
    private var aggregatedResources: [AggregatedResource] = []
    private var aggregatedPrompts: [AggregatedPrompt] = []
    private let clientManager: StdioClientManager

    private let logger = bridgeLogger.child(label: "capability-aggregator")

    // MARK: - Init

    public init(clientManager: StdioClientManager) {
        self.clientManager = clientManager
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

    /// 从带前缀的 tool 名称解析出服务器名和原始名
    public func resolveToolServer(prefixedName: String) -> ResolvedName? {
        guard let resolved = parsePrefix(prefixedName),
            aggregatedTools.contains(where: { $0.name == prefixedName })
        else {
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
    public func refresh() async {
        aggregatedTools = []
        aggregatedResources = []
        aggregatedPrompts = []

        let activeServers = await clientManager.getActiveServers()

        guard !activeServers.isEmpty else {
            logger.info("No active servers to aggregate")
            return
        }

        logger.info("Refreshing capabilities from \(activeServers.count) server(s)")

        // 每个 server 返回的 capabilities
        typealias ServerResult = (
            tools: [AggregatedTool],
            resources: [AggregatedResource],
            prompts: [AggregatedPrompt]
        )

        let results = await withTaskGroup(
            of: ServerResult?.self,
            returning: [ServerResult].self
        ) { group in
            for serverName in activeServers {
                group.addTask {
                    await self.fetchServerCapabilities(serverName: serverName)
                }
            }

            var collected: [ServerResult] = []
            for await result in group {
                if let result {
                    collected.append(result)
                }
            }
            return collected
        }

        // 合并所有结果
        for result in results {
            aggregatedTools.append(contentsOf: result.tools)
            aggregatedResources.append(contentsOf: result.resources)
            aggregatedPrompts.append(contentsOf: result.prompts)
        }

        logger.info("Aggregated capabilities", metadata: [
            "tools": "\(aggregatedTools.count)",
            "resources": "\(aggregatedResources.count)",
            "prompts": "\(aggregatedPrompts.count)",
        ])
    }

    // MARK: - Private: Fetch

    /// 获取单个服务器的 capabilities，任一类别失败则 warn 并跳过该类别
    private func fetchServerCapabilities(
        serverName: String
    ) async -> (tools: [AggregatedTool], resources: [AggregatedResource], prompts: [AggregatedPrompt])? {
        guard let client = await clientManager.getClient(name: serverName) else {
            logger.warning("Client not found for server '\(serverName)', skipping")
            return nil
        }

        var tools: [AggregatedTool] = []
        var resources: [AggregatedResource] = []
        var prompts: [AggregatedPrompt] = []

        // Tools
        do {
            let result = try await client.listTools()
            tools = result.tools.map { tool in
                AggregatedTool(
                    name: addPrefix(serverName, tool.name),
                    originalName: tool.name,
                    serverName: serverName,
                    description: tool.description,
                    inputSchema: tool.inputSchema
                )
            }
        } catch {
            logger.warning("Failed to list tools from '\(serverName)'", metadata: [
                "error": "\(error)"
            ])
        }

        // Resources
        do {
            let result = try await client.listResources()
            resources = result.resources.map { resource in
                AggregatedResource(
                    uri: addPrefix(serverName, resource.uri),
                    originalUri: resource.uri,
                    serverName: serverName,
                    name: resource.name,
                    description: resource.description,
                    mimeType: resource.mimeType
                )
            }
        } catch {
            logger.warning("Failed to list resources from '\(serverName)'", metadata: [
                "error": "\(error)"
            ])
        }

        // Prompts
        do {
            let result = try await client.listPrompts()
            prompts = result.prompts.map { prompt in
                AggregatedPrompt(
                    name: addPrefix(serverName, prompt.name),
                    originalName: prompt.name,
                    serverName: serverName,
                    description: prompt.description,
                    arguments: prompt.arguments
                )
            }
        } catch {
            logger.warning("Failed to list prompts from '\(serverName)'", metadata: [
                "error": "\(error)"
            ])
        }

        return (tools: tools, resources: resources, prompts: prompts)
    }

    // MARK: - Private: Prefix

    /// 为名称添加服务器前缀
    private func addPrefix(_ serverName: String, _ name: String) -> String {
        serverName + prefixSeparator + name
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

        return ResolvedName(serverName: serverName, originalName: originalName)
    }
}
