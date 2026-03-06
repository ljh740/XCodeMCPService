import AppKit
import MCPServiceCore

/// 本地化字符串 helper，从 Bundle.module 加载
private func L10n(_ key: String) -> String {
    NSLocalizedString(key, bundle: Bundle.module, comment: "")
}

// MARK: - StatusBarController

/// 管理 macOS 状态栏图标和菜单
///
/// 显示服务运行状态，提供启动/停止/配置/退出等操作。
/// 所有 UI 操作在 @MainActor 上执行。
@MainActor
final class StatusBarController: NSObject {

    // MARK: - Properties

    private var statusItem: NSStatusItem?
    private let bridgeManager: BridgeManager

    // 菜单项引用（用于动态更新）
    private var statusMenuItem: NSMenuItem?
    private var startStopMenuItem: NSMenuItem?
    private var configSubmenu: NSMenu?

    // MARK: - Init

    init(bridgeManager: BridgeManager) {
        self.bridgeManager = bridgeManager
        super.init()
    }

    // MARK: - Setup

    /// 初始化状态栏图标和菜单
    func setup() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "bolt.horizontal.circle",
                accessibilityDescription: "MCP Bridge Service"
            )
        }

        statusItem.menu = buildMenu()

        // 注册状态变化回调
        Task {
            await bridgeManager.set(onStateChanged: { [weak self] state in
                Task { @MainActor in
                    self?.updateUI(state: state)
                }
            })
        }

        updateUI(state: .stopped)
    }

    // MARK: - Menu Construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // 状态显示
        let statusItem = NSMenuItem(title: L10n("status.stopped"), action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        self.statusMenuItem = statusItem
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // 启动/停止
        let startStop = NSMenuItem(
            title: L10n("menu.start"),
            action: #selector(toggleService),
            keyEquivalent: "s"
        )
        startStop.target = self
        self.startStopMenuItem = startStop
        menu.addItem(startStop)

        // 重启
        let restart = NSMenuItem(
            title: L10n("menu.restart"),
            action: #selector(restartService),
            keyEquivalent: "r"
        )
        restart.target = self
        menu.addItem(restart)

        menu.addItem(.separator())

        // 配置信息子菜单
        let configItem = NSMenuItem(title: L10n("menu.configuration"), action: nil, keyEquivalent: "")
        let configSubmenu = NSMenu()
        configItem.submenu = configSubmenu
        self.configSubmenu = configSubmenu
        menu.addItem(configItem)

        // 打开配置文件
        let openConfig = NSMenuItem(
            title: L10n("menu.openConfig"),
            action: #selector(openConfigFile),
            keyEquivalent: ","
        )
        openConfig.target = self
        menu.addItem(openConfig)

        // 打开日志目录
        let openLogs = NSMenuItem(
            title: L10n("menu.openLogs"),
            action: #selector(openLogsFolder),
            keyEquivalent: "l"
        )
        openLogs.target = self
        menu.addItem(openLogs)

        menu.addItem(.separator())

        // 退出
        let quit = NSMenuItem(
            title: L10n("menu.quit"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - UI Updates

    /// 根据服务状态更新状态栏图标和菜单项
    func updateUI(state: ServiceState) {
        guard let button = statusItem?.button else { return }

        switch state {
        case .running:
            button.image = NSImage(
                systemSymbolName: "bolt.horizontal.circle.fill",
                accessibilityDescription: "MCP Bridge Service - Running"
            )
            statusMenuItem?.title = L10n("status.running")
            startStopMenuItem?.title = L10n("menu.stop")
            startStopMenuItem?.isEnabled = true

        case .stopped:
            button.image = NSImage(
                systemSymbolName: "bolt.horizontal.circle",
                accessibilityDescription: "MCP Bridge Service - Stopped"
            )
            statusMenuItem?.title = L10n("status.stopped")
            startStopMenuItem?.title = L10n("menu.start")
            startStopMenuItem?.isEnabled = true

        case .starting:
            button.image = NSImage(
                systemSymbolName: "bolt.horizontal.circle",
                accessibilityDescription: "MCP Bridge Service - Starting"
            )
            statusMenuItem?.title = L10n("status.starting")
            startStopMenuItem?.isEnabled = false

        case .stopping:
            button.image = NSImage(
                systemSymbolName: "bolt.horizontal.circle",
                accessibilityDescription: "MCP Bridge Service - Stopping"
            )
            statusMenuItem?.title = L10n("status.stopping")
            startStopMenuItem?.isEnabled = false

        case .reconnecting(let name):
            button.image = NSImage(
                systemSymbolName: "arrow.triangle.2.circlepath",
                accessibilityDescription: "MCP Bridge Service - Reconnecting"
            )
            statusMenuItem?.title = String(format: L10n("status.reconnecting"), name)
            startStopMenuItem?.title = L10n("menu.stop")
            startStopMenuItem?.isEnabled = true

        case .error(let msg):
            button.image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "MCP Bridge Service - Error"
            )
            statusMenuItem?.title = String(format: L10n("status.error"), msg)
            startStopMenuItem?.title = L10n("menu.start")
            startStopMenuItem?.isEnabled = true
        }

        // 刷新配置信息子菜单
        refreshConfigSubmenu()
    }

    /// 刷新配置信息子菜单
    private func refreshConfigSubmenu() {
        guard let configSubmenu else { return }
        configSubmenu.removeAllItems()

        // 异步加载配置信息
        Task {
            guard let info = await bridgeManager.getConfigInfo() else {
                configSubmenu.addItem(NSMenuItem(title: L10n("config.loadFailed"), action: nil, keyEquivalent: ""))
                return
            }

            configSubmenu.addItem(NSMenuItem(
                title: String(format: L10n("config.address"), info.host, info.port),
                action: nil, keyEquivalent: ""
            ))
            configSubmenu.addItem(.separator())

            if info.servers.isEmpty {
                configSubmenu.addItem(NSMenuItem(
                    title: L10n("config.noServers"), action: nil, keyEquivalent: ""
                ))
            } else {
                configSubmenu.addItem(NSMenuItem(
                    title: String(format: L10n("config.servers.count"), info.servers.count),
                    action: nil, keyEquivalent: ""
                ))
                for name in info.servers {
                    let item = NSMenuItem(title: "  • \(name)", action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    configSubmenu.addItem(item)
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func toggleService() {
        Task {
            let currentState = await bridgeManager.getState()
            if currentState.canStop {
                await bridgeManager.stop()
            } else {
                await bridgeManager.start()
            }
        }
    }

    @objc private func restartService() {
        Task {
            await bridgeManager.restart()
        }
    }

    @objc private func openConfigFile() {
        let defaultPath = ConfigManager.defaultConfigPath
        // 优先使用环境变量指定的路径，其次使用默认路径
        let candidates = [
            ProcessInfo.processInfo.environment["CONFIG_PATH"],
            defaultPath,
        ].compactMap { $0 }

        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
                return
            }
        }

        // 未找到配置文件，打开默认配置目录（方便用户创建）
        let configDir = (defaultPath as NSString).deletingLastPathComponent
        let dirURL = URL(fileURLWithPath: configDir)
        // 确保目录存在
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dirURL)
    }

    @objc private func openLogsFolder() {
        let dirURL = URL(fileURLWithPath: logDirectory)
        let fm = FileManager.default
        // 确保目录存在
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dirURL)
    }

    @objc private func quitApp() {
        Task {
            let currentState = await bridgeManager.getState()
            if currentState.canStop {
                await bridgeManager.stop()
            }
            NSApp.terminate(nil)
        }
    }
}
