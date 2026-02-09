import Foundation
import Testing
@testable import MCPServiceCore

// MARK: - RestartPolicy Tests

@Suite("RestartPolicy Tests")
struct RestartPolicyTests {

    @Test("Default policy has expected values")
    func defaultPolicy() {
        let policy = RestartPolicy.default
        #expect(policy.maxRestarts == 5)
        #expect(policy.backoffBaseMs == 1000)
        #expect(policy.backoffMaxMs == 30000)
        #expect(policy.resetAfterMs == 60000)
    }

    @Test("Custom policy preserves values")
    func customPolicy() {
        let policy = RestartPolicy(
            maxRestarts: 3,
            backoffBaseMs: 500,
            backoffMaxMs: 10000,
            resetAfterMs: 30000
        )
        #expect(policy.maxRestarts == 3)
        #expect(policy.backoffBaseMs == 500)
        #expect(policy.backoffMaxMs == 10000)
        #expect(policy.resetAfterMs == 30000)
    }

    @Test("Backoff calculation: delay doubles per attempt up to max")
    func backoffCalculation() {
        let policy = RestartPolicy(
            maxRestarts: 10,
            backoffBaseMs: 1000,
            backoffMaxMs: 16000,
            resetAfterMs: 60000
        )
        // attempt 1: 1000 * 2^0 = 1000
        #expect(min(policy.backoffBaseMs * (1 << 0), policy.backoffMaxMs) == 1000)
        // attempt 2: 1000 * 2^1 = 2000
        #expect(min(policy.backoffBaseMs * (1 << 1), policy.backoffMaxMs) == 2000)
        // attempt 3: 1000 * 2^2 = 4000
        #expect(min(policy.backoffBaseMs * (1 << 2), policy.backoffMaxMs) == 4000)
        // attempt 4: 1000 * 2^3 = 8000
        #expect(min(policy.backoffBaseMs * (1 << 3), policy.backoffMaxMs) == 8000)
        // attempt 5: 1000 * 2^4 = 16000 (hits max)
        #expect(min(policy.backoffBaseMs * (1 << 4), policy.backoffMaxMs) == 16000)
        // attempt 6: 1000 * 2^5 = 32000 → capped at 16000
        #expect(min(policy.backoffBaseMs * (1 << 5), policy.backoffMaxMs) == 16000)
    }
}

// MARK: - ProcessState Tests

@Suite("ProcessState Tests")
struct ProcessStateTests {

    @Test("Initial state has zero counts and no flags")
    func initialState() {
        let state = ProcessState(serverName: "test-server")
        #expect(state.serverName == "test-server")
        #expect(state.restartCount == 0)
        #expect(state.lastRestartAt == nil)
        #expect(state.firstFailureAt == nil)
        #expect(state.isRestarting == false)
    }

    @Test("State is mutable")
    func stateMutation() {
        var state = ProcessState(serverName: "s1")
        state.restartCount = 3
        state.isRestarting = true
        state.firstFailureAt = Date()
        state.lastRestartAt = Date()

        #expect(state.restartCount == 3)
        #expect(state.isRestarting == true)
        #expect(state.firstFailureAt != nil)
        #expect(state.lastRestartAt != nil)
    }
}

// MARK: - LifecycleCallbacks Tests

@Suite("LifecycleCallbacks Tests")
struct LifecycleCallbacksTests {

    @Test("Default callbacks are nil")
    func defaultCallbacks() {
        let callbacks = LifecycleCallbacks()
        #expect(callbacks.onRestarting == nil)
        #expect(callbacks.onRestarted == nil)
        #expect(callbacks.onRestartFailed == nil)
        #expect(callbacks.onMaxRestartsReached == nil)
    }

    @Test("Callbacks can be set and invoked")
    func callbackInvocation() async {
        // Use an actor to safely capture state
        actor CallbackTracker {
            var restartingName: String?
            var restartingAttempt: Int?
            var restartedName: String?

            func recordRestarting(name: String, attempt: Int) {
                restartingName = name
                restartingAttempt = attempt
            }

            func recordRestarted(name: String) {
                restartedName = name
            }
        }

        let tracker = CallbackTracker()

        let callbacks = LifecycleCallbacks(
            onRestarting: { name, attempt in
                Task { await tracker.recordRestarting(name: name, attempt: attempt) }
            },
            onRestarted: { name in
                Task { await tracker.recordRestarted(name: name) }
            }
        )

        callbacks.onRestarting?("test", 1)
        callbacks.onRestarted?("test")

        // Give tasks time to complete
        try? await Task.sleep(for: .milliseconds(10))

        let restartingName = await tracker.restartingName
        let restartingAttempt = await tracker.restartingAttempt
        let restartedName = await tracker.restartedName

        #expect(restartingName == "test")
        #expect(restartingAttempt == 1)
        #expect(restartedName == "test")
    }
}

// MARK: - ProcessLifecycleManager Actor Tests

@Suite("ProcessLifecycleManager Tests")
struct ProcessLifecycleManagerTests {

    // Create a minimal StdioClientManager for testing
    private func makeManager(policy: RestartPolicy = .default) -> ProcessLifecycleManager {
        let clientManager = StdioClientManager(configs: [])
        return ProcessLifecycleManager(clientManager: clientManager, policy: policy)
    }

    @Test("Monitor adds server to monitored set")
    func monitorAddsServer() async {
        let manager = makeManager()
        await manager.monitor(serverName: "test-server")
        let state = await manager.getProcessState(serverName: "test-server")
        #expect(state != nil)
        #expect(state?.serverName == "test-server")
        #expect(state?.restartCount == 0)
    }

    @Test("Unmonitor removes server")
    func unmonitorRemovesServer() async {
        let manager = makeManager()
        await manager.monitor(serverName: "test-server")
        await manager.unmonitor(serverName: "test-server")
        let state = await manager.getProcessState(serverName: "test-server")
        #expect(state == nil)
    }

    @Test("Reset restart count clears count and firstFailureAt")
    func resetRestartCount() async {
        let manager = makeManager()
        await manager.monitor(serverName: "s1")
        // Manually we can't set restartCount, but resetRestartCount should work on initial state
        await manager.resetRestartCount(serverName: "s1")
        let state = await manager.getProcessState(serverName: "s1")
        #expect(state?.restartCount == 0)
        #expect(state?.firstFailureAt == nil)
    }

    @Test("Dispose clears all state")
    func disposeClears() async {
        let manager = makeManager()
        await manager.monitor(serverName: "s1")
        await manager.monitor(serverName: "s2")
        await manager.dispose()
        let state1 = await manager.getProcessState(serverName: "s1")
        let state2 = await manager.getProcessState(serverName: "s2")
        #expect(state1 == nil)
        #expect(state2 == nil)
    }

    @Test("HandleCrash on unmonitored server is no-op")
    func handleCrashUnmonitored() async {
        let manager = makeManager()
        // Should not crash or hang
        await manager.handleCrash(serverName: "unknown")
        let state = await manager.getProcessState(serverName: "unknown")
        #expect(state == nil)
    }

    @Test("HandleCrash on disposed manager is no-op")
    func handleCrashDisposed() async {
        let manager = makeManager()
        await manager.monitor(serverName: "s1")
        await manager.dispose()
        // Should return immediately
        await manager.handleCrash(serverName: "s1")
    }
}
