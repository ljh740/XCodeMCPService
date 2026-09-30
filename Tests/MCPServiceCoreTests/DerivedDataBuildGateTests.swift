import Foundation
import Testing
@testable import MCPServiceCore

@Suite("DerivedDataBuildGate Tests")
struct DerivedDataBuildGateTests {

    private let workspacePath = "/Users/jie/MTXX/MTXX.xcworkspace"

    /// 在临时 DerivedData 中建立一个 workspace 目录，返回 (根目录, 构建日志目录)。
    private func makeDerivedData() throws -> (root: URL, buildLogs: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DerivedDataBuildGateTests-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("MTXX-abc", isDirectory: true)
        let buildLogs = project.appendingPathComponent("Logs/Build", isDirectory: true)
        try FileManager.default.createDirectory(at: buildLogs, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["WorkspacePath": workspacePath],
            format: .xml,
            options: 0
        )
        try info.write(to: project.appendingPathComponent("info.plist"))
        return (root, buildLogs)
    }

    private func writeBuildLog(in directory: URL, modified: Date) throws {
        let url = directory.appendingPathComponent("\(UUID().uuidString).xcactivitylog")
        try Data().write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test("locates build logs by workspace path in info.plist")
    func locatesBuildLogs() throws {
        let (root, buildLogs) = try makeDerivedData()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DerivedDataBuildGate(derivedDataRoot: root)

        #expect(gate.buildLogDirectory(forWorkspace: workspacePath)?.standardizedFileURL == buildLogs.standardizedFileURL)
        #expect(gate.buildLogDirectory(forWorkspace: "/tmp/Other.xcworkspace") == nil)
    }

    @Test("unknown workspace does not block device watching")
    func unknownWorkspaceReturnsImmediately() async throws {
        let (root, _) = try makeDerivedData()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DerivedDataBuildGate(derivedDataRoot: root, pollInterval: .milliseconds(5))

        try await gate.waitUntilDeviceNeeded(workspacePath: nil, since: Date())
        try await gate.waitUntilDeviceNeeded(workspacePath: "/tmp/Other.xcworkspace", since: Date())
    }

    @Test("waits until a build log newer than the call appears")
    func waitsForNewBuildLog() async throws {
        let (root, buildLogs) = try makeDerivedData()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DerivedDataBuildGate(derivedDataRoot: root, pollInterval: .milliseconds(5))
        let since = Date()
        // 调用开始前的旧构建日志不算
        try writeBuildLog(in: buildLogs, modified: since.addingTimeInterval(-60))

        let wait = Task { try await gate.waitUntilDeviceNeeded(workspacePath: workspacePath, since: since) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(gate.hasBuildLog(in: buildLogs, since: since) == false)

        try writeBuildLog(in: buildLogs, modified: Date())
        try await wait.value
        #expect(gate.hasBuildLog(in: buildLogs, since: since))
    }

    @Test("waiting ends with cancellation when the call finishes first")
    func cancellationStopsWaiting() async throws {
        let (root, _) = try makeDerivedData()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DerivedDataBuildGate(derivedDataRoot: root, pollInterval: .milliseconds(5))

        let wait = Task { try await gate.waitUntilDeviceNeeded(workspacePath: workspacePath, since: Date()) }
        wait.cancel()

        await #expect(throws: CancellationError.self) { try await wait.value }
    }
}
