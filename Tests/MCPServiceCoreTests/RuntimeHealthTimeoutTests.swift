import Foundation
import Testing
@testable import MCPServiceCore

@Suite("Runtime Health Timeout Reporting")
struct RuntimeHealthTimeoutTests {

    @Test("Request timeout failures trigger hang reconnection")
    func requestTimeoutTriggersReconnect() async throws {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("xcode-tools")

        let tracker = CallbackTracker()
        let policy = RestartPolicy(
            maxRestarts: 2,
            backoffBaseMs: 10,
            backoffMaxMs: 20,
            resetAfterMs: 1000,
            healthCheckIntervalMs: 30000,
            hangTimeoutMs: 10000,
            hangThreshold: 2
        )
        let manager = ProcessLifecycleManager(
            clientManager: mock,
            policy: policy,
            callbacks: tracker.makeCallbacks()
        )
        await manager.monitorAll()
        let initialGeneration = await manager.currentHealthGeneration(serverName: "xcode-tools")
        #expect(initialGeneration == 1)

        await manager.recordRequestTimeout(
            serverName: "xcode-tools",
            operation: "tool:GetBuildLog",
            generation: initialGeneration
        )
        let stateAfterFirstTimeout = await manager.getProcessState(serverName: "xcode-tools")
        #expect(stateAfterFirstTimeout?.consecutiveHealthFailures == 1)

        await manager.recordRequestTimeout(
            serverName: "xcode-tools",
            operation: "tool:XcodeListNavigatorIssues",
            generation: initialGeneration
        )

        let stopCallCount = await mock.stopCallCount
        let startCallCount = await mock.startCallCount
        let hangDetectedNames = await tracker.hangDetectedNames
        let restartedNames = await tracker.restartedNames
        let stateAfterReconnect = await manager.getProcessState(serverName: "xcode-tools")
        let generationAfterReconnect = await manager.currentHealthGeneration(serverName: "xcode-tools")

        #expect(stopCallCount == 1)
        #expect(startCallCount == 1)
        #expect(hangDetectedNames.contains("xcode-tools"))
        #expect(restartedNames.contains("xcode-tools"))
        #expect(stateAfterReconnect?.consecutiveHealthFailures == 0)
        #expect(generationAfterReconnect == 2)

        await manager.dispose()
    }

    @Test("Stale timeout from previous generation is ignored after reconnection")
    func staleRequestTimeoutIsIgnoredAfterReconnect() async throws {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("xcode-tools")

        let policy = RestartPolicy(
            maxRestarts: 2,
            backoffBaseMs: 10,
            backoffMaxMs: 20,
            resetAfterMs: 1000,
            healthCheckIntervalMs: 30000,
            hangTimeoutMs: 10000,
            hangThreshold: 2
        )
        let manager = ProcessLifecycleManager(
            clientManager: mock,
            policy: policy
        )
        await manager.monitorAll()

        let initialGeneration = await manager.currentHealthGeneration(serverName: "xcode-tools")
        #expect(initialGeneration == 1)

        await manager.recordRequestTimeout(
            serverName: "xcode-tools",
            operation: "tool:GetBuildLog",
            generation: initialGeneration
        )
        await manager.recordRequestTimeout(
            serverName: "xcode-tools",
            operation: "tool:XcodeListNavigatorIssues",
            generation: initialGeneration
        )

        let stopCallsAfterReconnect = await mock.stopCallCount
        let startCallsAfterReconnect = await mock.startCallCount
        let generationAfterReconnect = await manager.currentHealthGeneration(serverName: "xcode-tools")
        let stateAfterReconnect = await manager.getProcessState(serverName: "xcode-tools")

        #expect(generationAfterReconnect == 2)
        #expect(stateAfterReconnect?.consecutiveHealthFailures == 0)

        await manager.recordRequestTimeout(
            serverName: "xcode-tools",
            operation: "tool:late-timeout",
            generation: initialGeneration
        )

        let finalState = await manager.getProcessState(serverName: "xcode-tools")
        let finalStopCalls = await mock.stopCallCount
        let finalStartCalls = await mock.startCallCount

        #expect(finalState?.consecutiveHealthFailures == 0)
        #expect(finalStopCalls == stopCallsAfterReconnect)
        #expect(finalStartCalls == startCallsAfterReconnect)

        await manager.dispose()
    }
}
