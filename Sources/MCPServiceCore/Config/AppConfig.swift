// MARK: - Configuration Validation

/// 配置验证错误
public struct ConfigValidationError: Error, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

// MARK: - LogLevel

/// 日志级别
public enum LogLevel: String, Codable, Sendable, Hashable, CaseIterable {
    case debug
    case info
    case warn
    case error
}

// MARK: - ServerConfig

/// MCP 服务器配置
public struct ServerConfig: Codable, Sendable, Hashable {
    /// 服务器唯一名称
    public var name: String
    /// 启动命令
    public var command: String
    /// 命令参数
    public var args: [String]
    /// 环境变量
    public var env: [String: String]?
    /// 是否启用
    public var enabled: Bool

    public init(
        name: String,
        command: String,
        args: [String] = [],
        env: [String: String]? = nil,
        enabled: Bool = true
    ) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case name, command, args, env, enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
        env = try container.decodeIfPresent([String: String].self, forKey: .env)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

// MARK: - BridgeConfig

/// 桥接服务配置
public struct BridgeConfig: Codable, Sendable, Hashable {
    /// HTTP 监听端口
    public var port: Int
    /// 监听地址
    public var host: String
    /// 请求超时（毫秒）
    public var timeout: Int
    /// 日志级别
    public var logLevel: LogLevel

    public init(
        port: Int = 13339,
        host: String = "127.0.0.1",
        timeout: Int = 30000,
        logLevel: LogLevel = .info
    ) {
        self.port = port
        self.host = host
        self.timeout = timeout
        self.logLevel = logLevel
    }

    private enum CodingKeys: String, CodingKey {
        case port, host, timeout, logLevel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 13339
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        timeout = try container.decodeIfPresent(Int.self, forKey: .timeout) ?? 30000
        logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
    }
}

// MARK: - AppConfig

/// 应用顶层配置
public struct AppConfig: Codable, Sendable, Hashable {
    /// 桥接服务配置
    public var bridge: BridgeConfig
    /// MCP 服务器列表
    public var servers: [ServerConfig]

    /// 内置默认配置
    public static let `default` = AppConfig(
        bridge: BridgeConfig(
            port: 13339,
            host: "127.0.0.1",
            timeout: 30000,
            logLevel: .info
        ),
        servers: [
            ServerConfig(
                name: "xcode-tools",
                command: "xcrun",
                args: ["mcpbridge"],
                enabled: true
            ),
        ]
    )

    public init(
        bridge: BridgeConfig = BridgeConfig(),
        servers: [ServerConfig]
    ) {
        self.bridge = bridge
        self.servers = servers
    }

    private enum CodingKeys: String, CodingKey {
        case bridge, servers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bridge = try container.decodeIfPresent(BridgeConfig.self, forKey: .bridge) ?? BridgeConfig()
        servers = try container.decode([ServerConfig].self, forKey: .servers)
    }

    /// 验证配置合法性
    public func validate() throws {
        guard !servers.isEmpty else {
            throw ConfigValidationError("servers must contain at least one entry")
        }

        for (index, server) in servers.enumerated() {
            guard !server.name.isEmpty else {
                throw ConfigValidationError("servers[\(index)].name must not be empty")
            }
            guard !server.command.isEmpty else {
                throw ConfigValidationError("servers[\(index)].command must not be empty")
            }
        }

        guard (1...65535).contains(bridge.port) else {
            throw ConfigValidationError("bridge.port must be between 1 and 65535, got \(bridge.port)")
        }

        guard bridge.timeout >= 1000 else {
            throw ConfigValidationError("bridge.timeout must be at least 1000ms, got \(bridge.timeout)")
        }

        // 只允许 localhost 访问
        let allowedHosts: Set<String> = ["127.0.0.1", "localhost"]
        guard allowedHosts.contains(bridge.host) else {
            throw ConfigValidationError(
                "host must be 127.0.0.1 or localhost (only local access is supported)"
            )
        }
    }
}
