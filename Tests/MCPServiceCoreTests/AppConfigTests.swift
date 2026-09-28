import Foundation
import Testing
@testable import MCPServiceCore

@Suite("AppConfig Tests")
struct AppConfigTests {

    // MARK: - ServerConfig Defaults

    @Test("ServerConfig JSON decoding applies defaults")
    func serverConfigDefaults() throws {
        let json = """
        {"name": "test", "command": "/usr/bin/test"}
        """
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        #expect(config.name == "test")
        #expect(config.command == "/usr/bin/test")
        #expect(config.args == [])
        #expect(config.env == nil)
        #expect(config.enabled == true)
    }

    @Test("ServerConfig JSON decoding with all fields")
    func serverConfigAllFields() throws {
        let json = """
        {"name":"s1","command":"node","args":["index.js"],"env":{"KEY":"VAL"},"enabled":false}
        """
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        #expect(config.args == ["index.js"])
        #expect(config.env == ["KEY": "VAL"])
        #expect(config.enabled == false)
    }

    // MARK: - BridgeConfig Defaults

    @Test("BridgeConfig JSON decoding applies defaults")
    func bridgeConfigDefaults() throws {
        let json = "{}"
        let config = try JSONDecoder().decode(BridgeConfig.self, from: Data(json.utf8))
        #expect(config.port == 13339)
        #expect(config.host == "127.0.0.1")
        #expect(config.timeout == 30000)
        #expect(config.toolTimeouts == [
            "xcode-tools__BuildProject": 2_400_000,
            "xcode-tools__RunAllTests": 2_400_000,
            "xcode-tools__RunSomeTests": 2_400_000,
        ])
        #expect(config.capabilityTimeout == 15000)
        #expect(config.logLevel == .info)
    }

    @Test("BridgeConfig JSON decoding with custom values")
    func bridgeConfigCustom() throws {
        let json = """
        {"port":8080,"host":"127.0.0.1","timeout":60000,"capabilityTimeout":7000,"logLevel":"debug"}
        """
        let config = try JSONDecoder().decode(BridgeConfig.self, from: Data(json.utf8))
        #expect(config.port == 8080)
        #expect(config.host == "127.0.0.1")
        #expect(config.timeout == 60000)
        #expect(config.capabilityTimeout == 7000)
        #expect(config.logLevel == .debug)
    }

    @Test("Existing config keeps its global timeout and gains long task defaults")
    func existingConfigLongTaskDefaults() throws {
        let data = Data(#"{"timeout":600000}"#.utf8)
        let config = try JSONDecoder().decode(BridgeConfig.self, from: data)
        #expect(config.timeout == 600000)
        #expect(config.toolTimeouts == BridgeConfig.defaultToolTimeouts)
    }

    @Test("Explicit tool timeout table replaces defaults, including an empty table")
    func explicitToolTimeoutTable() throws {
        let data = Data(#"{"toolTimeouts":{"custom__BuildProject":900000}}"#.utf8)
        let config = try JSONDecoder().decode(BridgeConfig.self, from: data)
        #expect(config.toolTimeouts == ["custom__BuildProject": 900000])

        let empty = try JSONDecoder().decode(BridgeConfig.self, from: Data(#"{"toolTimeouts":{}}"#.utf8))
        #expect(empty.toolTimeouts.isEmpty)
    }

    // MARK: - AppConfig Decoding

    @Test("AppConfig decoding with bridge defaults")
    func appConfigBridgeDefaults() throws {
        let json = """
        {"servers":[{"name":"s1","command":"cmd"}]}
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        #expect(config.bridge.port == 13339)
        #expect(config.servers.count == 1)
    }

    // MARK: - Validation

    @Test("validate passes with valid config")
    func validateValid() throws {
        let config = AppConfig(servers: [ServerConfig(name: "s1", command: "node")])
        try config.validate()
    }

    @Test("validate throws on empty servers")
    func validateEmptyServers() {
        let config = AppConfig(servers: [])
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    @Test("validate throws on empty server name")
    func validateEmptyName() {
        let config = AppConfig(servers: [ServerConfig(name: "", command: "cmd")])
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    @Test("validate throws on empty server command")
    func validateEmptyCommand() {
        let config = AppConfig(servers: [ServerConfig(name: "s1", command: "")])
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    @Test("validate throws on invalid port")
    func validateInvalidPort() {
        let config = AppConfig(
            bridge: BridgeConfig(port: 0),
            servers: [ServerConfig(name: "s1", command: "node")]
        )
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    @Test("validate throws on timeout below 1000ms")
    func validateLowTimeout() {
        let config = AppConfig(
            bridge: BridgeConfig(timeout: 500),
            servers: [ServerConfig(name: "s1", command: "node")]
        )
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    @Test("validate rejects invalid tool timeout entries", arguments: [
        ["xcode-tools__BuildProject": 0],
        ["xcode-tools__BuildProject": 999],
        ["": 2400000],
    ])
    func validateInvalidToolTimeouts(toolTimeouts: [String: Int]) {
        let config = AppConfig(
            bridge: BridgeConfig(toolTimeouts: toolTimeouts),
            servers: [ServerConfig(name: "xcode-tools", command: "xcrun")]
        )
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    @Test("validate throws on capability timeout below 1000ms")
    func validateLowCapabilityTimeout() {
        let config = AppConfig(
            bridge: BridgeConfig(capabilityTimeout: 500),
            servers: [ServerConfig(name: "s1", command: "node")]
        )
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    // MARK: - Round-trip Encoding

    @Test("Encode then decode preserves values")
    func roundTrip() throws {
        let original = AppConfig(
            bridge: BridgeConfig(
                port: 9090,
                host: "127.0.0.1",
                timeout: 5000,
                toolTimeouts: ["custom__BuildProject": 900000],
                capabilityTimeout: 4000,
                logLevel: .debug
            ),
            servers: [
                ServerConfig(name: "a", command: "xcrun", args: ["--flag"], env: ["K": "V"], enabled: false),
                ServerConfig(name: "b", command: "xcrun"),
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Host Validation

    @Test("validate passes for default localhost")
    func validateDefaultLocalhostNoTls() throws {
        let config = AppConfig(
            servers: [ServerConfig(name: "s1", command: "node")]
        )
        try config.validate()
    }

    @Test("validate passes for localhost name")
    func validateLocalhostName() throws {
        let config = AppConfig(
            bridge: BridgeConfig(host: "localhost"),
            servers: [ServerConfig(name: "s1", command: "node")]
        )
        try config.validate()
    }

    @Test("validate throws on non-localhost host")
    func validateNonLocalhostHost() {
        let config = AppConfig(
            bridge: BridgeConfig(host: "0.0.0.0"),
            servers: [ServerConfig(name: "s1", command: "node")]
        )
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    @Test("validate throws on arbitrary host")
    func validateArbitraryHost() {
        let config = AppConfig(
            bridge: BridgeConfig(host: "192.168.1.1"),
            servers: [ServerConfig(name: "s1", command: "node")]
        )
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }

    @Test("validate throws on ::1 ipv6 loopback")
    func validateIpv6LoopbackRejected() {
        let config = AppConfig(
            bridge: BridgeConfig(host: "::1"),
            servers: [ServerConfig(name: "s1", command: "node")]
        )
        #expect(throws: ConfigValidationError.self) {
            try config.validate()
        }
    }
}
