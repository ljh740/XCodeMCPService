import AppKit

// MARK: - AppDelegate

/// XCodeMCPStatusBar 应用代理
///
/// 管理应用生命周期，初始化 BridgeManager 和 StatusBarController。
/// 启动时自动启动桥接服务，退出时优雅停止。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var bridgeManager: BridgeManager!
    private var statusBarController: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化服务管理器
        let configPath = ProcessInfo.processInfo.environment["CONFIG_PATH"]
        bridgeManager = BridgeManager(configPath: configPath)

        // 初始化状态栏控制器
        statusBarController = StatusBarController(bridgeManager: bridgeManager)
        statusBarController.setup()

        // 自动启动服务
        Task {
            await bridgeManager.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await bridgeManager.stop()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }
}

// MARK: - Entry Point

@main
@MainActor
enum XCodeMCPStatusBarApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate

        app.run()
    }
}
