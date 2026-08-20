import Foundation

/// 子进程启动前解析后的命令、环境和诊断元数据。
public struct ResolvedServerLaunch: Sendable, Equatable {
    public let command: String
    public let args: [String]
    public let environment: [String: String]
    public let metadata: [String: String]

    public init(
        command: String,
        args: [String],
        environment: [String: String],
        metadata: [String: String] = [:]
    ) {
        self.command = command
        self.args = args
        self.environment = environment
        self.metadata = metadata
    }
}

public protocol ServerLaunchResolving: Sendable {
    func resolve(config: ServerConfig, environment: [String: String]) async throws -> ResolvedServerLaunch
}

/// 保持普通 MCP server 原样，为 Xcode 自带的 MCP 工具选择匹配的 Xcode。
public struct DefaultServerLaunchResolver: ServerLaunchResolving, Sendable {
    private let xcodeRuntimeResolver: any XcodeRuntimeResolving
    private let xcodeMCPServerStatusProvider: any XcodeMCPServerStatusProviding
    private let logger = bridgeLogger.child(label: "server-launch-resolver")

    public init(
        xcodeRuntimeResolver: any XcodeRuntimeResolving = DefaultXcodeRuntimeResolver(),
        xcodeMCPServerStatusProvider: any XcodeMCPServerStatusProviding = DefaultXcodeMCPServerStatusProvider()
    ) {
        self.xcodeRuntimeResolver = xcodeRuntimeResolver
        self.xcodeMCPServerStatusProvider = xcodeMCPServerStatusProvider
    }

    public func resolve(config: ServerConfig, environment: [String: String]) async throws -> ResolvedServerLaunch {
        guard let xcodeTool = standardXcodeTool(config) else {
            return ResolvedServerLaunch(
                command: config.command,
                args: config.args,
                environment: environment
            )
        }

        let runtime = try await xcodeRuntimeResolver.resolve(
            developerDirectoryOverride: environment["DEVELOPER_DIR"]
        )
        var resolvedEnvironment = environment
        resolvedEnvironment["DEVELOPER_DIR"] = runtime.developerDirectoryURL.path

        var metadata = [
            "xcodePath": runtime.applicationURL.path,
            "xcodeVersion": runtime.version,
            "xcodeBuild": runtime.buildVersion,
            "xcodeMode": runtime.mode.rawValue,
            "xcodeSelection": runtime.selectionSource.rawValue,
        ]

        if xcodeTool == .lldbMCP {
            // MCP_XCODE_PID 仅属于 mcpbridge 的 GUI 连接协议，不能泄漏给 lldb-mcp。
            resolvedEnvironment.removeValue(forKey: "MCP_XCODE_PID")
            metadata["xcodeConnection"] = "lldb-mcp"
            return ResolvedServerLaunch(
                command: config.command,
                args: config.args,
                environment: resolvedEnvironment,
                metadata: metadata
            )
        }

        if let explicitProcessIdentifier = nonEmptyValue(resolvedEnvironment["MCP_XCODE_PID"]) {
            resolvedEnvironment["MCP_XCODE_PID"] = explicitProcessIdentifier
            metadata["xcodeConnection"] = "running-xcode-explicit"
            metadata["xcodePID"] = explicitProcessIdentifier
        } else if runtime.mode == .headlessCapable {
            do {
                let status = try await xcodeMCPServerStatusProvider.status(
                    developerDirectoryURL: runtime.developerDirectoryURL
                )
                metadata["xcodeHeadlessRunning"] = String(status.running)
                metadata["xcodeUnsafeAlwaysAllowAllAgents"] = String(status.unsafeAlwaysAllowAllAgents)

                if status.enabled {
                    // Xcode 27 headless 模式拥有独立的持久授权模型；不要注入 PID 切回 GUI 单次授权路径。
                    resolvedEnvironment.removeValue(forKey: "MCP_XCODE_PID")
                    metadata["xcodeConnection"] = "headless-mcp-server"
                    if status.unsafeAlwaysAllowAllAgents {
                        logger.warning(
                            "Xcode MCP server is allowing all agents without approval",
                            metadata: [
                                "xcodePath": runtime.applicationURL.path,
                                "xcodeVersion": runtime.version,
                            ]
                        )
                    }
                } else if let processIdentifier = runtime.processIdentifier {
                    let processIdentifierValue = String(processIdentifier)
                    resolvedEnvironment["MCP_XCODE_PID"] = processIdentifierValue
                    metadata["xcodeConnection"] = "running-xcode"
                    metadata["xcodePID"] = processIdentifierValue
                    metadata["xcodeHeadlessFallback"] = "disabled"
                } else {
                    resolvedEnvironment.removeValue(forKey: "MCP_XCODE_PID")
                    metadata["xcodeConnection"] = "bridge-auto-detection"
                    metadata["xcodeHeadlessFallback"] = "disabled-no-running-xcode"
                }
            } catch {
                // status 是诊断探测，不应因其暂时阻塞或失败而切回 GUI 单次授权路径。
                resolvedEnvironment.removeValue(forKey: "MCP_XCODE_PID")
                metadata["xcodeConnection"] = "headless-mcp-server-unverified"
                metadata["xcodeHeadlessStatusError"] = String(describing: error)
                logger.warning(
                    "Unable to verify Xcode headless MCP status; continuing without MCP_XCODE_PID",
                    metadata: [
                        "error": String(describing: error),
                        "xcodePath": runtime.applicationURL.path,
                        "xcodeVersion": runtime.version,
                    ]
                )
            }
        } else if let processIdentifier = runtime.processIdentifier {
            let processIdentifierValue = String(processIdentifier)
            resolvedEnvironment["MCP_XCODE_PID"] = processIdentifierValue
            metadata["xcodeConnection"] = "running-xcode"
            metadata["xcodePID"] = processIdentifierValue
        } else {
            resolvedEnvironment.removeValue(forKey: "MCP_XCODE_PID")
            metadata["xcodeConnection"] = "bridge-auto-detection"
        }

        return ResolvedServerLaunch(
            command: config.command,
            args: config.args,
            environment: resolvedEnvironment,
            metadata: metadata
        )
    }

    private enum StandardXcodeTool: Equatable {
        case mcpBridge
        case lldbMCP
    }

    private func standardXcodeTool(_ config: ServerConfig) -> StandardXcodeTool? {
        guard URL(fileURLWithPath: config.command).lastPathComponent == "xcrun" else {
            return nil
        }
        switch config.args.first {
        case "mcpbridge":
            return .mcpBridge
        case "lldb-mcp":
            return .lldbMCP
        default:
            return nil
        }
    }

    private func nonEmptyValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
