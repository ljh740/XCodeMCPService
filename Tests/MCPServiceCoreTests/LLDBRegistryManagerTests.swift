import Foundation
import Testing
@testable import MCPServiceCore

private struct StaticLLDBProcessChecker: LLDBProcessChecking {
    let running: Bool
    var executablePath: String? = nil

    func isProcessRunning(_ processIdentifier: Int32) -> Bool {
        running
    }

    func executablePath(for processIdentifier: Int32) -> String? {
        executablePath
    }

    func parentProcessIdentifier(for processIdentifier: Int32) -> Int32? {
        nil
    }
}

private struct StaticLLDBConnectionChecker: LLDBConnectionChecking {
    let reachable: Bool

    func isReachable(connectionURI: String) async -> Bool {
        reachable
    }
}

@Suite("LLDB Registry Manager Tests")
struct LLDBRegistryManagerTests {
    @Test("Dead and unreachable registry entries are moved to recoverable quarantine")
    func quarantinesConfirmedStaleEntry() async throws {
        let directoryURL = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let registryURL = try writeRegistry(processIdentifier: 12345, directoryURL: directoryURL)
        let manager = DefaultLLDBRegistryManager(
            directoryURL: directoryURL,
            processChecker: StaticLLDBProcessChecker(running: false),
            connectionChecker: StaticLLDBConnectionChecker(reachable: false)
        )

        let quarantined = await manager.quarantineConfirmedStaleEntries()

        #expect(quarantined.count == 1)
        #expect(FileManager.default.fileExists(atPath: registryURL.path) == false)
        #expect(quarantined.first?.contains("XCodeMCPService-Stale") == true)
        #expect(quarantined.first.map(FileManager.default.fileExists(atPath:)) == true)
    }

    @Test("Live process registry entries are preserved")
    func preservesLiveProcessEntry() async throws {
        let directoryURL = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let registryURL = try writeRegistry(processIdentifier: 12346, directoryURL: directoryURL)
        let manager = DefaultLLDBRegistryManager(
            directoryURL: directoryURL,
            processChecker: StaticLLDBProcessChecker(running: true),
            connectionChecker: StaticLLDBConnectionChecker(reachable: false)
        )

        let quarantined = await manager.quarantineConfirmedStaleEntries()

        #expect(quarantined.isEmpty)
        #expect(FileManager.default.fileExists(atPath: registryURL.path))
    }

    @Test("Reachable registry entries are preserved even when the recorded PID disappeared")
    func preservesReachableEntry() async throws {
        let directoryURL = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let registryURL = try writeRegistry(processIdentifier: 12347, directoryURL: directoryURL)
        let manager = DefaultLLDBRegistryManager(
            directoryURL: directoryURL,
            processChecker: StaticLLDBProcessChecker(running: false),
            connectionChecker: StaticLLDBConnectionChecker(reachable: true)
        )

        let quarantined = await manager.quarantineConfirmedStaleEntries()

        #expect(quarantined.isEmpty)
        #expect(FileManager.default.fileExists(atPath: registryURL.path))
    }

    @Test("Snapshot is deterministic and ignores unrelated files")
    func snapshotIsDeterministic() async throws {
        let directoryURL = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        _ = try writeRegistry(processIdentifier: 22, directoryURL: directoryURL)
        _ = try writeRegistry(processIdentifier: 11, directoryURL: directoryURL)
        try Data("ignore".utf8).write(to: directoryURL.appendingPathComponent("settings.json"))
        let manager = DefaultLLDBRegistryManager(directoryURL: directoryURL)

        let snapshot = await manager.snapshot()

        #expect(snapshot.entries.map(\.processIdentifier) == [11, 22])
    }

    @Test("Snapshot equality ignores other lldb-mcp multiplexer processes")
    func snapshotEqualityIgnoresMultiplexers() {
        let debugger = LLDBRegistryEntry(
            fileURL: URL(fileURLWithPath: "/tmp/lldb-mcp-100.json"),
            processIdentifier: 100,
            connectionURI: "connection://[127.0.0.1]:5100",
            contents: "debugger",
            processExecutablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode"
        )
        let firstMultiplexer = LLDBRegistryEntry(
            fileURL: URL(fileURLWithPath: "/tmp/lldb-mcp-200.json"),
            processIdentifier: 200,
            connectionURI: "connection://[127.0.0.1]:5200",
            contents: "first",
            processExecutablePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-mcp"
        )
        let secondMultiplexer = LLDBRegistryEntry(
            fileURL: URL(fileURLWithPath: "/tmp/lldb-mcp-300.json"),
            processIdentifier: 300,
            connectionURI: "connection://[127.0.0.1]:5300",
            contents: "second",
            processExecutablePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-mcp"
        )

        #expect(
            LLDBRegistrySnapshot(entries: [debugger, firstMultiplexer])
                == LLDBRegistrySnapshot(entries: [debugger, secondMultiplexer])
        )
    }

    @Test("Snapshot identifies backends created by a newly started lldb-mcp")
    func identifiesOwnedBackendProcesses() {
        let previous = LLDBRegistrySnapshot(entries: [])
        let spawnedBackend = LLDBRegistryEntry(
            fileURL: URL(fileURLWithPath: "/tmp/lldb-mcp-400.json"),
            processIdentifier: 400,
            connectionURI: "connection://[127.0.0.1]:5400",
            contents: "backend",
            processExecutablePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb",
            parentProcessIdentifier: 399,
            parentProcessExecutablePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/lldb-mcp"
        )
        let interactiveDebugger = LLDBRegistryEntry(
            fileURL: URL(fileURLWithPath: "/tmp/lldb-mcp-500.json"),
            processIdentifier: 500,
            connectionURI: "connection://[127.0.0.1]:5500",
            contents: "interactive",
            processExecutablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode",
            parentProcessIdentifier: 1,
            parentProcessExecutablePath: "/sbin/launchd"
        )

        let spawned = LLDBRegistrySnapshot(entries: [spawnedBackend, interactiveDebugger])
            .backendsSpawnedByMultiplexer(since: previous)

        #expect(spawned == [spawnedBackend])
    }

    private func makeDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("XCodeMCPService-LLDBRegistry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func writeRegistry(processIdentifier: Int32, directoryURL: URL) throws -> URL {
        let registryURL = directoryURL.appendingPathComponent("lldb-mcp-\(processIdentifier).json")
        let contents = #"{"connection_uri":"connection://[127.0.0.1]:51611"}"#
        try Data(contents.utf8).write(to: registryURL)
        return registryURL
    }
}
