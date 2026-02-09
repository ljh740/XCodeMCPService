import Foundation

// MARK: - RestartPolicy

/// 重启策略配置
public struct RestartPolicy: Sendable {
    public var maxRestarts: Int
    public var backoffBaseMs: Int
    public var backoffMaxMs: Int
    public var resetAfterMs: Int

    public init(
        maxRestarts: Int = 5,
        backoffBaseMs: Int = 1000,
        backoffMaxMs: Int = 30000,
        resetAfterMs: Int = 60000
    ) {
        self.maxRestarts = maxRestarts
        self.backoffBaseMs = backoffBaseMs
        self.backoffMaxMs = backoffMaxMs
        self.resetAfterMs = resetAfterMs
    }

    public static let `default` = RestartPolicy(
        maxRestarts: 5, backoffBaseMs: 1000, backoffMaxMs: 30000, resetAfterMs: 60000
    )
}

// MARK: - ProcessState

/// 被监控进程的运行时状态
public struct ProcessState: Sendable {
    public let serverName: String
    public var restartCount: Int = 0
    public var lastRestartAt: Date? = nil
    public var firstFailureAt: Date? = nil
    public var isRestarting: Bool = false

    public init(serverName: String) {
        self.serverName = serverName
    }
}

// MARK: - LifecycleCallbacks

/// 生命周期事件回调
public struct LifecycleCallbacks: Sendable {
    /// 正在重启 (serverName, attempt)
    public var onRestarting: (@Sendable (String, Int) -> Void)?
    /// 重启成功 (serverName)
    public var onRestarted: (@Sendable (String) -> Void)?
    /// 重启失败 (serverName, error)
    public var onRestartFailed: (@Sendable (String, Error) -> Void)?
    /// 达到最大重启次数 (serverName)
    public var onMaxRestartsReached: (@Sendable (String) -> Void)?

    public init(
        onRestarting: (@Sendable (String, Int) -> Void)? = nil,
        onRestarted: (@Sendable (String) -> Void)? = nil,
        onRestartFailed: (@Sendable (String, Error) -> Void)? = nil,
        onMaxRestartsReached: (@Sendable (String) -> Void)? = nil
    ) {
        self.onRestarting = onRestarting
        self.onRestarted = onRestarted
        self.onRestartFailed = onRestartFailed
        self.onMaxRestartsReached = onMaxRestartsReached
    }
}

// MARK: - ProcessLifecycleManager

