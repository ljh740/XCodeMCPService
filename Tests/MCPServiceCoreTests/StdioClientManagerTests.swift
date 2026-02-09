import Foundation
import Testing
@testable import MCPServiceCore

@Suite("StdioClientManager Tests")
struct StdioClientManagerTests {

    private func makeConfig(name: String, command: String = "/usr/bin/echo") -> ServerConfig {
        ServerConfig(name: name, command: command)
    }

    // MARK: - Init & Query

    @Test("Init with empty configs")
    func initEmpty() async {
        let manager = StdioClientManager(configs: [])
        let active = await manager.getActiveServers()
        #expect(active.isEmpty)
    }

    @Test("getActiveServers returns empty when no servers started")
    func noActiveServers() async {
        let manager = StdioClientManager(configs: [
            makeConfig(name: "server1"),
            makeConfig(name: "server2"),
        ])
        let active = await manager.getActiveServers()
        #expect(active.isEmpty)
    }

    @Test("isServerRunning returns false for configured but not started server")
    func notRunning() async {
        let manager = StdioClientManager(configs: [makeConfig(name: "s1")])
        let running = await manager.isServerRunning(name: "s1")
        #expect(running == false)
    }

    @Test("isServerRunning returns false for unknown server")
    func unknownServer() async {
        let manager = StdioClientManager(configs: [])
        let running = await manager.isServerRunning(name: "nonexistent")
        #expect(running == false)
    }

    @Test("getClient returns nil for non-running server")
    func clientNilWhenNotRunning() async {
        let manager = StdioClientManager(configs: [makeConfig(name: "s1")])
        let client = await manager.getClient(name: "s1")
        #expect(client == nil)
    }

    @Test("getClient returns nil for unknown server")
    func clientNilForUnknown() async {
        let manager = StdioClientManager(configs: [])
        let client = await manager.getClient(name: "nonexistent")
        #expect(client == nil)
    }

    // MARK: - Error Paths

    @Test("startServer throws for unknown config name")
    func startUnknownThrows() async {
        let manager = StdioClientManager(configs: [makeConfig(name: "s1")])
        do {
            try await manager.startServer(name: "nonexistent")
            Issue.record("Expected error to be thrown")
        } catch {
            // Expected: BridgeError.serverNotFound
            #expect(String(describing: error).contains("not found"))
        }
    }

    @Test("stopServer is no-op for unknown server (no crash)")
    func stopUnknownNoCrash() async {
        let manager = StdioClientManager(configs: [])
        await manager.stopServer(name: "nonexistent")
        // Should not crash
    }

    @Test("stopAll on empty manager is no-op")
    func stopAllEmpty() async {
        let manager = StdioClientManager(configs: [])
        await manager.stopAll()
        // Should not crash
    }

    @Test("startAll with no enabled servers is no-op")
    func startAllNoEnabled() async throws {
        var config = makeConfig(name: "s1")
        config.enabled = false
        let manager = StdioClientManager(configs: [config])
        try await manager.startAll()
        let active = await manager.getActiveServers()
        #expect(active.isEmpty)
    }
}
