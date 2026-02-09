import ArgumentParser
import Dispatch
import Foundation
import MCPServiceCore

@main
struct XCodeMCPService: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-mcp-service",
        abstract: "MCP Forward Bridge Service - 将远程请求转发到本地 stdio MCP 服务器"
    )

    @Option(name: [.short, .long], help: "配置文件路径")
    var config: String?

    func run() async throws {
        let configPath = config ?? ProcessInfo.processInfo.environment["CONFIG_PATH"]
        let bridge = BridgeServer(configPath: configPath)

        // 使用 continuation 等待信号，实现优雅关闭
        try await bridge.start()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let lock = NSLock()

            func resumeOnce() {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }

            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

            sigintSource.setEventHandler { resumeOnce() }
            sigtermSource.setEventHandler { resumeOnce() }

            sigintSource.resume()
            sigtermSource.resume()
        }

        await bridge.stop()
    }
}
