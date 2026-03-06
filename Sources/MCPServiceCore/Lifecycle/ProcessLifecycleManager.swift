import Foundation
import MCP

// MARK: - RestartPolicy

/// 重启策略配置
public struct RestartPolicy: Codable, Sendable {
    public var maxRestarts: Int
    public var backoffBaseMs: Int
    public var backoffMaxMs: Int
    public var resetAfterMs: Int
    /// 健康检查间隔（毫秒）
    public var healthCheckIntervalMs: Int
    /// 挂起超时（毫秒），ping 无响应超过此时间视为挂起
    public var hangTimeoutMs: Int
    /// 连续健康检查失败次数阈值，达到后触发重连
    public var hangThreshold: Int

    public init(
        maxRestarts: Int = 5,
        backoffBaseMs: Int = 1000,
        backoffMaxMs: Int = 30000,
        resetAfterMs: Int = 60000,
        healthCheckIntervalMs: Int = 30000,
        hangTimeoutMs: Int = 10000,
        hangThreshold: Int = 3
    ) {
        self.maxRestarts = max(maxRestarts, 0)
        self.backoffBaseMs = max(backoffBaseMs, 0)
        self.backoffMaxMs = max(backoffMaxMs, 0)
        self.resetAfterMs = max(resetAfterMs, 0)
        self.healthCheckIntervalMs = max(healthCheckIntervalMs, 1)
        self.hangTimeoutMs = max(hangTimeoutMs, 1)
        self.hangThreshold = max(hangThreshold, 1)
    }

    private enum CodingKeys: String, CodingKey {
        case maxRestarts, backoffBaseMs, backoffMaxMs, resetAfterMs
        case healthCheckIntervalMs, hangTimeoutMs, hangThreshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxRestarts = max(try container.decodeIfPresent(Int.self, forKey: .maxRestarts) ?? 5, 0)
        backoffBaseMs = max(try container.decodeIfPresent(Int.self, forKey: .backoffBaseMs) ?? 1000, 0)
        backoffMaxMs = max(try container.decodeIfPresent(Int.self, forKey: .backoffMaxMs) ?? 30000, 0)
        resetAfterMs = max(try container.decodeIfPresent(Int.self, forKey: .resetAfterMs) ?? 60000, 0)
        healthCheckIntervalMs = max(try container.decodeIfPresent(Int.self, forKey: .healthCheckIntervalMs) ?? 30000, 1)
        hangTimeoutMs = max(try container.decodeIfPresent(Int.self, forKey: .hangTimeoutMs) ?? 10000, 1)
        hangThreshold = max(try container.decodeIfPresent(Int.self, forKey: .hangThreshold) ?? 3, 1)
    }

