import Foundation
import MCPServiceCore

// MARK: - ServiceState

/// 桥接服务运行状态
public enum ServiceState: Sendable, CustomStringConvertible {
    case stopped
    case starting
    case running
    case stopping
    case reconnecting(String)
    case degraded(String)
    case error(String)

    public var description: String {
        switch self {
        case .stopped: "stopped"
        case .starting: "starting"
        case .running: "running"
        case .stopping: "stopping"
        case .reconnecting(let name): "reconnecting: \(name)"
        case .degraded(let name): "degraded: \(name) permanently down"
        case .error(let msg): "error: \(msg)"
        }
    }

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// 是否可以启动（仅 stopped 和 error 状态允许）
    public var canStart: Bool {
        switch self {
        case .stopped, .error: true
        default: false
        }
    }

    /// 是否可以停止（running、reconnecting、degraded 状态允许）
    public var canStop: Bool {
        switch self {
        case .running, .reconnecting, .degraded: true
        default: false
        }
    }
}

// MARK: - ConfigInfo

/// 配置摘要信息，用于 UI 显示
public struct ConfigInfo: Sendable {
    public let port: Int
    public let host: String
    public let servers: [String]
}

// MARK: - BridgeManager

/// 管理 BridgeServer 生命周期的 actor
///
/// 封装 BridgeServer 的启动/停止操作，维护服务状态，
/// 通过回调通知 UI 层状态变化。
public actor BridgeManager {

    // MARK: - Properties

    private var bridge: BridgeServer?
    private var configPath: String?
    private(set) var state: ServiceState = .stopped

    private let logger = BridgeLogger(label: "mcp-forward.bridge-manager")

    /// 当前正在重连的 server 集合，用于正确管理多 server 状态
    private var reconnectingServers: Set<String> = []

    /// 已永久下线的 server 集合，用于维持 degraded 状态
    private var permanentlyDownServers: Set<String> = []

    /// 生命周期代数，每次 start() 递增，用于丢弃旧 bridge 的 stale events
    private var lifecycleGeneration: Int = 0

    /// 状态变化回调，在状态更新后调用
    private var onStateChanged: (@Sendable (ServiceState) -> Void)?

    /// 设置状态变化回调
    public func set(onStateChanged callback: (@Sendable (ServiceState) -> Void)?) {
        self.onStateChanged = callback
    }

    // MARK: - Init

    public init(configPath: String? = nil) {
        self.configPath = configPath
    }

    // MARK: - Lifecycle

    /// 启动桥接服务
    public func start() async {
        guard state.canStart else { return }

        updateState(.starting)
        reconnectingServers.removeAll()
        permanentlyDownServers.removeAll()
        lifecycleGeneration += 1
        let currentGeneration = lifecycleGeneration

        let bridge = BridgeServer(configPath: configPath)
        self.bridge = bridge

        await bridge.setLifecycleEventHandler { [weak self] event in
            guard let self else { return }
            Task { await self.handleLifecycleEvent(event, generation: currentGeneration) }
        }

        do {
            try await bridge.start()
            updateState(.running)
        } catch {
            self.bridge = nil
            updateState(.error(error.localizedDescription))
        }
    }

    /// 停止桥接服务
    public func stop() async {
        guard state.canStop else { return }

        updateState(.stopping)
        reconnectingServers.removeAll()
        permanentlyDownServers.removeAll()

        if let bridge {
            await bridge.stop()
        }
        self.bridge = nil

        updateState(.stopped)
    }

    /// 重启桥接服务
    public func restart() async {
        await stop()
        await start()
    }

    // MARK: - Query

    /// 获取当前服务状态
    public func getState() -> ServiceState {
        state
    }

    /// 获取配置摘要信息
    public func getConfigInfo() async -> ConfigInfo? {
        // 尝试通过 ConfigManager 加载配置信息
        let manager = ConfigManager()
        do {
            let config = try await manager.loadConfig(from: configPath)
            let serverNames = config.servers.filter(\.enabled).map(\.name)
            return ConfigInfo(
                port: config.bridge.port,
                host: config.bridge.host,
                servers: serverNames
            )
        } catch {
            return nil
        }
    }

    /// 设置配置文件路径
    public func setConfigPath(_ path: String?) {
        self.configPath = path
    }

    // MARK: - Private

    private func handleLifecycleEvent(_ event: LifecycleEvent, generation: Int) {
        // 丢弃旧 bridge 的 stale events（restart 场景）
        guard generation == lifecycleGeneration else {
            logger.debug("Ignoring stale lifecycle event", metadata: [
                "event": "\(event)",
                "eventGeneration": "\(generation)",
                "currentGeneration": "\(lifecycleGeneration)",
            ])
            return
        }

        // 仅在 running/reconnecting/degraded 状态处理事件，
        // 忽略 stopped/stopping/starting/error 中的 stale events
        switch state {
        case .running, .reconnecting, .degraded:
            break
        default:
            logger.debug("Ignoring lifecycle event in non-active state", metadata: [
                "event": "\(event)",
                "state": "\(state)",
            ])
            return
        }

        logger.info("Handling lifecycle event", metadata: [
            "event": "\(event)",
            "currentState": "\(state)",
        ])

        switch event {
        case .serverRestarting(let name, _), .serverHangDetected(let name):
            reconnectingServers.insert(name)
            updateState(.reconnecting(name))
        case .serverRestarted(let name):
            reconnectingServers.remove(name)
            if reconnectingServers.isEmpty {
                if permanentlyDownServers.isEmpty {
                    updateState(.running)
                } else {
                    updateState(.degraded(permanentlyDownServers.first!))
                }
            } else {
                updateState(.reconnecting(reconnectingServers.first!))
            }
        case .serverPermanentlyDown(let name):
            reconnectingServers.remove(name)
            permanentlyDownServers.insert(name)
            if reconnectingServers.isEmpty {
                updateState(.degraded(name))
            } else {
                updateState(.reconnecting(reconnectingServers.first!))
            }
        case .serverRestartFailed:
            break  // 保持 reconnecting 直到成功或达到上限
        }
    }

    private func updateState(_ newState: ServiceState) {
        state = newState
        onStateChanged?(newState)
    }
}