/// 监控子进程健康状态，实现崩溃检测和自动重启（指数退避）
public actor ProcessLifecycleManager {

    // MARK: - Properties

    private let clientManager: StdioClientManager
    private let policy: RestartPolicy
    private var processStates: [String: ProcessState] = [:]
    private var monitoredServers: Set<String> = []
    public var callbacks: LifecycleCallbacks
    private var disposed: Bool = false

    private let logger = bridgeLogger.child(label: "lifecycle")

    // MARK: - Init

    public init(
        clientManager: StdioClientManager,
        policy: RestartPolicy = .default
    ) {
        self.clientManager = clientManager
        self.policy = policy
        self.callbacks = LifecycleCallbacks()
    }

    // MARK: - Monitor

    /// 开始监控指定服务器
    public func monitor(serverName: String) {
        guard !disposed else { return }

        monitoredServers.insert(serverName)
        if processStates[serverName] == nil {
            processStates[serverName] = ProcessState(serverName: serverName)
        }
        logger.info("Monitoring started", metadata: ["server": serverName])
    }

    /// 停止监控指定服务器
    public func unmonitor(serverName: String) {
        monitoredServers.remove(serverName)
        processStates.removeValue(forKey: serverName)
        logger.info("Monitoring stopped", metadata: ["server": serverName])
    }

    /// 监控所有当前活跃的服务器
    public func monitorAll() async {
        guard !disposed else { return }

        let activeServers = await clientManager.getActiveServers()
        for name in activeServers {
            monitor(serverName: name)
        }
        logger.info("Monitoring all active servers", metadata: [
            "count": "\(activeServers.count)",
        ])
    }

    // MARK: - Crash Handling

    /// 处理服务器崩溃，执行指数退避重启
    public func handleCrash(serverName: String) async {
        guard !disposed else { return }
        guard monitoredServers.contains(serverName) else {
            logger.warning("Crash reported for unmonitored server", metadata: ["server": serverName])
            return
        }

        // 初始化状态（如果不存在）
        if processStates[serverName] == nil {
            processStates[serverName] = ProcessState(serverName: serverName)
        }

        // 已在重启中，跳过
        guard processStates[serverName]?.isRestarting != true else {
            logger.debug("Already restarting, skipping", metadata: ["server": serverName])
            return
        }

        // 使用 while 循环替代递归重试
        while !disposed {
            let now = Date()

            // 检查是否需要重置计数（距上次重启超过 resetAfterMs）
            if let lastRestart = processStates[serverName]?.lastRestartAt {
                let elapsed = now.timeIntervalSince(lastRestart) * 1000
                if elapsed >= Double(policy.resetAfterMs) {
                    logger.info("Reset window elapsed, resetting restart count", metadata: [
                        "server": serverName,
                    ])
                    processStates[serverName]?.restartCount = 0
                    processStates[serverName]?.firstFailureAt = nil
                }
            }

            // 记录首次故障时间
            if processStates[serverName]?.firstFailureAt == nil {
                processStates[serverName]?.firstFailureAt = now
            }

            // 递增重启计数
            processStates[serverName]?.restartCount += 1
            let attempt = processStates[serverName]?.restartCount ?? 1

            // 检查是否达到最大重启次数
            if attempt > policy.maxRestarts {
                logger.error("Max restarts reached", metadata: [
                    "server": serverName,
                    "maxRestarts": "\(policy.maxRestarts)",
                ])
                processStates[serverName]?.isRestarting = false
                callbacks.onMaxRestartsReached?(serverName)
                return
            }

            processStates[serverName]?.isRestarting = true
            defer {
                processStates[serverName]?.isRestarting = false
            }

            // 计算退避延迟：min(baseMs * 2^(count-1), maxMs)
            let exponent = attempt - 1
            let delayMs = min(
                policy.backoffBaseMs * (1 << exponent),
                policy.backoffMaxMs
            )

            logger.info("Scheduling restart", metadata: [
                "server": serverName,
                "attempt": "\(attempt)",
                "delayMs": "\(delayMs)",
            ])

            callbacks.onRestarting?(serverName, attempt)

            // 等待退避时间
            do {
                try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            } catch {
                // Task 被取消
                return
            }

            // disposed 检查（sleep 后可能已被清理）
            guard !disposed else {
                return
            }

            // 尝试重启
            do {
                try await clientManager.startServer(name: serverName)
                processStates[serverName]?.lastRestartAt = Date()

                logger.info("Restart succeeded", metadata: [
                    "server": serverName,
                    "attempt": "\(attempt)",
                ])
                callbacks.onRestarted?(serverName)
                break  // 成功，退出循环
            } catch {
                logger.error("Restart failed", metadata: [
                    "server": serverName,
                    "attempt": "\(attempt)",
                    "error": "\(error)",
                ])
                callbacks.onRestartFailed?(serverName, error)
                // 失败，继续循环重试（移除递归调用）
                continue
            }
        }
    }

    // MARK: - Query

    /// 获取指定服务器的进程状态
    public func getProcessState(serverName: String) -> ProcessState? {
        processStates[serverName]
    }

    /// 重置指定服务器的重启计数
    public func resetRestartCount(serverName: String) {
        processStates[serverName]?.restartCount = 0
        processStates[serverName]?.firstFailureAt = nil
        logger.debug("Restart count reset", metadata: ["server": serverName])
    }

    // MARK: - Shutdown

    /// 优雅关闭所有监控的服务器
    public func gracefulShutdownAll() async {
        logger.info("Graceful shutdown started", metadata: [
            "count": "\(monitoredServers.count)",
        ])

        let servers = Array(monitoredServers)
        for name in servers {
            processStates[name]?.isRestarting = false
        }

        await withTaskGroup(of: Void.self) { group in
            for name in servers {
                group.addTask {
                    await self.clientManager.stopServer(name: name)
                }
            }
        }

        logger.info("Graceful shutdown completed")
    }

    /// 清理所有资源，标记为已释放
    public func dispose() {
        disposed = true
        monitoredServers.removeAll()
        processStates.removeAll()
        logger.info("ProcessLifecycleManager disposed")
    }
}
