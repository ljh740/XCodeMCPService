import AppKit
import Foundation

// MARK: - Dependencies

/// 查询运行中服务器的启动绑定，并按当前环境重新解析。
public protocol XcodeLaunchInspecting: Sendable {
    func getActiveServers() async -> [String]
    func currentLaunch(name: String) async -> ResolvedServerLaunch?
    func resolveLaunch(name: String) async throws -> ResolvedServerLaunch
}

/// 按需重启单个服务器。
public protocol OnDemandServerRestarting: Sendable {
    func restartServer(serverName: String) async -> ServerRestartOutcome
}

/// 报告服务器是否有进行中的业务调用。
public protocol ServerActivityReporting: Sendable {
    func hasInFlightToolCalls(serverName: String) async -> Bool
}

extension StdioClientManager: XcodeLaunchInspecting {}
extension ProcessLifecycleManager: OnDemandServerRestarting {}
extension RequestRouter: ServerActivityReporting {}

// MARK: - XcodeRuntimeSwitchCoordinator

/// Xcode 启动或退出后重新解析各服务器绑定的 Xcode，仅在绑定变化时重启对应服务器。
///
/// 事件经过防抖合并；服务器有进行中的 tool 调用（如 BuildProject）时延后到空闲再切换。
public actor XcodeRuntimeSwitchCoordinator {
    private let inspector: any XcodeLaunchInspecting
    private let restarter: any OnDemandServerRestarting
    private let activity: any ServerActivityReporting
    private let debounceMs: Int
    private let idleRetryMs: Int
    private var pendingTask: Task<Void, Never>?
    private var disposed = false

    private let logger = bridgeLogger.child(label: "xcode-runtime-switch")

    public init(
        inspector: any XcodeLaunchInspecting,
        restarter: any OnDemandServerRestarting,
        activity: any ServerActivityReporting,
        debounceMs: Int = 3000,
        idleRetryMs: Int = 5000
    ) {
        self.inspector = inspector
        self.restarter = restarter
        self.activity = activity
        self.debounceMs = max(debounceMs, 0)
        self.idleRetryMs = max(idleRetryMs, 1)
    }

    /// Xcode 启动或退出时调用；重新计时，合并短时间内的连续事件。
    public func xcodeApplicationsChanged() {
        guard !disposed else { return }
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            await self?.reconcileAfterDebounce()
        }
    }

    public func shutdown() {
        disposed = true
        pendingTask?.cancel()
        pendingTask = nil
    }

    /// 等待当前一轮核对结束，仅供测试使用。
    func waitForPendingReconcile() async {
        await pendingTask?.value
    }

    private func reconcileAfterDebounce() async {
        do {
            try await Task.sleep(for: .milliseconds(debounceMs))
        } catch {
            return
        }

        var pending = Set(await inspector.getActiveServers())
        var deferredServers: Set<String> = []
        while !pending.isEmpty {
            for name in pending.sorted() {
                guard !Task.isCancelled, !disposed else { return }
                switch await reconcile(serverName: name) {
                case .done:
                    pending.remove(name)
                case .busy:
                    if deferredServers.insert(name).inserted {
                        logger.info("Deferring Xcode runtime check until in-flight tool calls finish", metadata: [
                            "server": name,
                        ])
                    }
                }
            }
            guard !pending.isEmpty else { return }
            do {
                try await Task.sleep(for: .milliseconds(idleRetryMs))
            } catch {
                return
            }
        }
    }

    private enum ReconcileResult {
        case done
        /// 有进行中的调用或正在重启，稍后重试
        case busy
    }

    private func reconcile(serverName: String) async -> ReconcileResult {
        guard let current = await inspector.currentLaunch(name: serverName)?.automaticXcodeBinding else {
            return .done
        }
        // 先做廉价的忙碌检查，避免长任务期间反复执行 mcp-server status 探测。
        guard await !activity.hasInFlightToolCalls(serverName: serverName) else {
            return .busy
        }

        let resolved: ResolvedServerLaunch
        do {
            resolved = try await inspector.resolveLaunch(name: serverName)
        } catch {
            logger.warning("Unable to resolve Xcode runtime after Xcode change; keeping current binding", metadata: [
                "server": serverName,
                "error": "\(error)",
            ])
            return .done
        }

        guard let target = resolved.automaticXcodeBinding, target != current else {
            return .done
        }
        // 解析期间可能有新调用进入
        guard await !activity.hasInFlightToolCalls(serverName: serverName) else {
            return .busy
        }

        logger.info("Xcode runtime changed, restarting server", metadata: [
            "server": serverName,
            "fromXcode": current.xcodePath,
            "fromConnection": current.connection,
            "toXcode": target.xcodePath,
            "toConnection": target.connection,
        ])
        // 重启放在独立 Task 中，避免新的 Xcode 事件取消本轮核对时中断 stop/start。
        let restarter = self.restarter
        let outcome = await Task {
            await restarter.restartServer(serverName: serverName)
        }.value
        return outcome == .busy ? .busy : .done
    }
}

// MARK: - XcodeApplicationObserver

/// 监听 Xcode 启动与退出事件。
public enum XcodeApplicationObserver {
    static let bundleIdentifier = "com.apple.dt.Xcode"

    /// 返回的 Task 被取消时停止监听。
    public static func observe(onChange: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        Task {
            await withTaskGroup(of: Void.self) { group in
                for name in [
                    NSWorkspace.didLaunchApplicationNotification,
                    NSWorkspace.didTerminateApplicationNotification,
                ] {
                    group.addTask {
                        let notifications = NSWorkspace.shared.notificationCenter.notifications(named: name)
                        for await notification in notifications {
                            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                                as? NSRunningApplication
                            guard application?.bundleIdentifier == bundleIdentifier else { continue }
                            await onChange()
                        }
                    }
                }
            }
        }
    }
}
