import Foundation
import MCP
import Synchronization
import Testing
@testable import MCPServiceCore

/// 按脚本依次返回锁屏状态，脚本耗尽后保持最后一个值。
final class ScriptedLockStateProvider: DeviceLockStateProviding, Sendable {
    private let state: Mutex<(script: [Bool], queries: [String])>

    init(_ script: [Bool]) {
        self.state = Mutex((script, []))
    }

    func isLocked(deviceName: String) async throws -> Bool {
        state.withLock { state in
            state.queries.append(deviceName)
            return state.script.count > 1 ? state.script.removeFirst() : state.script[0]
        }
    }

    var queries: [String] {
        state.withLock { $0.queries }
    }
}

final class DeviceLockEventRecorder: Sendable {
    private let storage = Mutex<[DeviceLockEvent]>([])

    func append(_ event: DeviceLockEvent) {
        storage.withLock { $0.append(event) }
    }

    var events: [DeviceLockEvent] {
        storage.withLock { $0 }
    }
}

func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("DeviceLockMonitor Tests")
struct DeviceLockMonitorTests {

    private func makeMonitor(
        _ script: [Bool]
    ) -> (DeviceLockMonitor, ScriptedLockStateProvider, DeviceLockEventRecorder) {
        let provider = ScriptedLockStateProvider(script)
        let recorder = DeviceLockEventRecorder()
        let monitor = DeviceLockMonitor(provider: provider, pollInterval: .milliseconds(5)) { event in
            recorder.append(event)
        }
        return (monitor, provider, recorder)
    }

    // MARK: - Lock State Decoding

    @Test("decodes passcodeRequired as locked state")
    func decodeLockState() throws {
        let locked = Data(#"{"info":{"outcome":"success"},"result":{"passcodeRequired":true,"unlockedSinceBoot":true}}"#.utf8)
        let unlocked = Data(#"{"info":{"outcome":"success"},"result":{"passcodeRequired":false,"unlockedSinceBoot":true}}"#.utf8)

        #expect(try DevicectlLockStateProvider.decodeLockState(locked, terminationStatus: 0) == true)
        #expect(try DevicectlLockStateProvider.decodeLockState(unlocked, terminationStatus: 0) == false)
    }

    @Test("failed devicectl outcome surfaces error description")
    func decodeFailedOutcome() {
        let data = Data(#"{"info":{"outcome":"failed"},"error":{"userInfo":{"NSLocalizedDescription":{"string":"The specified device was not found."}}}}"#.utf8)

        #expect(throws: DeviceLockStateError.self) {
            try DevicectlLockStateProvider.decodeLockState(data, terminationStatus: 1)
        }
    }

    // MARK: - Run Destination

    @Test("active physical iOS device is watched")
    func physicalDestination() {
        let text = #"{"activeDestinationDisplayTitle":"darkedge","destinations":[{"displayTitle":"darkedge","isActive":true,"isSimulator":false,"isGenericDevice":false,"platformIdentifier":"com.apple.platform.iphoneos"},{"displayTitle":"iPhone 17","isActive":false,"isSimulator":true,"isGenericDevice":false,"platformIdentifier":"com.apple.platform.iphonesimulator"}]}"#

        #expect(DeviceRunDestination.activePhysicalDeviceName(fromListOutput: text) == "darkedge")
    }

    @Test("simulator, Mac, generic and unparsable destinations are ignored")
    func ignoredDestinations() {
        let simulator = #"{"destinations":[{"displayTitle":"iPhone 17","isActive":true,"isSimulator":true,"isGenericDevice":false,"platformIdentifier":"com.apple.platform.iphonesimulator"}]}"#
        let mac = #"{"destinations":[{"displayTitle":"My Mac","isActive":true,"isSimulator":false,"isGenericDevice":false,"platformIdentifier":"com.apple.platform.macosx"}]}"#
        let generic = #"{"destinations":[{"displayTitle":"Any iOS Device (arm64)","isActive":true,"isSimulator":false,"isGenericDevice":true,"platformIdentifier":"com.apple.platform.iphoneos"}]}"#

        #expect(DeviceRunDestination.activePhysicalDeviceName(fromListOutput: simulator) == nil)
        #expect(DeviceRunDestination.activePhysicalDeviceName(fromListOutput: mac) == nil)
        #expect(DeviceRunDestination.activePhysicalDeviceName(fromListOutput: generic) == nil)
        #expect(DeviceRunDestination.activePhysicalDeviceName(fromListOutput: "Error: no workspace") == nil)
    }

    // MARK: - Monitor

    @Test("emits locked once, then cleared after unlock")
    func lockThenUnlock() async throws {
        let (monitor, _, recorder) = makeMonitor([true, true, true, false])

        let token = await monitor.register(deviceName: "darkedge")
        try await waitUntil { recorder.events.count == 2 }
        await monitor.unregister(token)

        #expect(recorder.events == [.locked(deviceName: "darkedge"), .cleared(deviceName: "darkedge")])
    }

    @Test("unlocked device never emits events")
    func unlockedDevice() async throws {
        let (monitor, provider, recorder) = makeMonitor([false])

        let token = await monitor.register(deviceName: "darkedge")
        try await waitUntil { provider.queries.count >= 3 }
        await monitor.unregister(token)

        #expect(recorder.events.isEmpty)
    }

    @Test("last unregister clears a still-locked device and stops polling")
    func unregisterWhileLocked() async throws {
        let (monitor, provider, recorder) = makeMonitor([true])

        let first = await monitor.register(deviceName: "darkedge")
        let second = await monitor.register(deviceName: "darkedge")
        try await waitUntil { !recorder.events.isEmpty }

        await monitor.unregister(first)
        #expect(recorder.events == [.locked(deviceName: "darkedge")])

        await monitor.unregister(second)
        #expect(recorder.events == [.locked(deviceName: "darkedge"), .cleared(deviceName: "darkedge")])

        let queriesAfterStop = provider.queries.count
        try await Task.sleep(for: .milliseconds(50))
        #expect(provider.queries.count <= queriesAfterStop + 1)
        #expect(recorder.events.count == 2)
    }

    @Test("shutdown clears every locked device")
    func shutdownClears() async throws {
        let (monitor, _, recorder) = makeMonitor([true])

        _ = await monitor.register(deviceName: "darkedge")
        try await waitUntil { !recorder.events.isEmpty }
        await monitor.shutdown()

        #expect(recorder.events == [.locked(deviceName: "darkedge"), .cleared(deviceName: "darkedge")])
    }
}