    public static let `default` = RestartPolicy(
        maxRestarts: 5, backoffBaseMs: 1000, backoffMaxMs: 30000, resetAfterMs: 60000,
        healthCheckIntervalMs: 30000, hangTimeoutMs: 10000, hangThreshold: 3
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
    /// 上次健康检查时间
    public var lastHealthCheckAt: Date? = nil
    /// 连续健康检查失败次数
    public var consecutiveHealthFailures: Int = 0

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
    /// 检测到进程挂起 (serverName)
    public var onHangDetected: (@Sendable (String) -> Void)?
    /// 健康检查失败 (serverName, consecutiveFailures)
    public var onHealthCheckFailed: (@Sendable (String, Int) -> Void)?

    public init(
        onRestarting: (@Sendable (String, Int) -> Void)? = nil,
        onRestarted: (@Sendable (String) -> Void)? = nil,
        onRestartFailed: (@Sendable (String, Error) -> Void)? = nil,
        onMaxRestartsReached: (@Sendable (String) -> Void)? = nil,
        onHangDetected: (@Sendable (String) -> Void)? = nil,
        onHealthCheckFailed: (@Sendable (String, Int) -> Void)? = nil
    ) {
        self.onRestarting = onRestarting
        self.onRestarted = onRestarted
        self.onRestartFailed = onRestartFailed
        self.onMaxRestartsReached = onMaxRestartsReached
        self.onHangDetected = onHangDetected
        self.onHealthCheckFailed = onHealthCheckFailed
    }
}

// MARK: - LifecycleEvent

/// 生命周期事件，用于向上层（BridgeManager / StatusBar）传播状态变化
public enum LifecycleEvent: Sendable {
    case serverRestarting(name: String, attempt: Int)
    case serverRestarted(name: String)
    case serverRestartFailed(name: String, error: String)
    case serverPermanentlyDown(name: String)
    case serverHangDetected(name: String)
}

// MARK: - ProcessLifecycleManager

/// 监控子进程健康状态，实现崩溃检测和自动重启（指数退避）
public actor ProcessLifecycleManager {

    // MARK: - Properties

    private let clientManager: any StdioClientManaging
    private let policy: RestartPolicy
    private var processStates: [String: ProcessState] = [:]
    private var monitoredServers: Set<String> = []
    public var callbacks: LifecycleCallbacks
    private var disposed: Bool = false
    /// Per-server health check tasks
    private var healthCheckTasks: [String: Task<Void, Never>] = [:]

    private let logger = bridgeLogger.child(label: "lifecycle")

    // MARK: - Init

    public init(
        clientManager: any StdioClientManaging,
        policy: RestartPolicy = .default,
        callbacks: LifecycleCallbacks = LifecycleCallbacks()
    ) {
        self.clientManager = clientManager
        self.policy = policy
        self.callbacks = callbacks
    }

    // MARK: - Monitor

    /// 开始监控指定服务器
    public func monitor(serverName: String) {
        guard !disposed else { return }

        monitoredServers.insert(serverName)
        if processStates[serverName] == nil {
            processStates[serverName] = ProcessState(serverName: serverName)
        }
        startHealthCheck(serverName: serverName)
        logger.info("Monitoring started", metadata: ["server": serverName])
    }

    /// 停止监控指定服务器
    public func unmonitor(serverName: String) {
        healthCheckTasks[serverName]?.cancel()
        healthCheckTasks.removeValue(forKey: serverName)
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

        processStates[serverName]?.isRestarting = true
        defer {
            processStates[serverName]?.isRestarting = false
        }

        // maxRestarts=0 means never restart; fire callback and bail immediately
        guard policy.maxRestarts > 0 else {
            logger.info("maxRestarts is 0, skipping restart", metadata: ["server": serverName])
            callbacks.onMaxRestartsReached?(serverName)
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
                healthCheckTasks[serverName]?.cancel()
                healthCheckTasks.removeValue(forKey: serverName)
                callbacks.onMaxRestartsReached?(serverName)
                return
            }

            // 计算退避延迟：min(baseMs * 2^(count-1), maxMs)，溢出安全
            let exponent = min(attempt - 1, 30)
            let (product, overflow) = policy.backoffBaseMs.multipliedReportingOverflow(by: 1 << exponent)
            let delayMs = overflow ? policy.backoffMaxMs : min(product, policy.backoffMaxMs)

            logger.info("Scheduling restart", metadata: [
                "server": serverName,
                "attempt": "\(attempt)",
                "delayMs": "\(delayMs)",
            ])

            callbacks.onRestarting?(serverName, attempt)

            // 等待退避时间
            do {
                try await Task.sleep(for: .milliseconds(delayMs))
            } catch {
                // Task 被取消
                return
            }

            // disposed 或已取消监控检查（sleep 后可能已被清理）
            guard !disposed, monitoredServers.contains(serverName) else {
                return
            }

            // 先清理残留资源再重启
            await clientManager.stopServer(name: serverName)

            // 重新检查（stopServer 期间 shutdown/unmonitor 可能已介入）
            guard !disposed, monitoredServers.contains(serverName) else {
                return
            }

            // 尝试重启
            do {
                try await clientManager.startServer(name: serverName)

                // startServer 是 await 挂起点，期间 shutdown/unmonitor 可能已介入
                guard !disposed, monitoredServers.contains(serverName) else {
                    // 清理刚启动的服务器，避免孤儿进程
                    await clientManager.stopServer(name: serverName)
                    return
                }

                processStates[serverName]?.lastRestartAt = Date()
                processStates[serverName]?.consecutiveHealthFailures = 0
                processStates[serverName]?.restartCount = 0
                processStates[serverName]?.firstFailureAt = nil

                logger.info("Restart succeeded", metadata: [
                    "server": serverName,
                    "attempt": "\(attempt)",
                ])
                callbacks.onRestarted?(serverName)

                // 重启健康检查（旧 task 可能已退出）
                startHealthCheck(serverName: serverName)
                break  // 成功，退出循环
            } catch {
                // startServer 失败也是 await 挂起点
                guard !disposed, monitoredServers.contains(serverName) else {
                    return
                }
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

    // MARK: - Health Check

    /// 启动指定服务器的周期性健康检查
    private func startHealthCheck(serverName: String) {
        // Cancel existing task if any
        healthCheckTasks[serverName]?.cancel()

        let task = Task<Void, Never> {
            await self.healthCheckLoop(serverName: serverName)
        }
        healthCheckTasks[serverName] = task
        logger.info("Health check started", metadata: ["server": serverName])
    }

    /// 健康检查循环：周期性 ping + 失败追踪 + 挂起检测
    private func healthCheckLoop(serverName: String) async {
        while !disposed {
            // Sleep for health check interval
            do {
                try await Task.sleep(for: .milliseconds(policy.healthCheckIntervalMs))
            } catch {
                // Task cancelled
                return
            }

            // Guard: disposed or no longer monitored
            guard !disposed, monitoredServers.contains(serverName) else { return }

            // Guard: skip if reconnection is in progress
            guard processStates[serverName]?.isRestarting != true else {
                continue
            }

            // Get client; if nil, server is not running -- skip without incrementing failures
            guard let client = await clientManager.getClient(name: serverName) else {
                continue
            }

            // Revalidate after await (getClient is cross-actor)
            guard !disposed, monitoredServers.contains(serverName) else { return }
            guard processStates[serverName]?.isRestarting != true else { continue }

            // Ping with timeout
            do {
                try await asyncWithTimeout(policy.hangTimeoutMs) {
                    try await client.ping()
                }

                // Revalidate after await (ping/timeout is cross-actor)
                guard !disposed, monitoredServers.contains(serverName) else { return }

                // Success: reset failure count, update timestamp
                processStates[serverName]?.consecutiveHealthFailures = 0
                processStates[serverName]?.lastHealthCheckAt = Date()
            } catch {
                // Revalidate after await
                guard !disposed, monitoredServers.contains(serverName) else { return }

                // Failure: increment consecutive failures
                processStates[serverName]?.consecutiveHealthFailures += 1
                let failures = processStates[serverName]?.consecutiveHealthFailures ?? 0

                logger.warning("Health check failed", metadata: [
                    "server": serverName,
                    "consecutiveFailures": "\(failures)",
                    "error": "\(error)",
                ])
                callbacks.onHealthCheckFailed?(serverName, failures)

                // Check hang threshold
                if failures >= policy.hangThreshold {
                    logger.error("Hang detected, triggering reconnection", metadata: [
                        "server": serverName,
                        "consecutiveFailures": "\(failures)",
                        "threshold": "\(policy.hangThreshold)",
                    ])
                    callbacks.onHangDetected?(serverName)
                    await reconnectHungServer(serverName: serverName)
                    // After reconnect attempt, the loop continues (new health task may have been started)
                    return
                }
            }
        }
    }

    // MARK: - Hang Reconnection

    /// 挂起触发的重连：stop + start，带指数退避重试
    private func reconnectHungServer(serverName: String) async {
        // Guard: server must still be monitored
        guard monitoredServers.contains(serverName) else {
            logger.debug("Server no longer monitored, skipping reconnection", metadata: ["server": serverName])
            return
        }

        // Reentrancy guard
        guard processStates[serverName]?.isRestarting != true else {
            logger.debug("Already restarting, skipping hang reconnection", metadata: ["server": serverName])
            return
        }

        processStates[serverName]?.isRestarting = true
        defer {
            processStates[serverName]?.isRestarting = false
        }

        // maxRestarts=0 means never restart; fire callback and bail immediately
        guard policy.maxRestarts > 0 else {
            logger.info("maxRestarts is 0, skipping hang reconnection", metadata: ["server": serverName])
            callbacks.onMaxRestartsReached?(serverName)
            return
        }

        // Exponential backoff restart loop (same pattern as handleCrash)
        while !disposed {
            let now = Date()

            // Check resetAfterMs window
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

            // Record first failure time
            if processStates[serverName]?.firstFailureAt == nil {
                processStates[serverName]?.firstFailureAt = now
            }

            // Increment restart count
            processStates[serverName]?.restartCount += 1
            let attempt = processStates[serverName]?.restartCount ?? 1

            // Check maxRestarts
            if attempt > policy.maxRestarts {
                logger.error("Max restarts reached during hang recovery", metadata: [
                    "server": serverName,
                    "maxRestarts": "\(policy.maxRestarts)",
                ])
                // Cancel health check task -- permanently stop monitoring this server
                healthCheckTasks[serverName]?.cancel()
                healthCheckTasks.removeValue(forKey: serverName)
                callbacks.onMaxRestartsReached?(serverName)
                return
            }

            // Calculate exponential backoff delay (overflow-safe)
            let exponent = min(attempt - 1, 30)
            let (product, overflow) = policy.backoffBaseMs.multipliedReportingOverflow(by: 1 << exponent)
            let delayMs = overflow ? policy.backoffMaxMs : min(product, policy.backoffMaxMs)

            logger.info("Scheduling hang reconnection", metadata: [
                "server": serverName,
                "attempt": "\(attempt)",
                "delayMs": "\(delayMs)",
            ])

            callbacks.onRestarting?(serverName, attempt)

            // Wait backoff delay
            do {
                try await Task.sleep(for: .milliseconds(delayMs))
            } catch {
                // Task cancelled
                return
            }

            guard !disposed, monitoredServers.contains(serverName) else { return }

            // Stop server (force-kill capable from IMPL-002)
            await clientManager.stopServer(name: serverName)

            // 重新检查（stopServer 期间 shutdown/unmonitor 可能已介入）
            guard !disposed, monitoredServers.contains(serverName) else { return }

            // Try start server
            do {
                try await clientManager.startServer(name: serverName)

                // startServer 是 await 挂起点，期间 shutdown/unmonitor 可能已介入
                guard !disposed, monitoredServers.contains(serverName) else {
                    // 清理刚启动的服务器，避免孤儿进程
                    await clientManager.stopServer(name: serverName)
                    return
                }

                processStates[serverName]?.lastRestartAt = Date()
                processStates[serverName]?.consecutiveHealthFailures = 0
                processStates[serverName]?.restartCount = 0
                processStates[serverName]?.firstFailureAt = nil

                logger.info("Hang reconnection succeeded", metadata: [
                    "server": serverName,
                    "attempt": "\(attempt)",
                ])
                callbacks.onRestarted?(serverName)

                // Restart health check with fresh task
                startHealthCheck(serverName: serverName)
                return
            } catch {
                // startServer 失败也是 await 挂起点
                guard !disposed, monitoredServers.contains(serverName) else {
                    return
                }
                logger.error("Hang reconnection failed", metadata: [
                    "server": serverName,
                    "attempt": "\(attempt)",
                    "error": "\(error)",
                ])
                callbacks.onRestartFailed?(serverName, error)
                // Continue loop for next attempt
                continue
            }
        }
    }

    // MARK: - Shutdown

    /// 优雅关闭所有监控的服务器
    public func gracefulShutdownAll() async {
        logger.info("Graceful shutdown started", metadata: [
            "count": "\(monitoredServers.count)",
        ])

        // Cancel all health check tasks first
        for (_, task) in healthCheckTasks {
            task.cancel()
        }
        healthCheckTasks.removeAll()

        let servers = Array(monitoredServers)
        monitoredServers.removeAll()
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
        // Cancel all health check tasks
        for (_, task) in healthCheckTasks {
            task.cancel()
        }
        healthCheckTasks.removeAll()
        monitoredServers.removeAll()
        processStates.removeAll()
        logger.info("ProcessLifecycleManager disposed")
    }
}
