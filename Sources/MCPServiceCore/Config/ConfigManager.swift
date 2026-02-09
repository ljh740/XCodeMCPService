import Foundation

// MARK: - ConfigManager

/// MCP Forward 桥接服务配置管理器
///
/// 负责从 JSON 文件加载、验证和管理 `AppConfig` 配置。
/// 使用 `actor` 保证线程安全。
public actor ConfigManager {

    // MARK: - Properties

    private var config: AppConfig?
    private var configPath: String?

    // MARK: - Init

    public init() {}

    // MARK: - Public API

    /// 配置是否已加载
    public var isLoaded: Bool {
        config != nil
    }

    /// 返回当前配置文件路径
    public func getConfigPath() -> String? {
        configPath
    }

    /// 默认配置文件路径：~/Library/Application Support/XCodeMCPService/config.json
    public static let defaultConfigPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/XCodeMCPService/config.json"
    }()

    /// 从指定路径（或环境变量 `CONFIG_PATH`）加载并验证配置。
    /// 未指定路径时依次查找环境变量和默认路径，都不存在则使用内置默认配置。
    @discardableResult
    public func loadConfig(from path: String? = nil) async throws -> AppConfig {
        let resolvedPath = path
            ?? ProcessInfo.processInfo.environment["CONFIG_PATH"]
            ?? {
                let defaultPath = ConfigManager.defaultConfigPath
                return FileManager.default.fileExists(atPath: defaultPath) ? defaultPath : nil
            }()

        let loaded: AppConfig

        if let resolvedPath, !resolvedPath.isEmpty {
            // 从文件加载
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                throw BridgeError.configError("Config file not found: \(resolvedPath)")
            }

            let data: Data
            do {
                data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
            } catch {
                throw BridgeError.configError("Failed to read config file: \(error)")
            }

            do {
                loaded = try JSONDecoder().decode(AppConfig.self, from: data)
            } catch {
                throw BridgeError.configError("Invalid JSON in config file: \(error)")
            }

            self.configPath = resolvedPath
        } else {
            // 使用默认配置，并写入默认路径
            loaded = AppConfig.default
            let defaultPath = ConfigManager.defaultConfigPath
            Self.writeDefaultConfigIfNeeded(loaded, to: defaultPath)
            self.configPath = defaultPath
        }

        // 验证失败时透传 ConfigValidationError
        try loaded.validate()

        self.config = loaded
        return loaded
    }

    /// 返回已加载的配置，未加载则抛错
    public func getConfig() throws -> AppConfig {
        guard let config else {
            throw BridgeError.configError("Config not loaded, call loadConfig() first")
        }
        return config
    }

    /// 返回所有已启用的服务器配置
    public func getEnabledServers() throws -> [ServerConfig] {
        let config = try getConfig()
        return config.servers.filter(\.enabled)
    }

    /// 按名称查找服务器配置
    public func getServerConfig(name: String) throws -> ServerConfig? {
        let config = try getConfig()
        return config.servers.first { $0.name == name }
    }

    // MARK: - Private

    /// 将默认配置写入指定路径（仅当文件不存在时）
    private static func writeDefaultConfigIfNeeded(_ config: AppConfig, to path: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
