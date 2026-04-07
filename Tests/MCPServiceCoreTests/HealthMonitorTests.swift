import Testing
import Foundation
import MCP
@testable import MCPServiceCore

// MARK: - CallbackTracker

/// Thread-safe tracker for lifecycle callback invocations in tests.
actor CallbackTracker {
    var restartingCalls: [(name: String, attempt: Int)] = []
    var restartedNames: [String] = []
    var restartFailedNames: [String] = []
    var maxRestartsReachedNames: [String] = []
    var hangDetectedNames: [String] = []
    var healthCheckFailedCalls: [(name: String, failures: Int)] = []

    func recordRestarting(name: String, attempt: Int) {
        restartingCalls.append((name, attempt))
    }
    func recordRestarted(name: String) {
        restartedNames.append(name)
    }
    func recordRestartFailed(name: String) {
        restartFailedNames.append(name)
    }
    func recordMaxRestartsReached(name: String) {
        maxRestartsReachedNames.append(name)
    }
    func recordHangDetected(name: String) {
        hangDetectedNames.append(name)
    }
    func recordHealthCheckFailed(name: String, failures: Int) {
        healthCheckFailedCalls.append((name, failures))
    }
}

// MARK: - MockStdioClientManager

/// Mock actor conforming to StdioClientManaging for testing ProcessLifecycleManager in isolation.
/// Provides configurable failure injection, call tracking, and client provisioning.
actor MockStdioClientManager: StdioClientManaging {
    // Failure injection flags
    var shouldFailStart: Bool = false

    // Call tracking
    private(set) var startCallCount: Int = 0
    private(set) var stopCallCount: Int = 0
    private(set) var startedServers: [String] = []
    private(set) var stoppedServers: [String] = []

    // Active servers state
    private var activeServers: Set<String> = []
    private var configuredServers: Set<String> = []

    // Client provisioning: map server name to a pre-created MCP Client (or nil)
    private var clients: [String: Client] = [:]

    func setClient(_ client: Client?, forServer name: String) {
        clients[name] = client
    }

    func addActiveServer(_ name: String) {
        configuredServers.insert(name)
        activeServers.insert(name)
    }

    func setActiveServers(_ names: [String]) {
        configuredServers.formUnion(names)
        activeServers = Set(names)
    }

    func setConfiguredServers(_ names: [String]) {
        configuredServers = Set(names)
    }

    func setShouldFailStart(_ value: Bool) {
        shouldFailStart = value
    }

    // MARK: - StdioClientManaging Conformance

    func startServer(name: String) async throws {
        startCallCount += 1
        startedServers.append(name)
        if shouldFailStart {
            throw BridgeError.internalError("Mock start failure for '\(name)'")
        }
        configuredServers.insert(name)
        activeServers.insert(name)
    }

    func stopServer(name: String) async {
        stopCallCount += 1
        stoppedServers.append(name)
        activeServers.remove(name)
    }

    func getClient(name: String) -> Client? {
        clients[name]
    }

    func getActiveServers() -> [String] {
        Array(activeServers)
    }

    func getConfiguredServerCount() -> Int {
        configuredServers.count
    }

    func isServerRunning(name: String) -> Bool {
        activeServers.contains(name)
    }
}

// MARK: - Helper: Build callbacks with tracker

extension CallbackTracker {
    /// Build LifecycleCallbacks that record all invocations into this tracker.
    nonisolated func makeCallbacks() -> LifecycleCallbacks {
        let tracker = self
        return LifecycleCallbacks(
            onRestarting: { name, attempt in
                Task { await tracker.recordRestarting(name: name, attempt: attempt) }
            },
            onRestarted: { name in
                Task { await tracker.recordRestarted(name: name) }
            },
            onRestartFailed: { name, _ in
                Task { await tracker.recordRestartFailed(name: name) }
            },
            onMaxRestartsReached: { name in
                Task { await tracker.recordMaxRestartsReached(name: name) }
            },
            onHangDetected: { name in
                Task { await tracker.recordHangDetected(name: name) }
            },
            onHealthCheckFailed: { name, failures in
                Task { await tracker.recordHealthCheckFailed(name: name, failures: failures) }
            }
        )
    }
}

// MARK: - RestartPolicy Codable Tests

@Suite("RestartPolicy Health Fields Codable")
struct RestartPolicyHealthCodableTests {

    @Test("Decodes with defaults when health fields absent (backward compat)")
    func decodesWithDefaults() throws {
        // JSON without any health check fields -- simulates old config
        let json = """
        {
            "maxRestarts": 3,
            "backoffBaseMs": 500,
            "backoffMaxMs": 10000,
            "resetAfterMs": 30000
        }
        """.data(using: .utf8)!

        let policy = try JSONDecoder().decode(RestartPolicy.self, from: json)
        #expect(policy.maxRestarts == 3)
        #expect(policy.backoffBaseMs == 500)
        #expect(policy.backoffMaxMs == 10000)
        #expect(policy.resetAfterMs == 30000)
        // Health fields should get defaults
        #expect(policy.healthCheckIntervalMs == 10000)
        #expect(policy.hangTimeoutMs == 10000)
        #expect(policy.hangThreshold == 2)
    }

    @Test("Decodes with explicit health field values")
    func decodesWithExplicitValues() throws {
        let json = """
        {
            "maxRestarts": 10,
            "backoffBaseMs": 2000,
            "backoffMaxMs": 60000,
            "resetAfterMs": 120000,
            "healthCheckIntervalMs": 5000,
            "hangTimeoutMs": 3000,
            "hangThreshold": 5
        }
        """.data(using: .utf8)!

        let policy = try JSONDecoder().decode(RestartPolicy.self, from: json)
        #expect(policy.maxRestarts == 10)
        #expect(policy.healthCheckIntervalMs == 5000)
        #expect(policy.hangTimeoutMs == 3000)
        #expect(policy.hangThreshold == 5)
    }
}

// MARK: - ProcessState Health Fields Tests

@Suite("ProcessState Health Tracking Fields")
struct ProcessStateHealthFieldsTests {

    @Test("Initializes with correct default health tracking values")
    func defaultHealthValues() {
        let state = ProcessState(serverName: "test-server")
        #expect(state.lastHealthCheckAt == nil)
        #expect(state.consecutiveHealthFailures == 0)
    }
}

// MARK: - Health Check Tests

@Suite("Health Check Logic")
struct HealthCheckLogicTests {

    @Test("Health check skips when no client available (getClient returns nil)")
    func healthCheckSkipsNoClient() async throws {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("server-a")
        // No client set for "server-a" -> getClient returns nil

        let policy = RestartPolicy(
            maxRestarts: 3,
            backoffBaseMs: 10,
            backoffMaxMs: 100,
            resetAfterMs: 60000,
            healthCheckIntervalMs: 20,  // 20ms interval
            hangTimeoutMs: 10,
            hangThreshold: 3
        )

        let manager = ProcessLifecycleManager(
            clientManager: mock,
            policy: policy
        )

        // Start monitoring -- this will start health check loop
        await manager.monitor(serverName: "server-a")

        // Wait enough time for a few health check cycles
        try await Task.sleep(for: .milliseconds(100))

        // Health check should have run but not failed (nil client means skip)
        let state = await manager.getProcessState(serverName: "server-a")
        #expect(state != nil)
        #expect(state?.consecutiveHealthFailures == 0)

        await manager.dispose()
    }

    @Test("Monitor sets up process state for server")
    func monitorSetsUpState() async {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("test-srv")

        let manager = ProcessLifecycleManager(clientManager: mock)
        await manager.monitor(serverName: "test-srv")

        let state = await manager.getProcessState(serverName: "test-srv")
        #expect(state != nil)
        #expect(state?.serverName == "test-srv")
        #expect(state?.restartCount == 0)
        #expect(state?.isRestarting == false)

        await manager.dispose()
    }

    @Test("Unmonitor removes process state and stops health check")
    func unmonitorRemovesState() async throws {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("srv")

        let policy = RestartPolicy(healthCheckIntervalMs: 20, hangTimeoutMs: 10, hangThreshold: 3)
        let manager = ProcessLifecycleManager(clientManager: mock, policy: policy)

        await manager.monitor(serverName: "srv")
        let stateBefore = await manager.getProcessState(serverName: "srv")
        #expect(stateBefore != nil)

        await manager.unmonitor(serverName: "srv")
        let stateAfter = await manager.getProcessState(serverName: "srv")
        #expect(stateAfter == nil)

        await manager.dispose()
    }

    @Test("monitorAll monitors all active servers")
    func monitorAllMonitorsActive() async {
        let mock = MockStdioClientManager()
        await mock.setActiveServers(["alpha", "beta", "gamma"])

        let manager = ProcessLifecycleManager(clientManager: mock)
        await manager.monitorAll()

        let stateA = await manager.getProcessState(serverName: "alpha")
        let stateB = await manager.getProcessState(serverName: "beta")
        let stateC = await manager.getProcessState(serverName: "gamma")

        #expect(stateA != nil)
        #expect(stateB != nil)
        #expect(stateC != nil)

        await manager.dispose()
    }

}

// MARK: - Reconnection Tests

@Suite("Health Reconnection Logic")
struct HealthReconnectionTests {

    @Test("handleCrash triggers restart with callback notifications")
    func handleCrashTriggersRestart() async throws {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("crash-srv")

        let tracker = CallbackTracker()
        let callbacks = tracker.makeCallbacks()

        let policy = RestartPolicy(
            maxRestarts: 3,
            backoffBaseMs: 10,     // 10ms backoff for fast test
            backoffMaxMs: 50,
            resetAfterMs: 60000,
            healthCheckIntervalMs: 30000,  // long interval to avoid health check interference
            hangTimeoutMs: 10000,
            hangThreshold: 3
        )

        let manager = ProcessLifecycleManager(
            clientManager: mock,
            policy: policy,
            callbacks: callbacks
        )
        await manager.monitor(serverName: "crash-srv")

        // Trigger crash handling
        await manager.handleCrash(serverName: "crash-srv")

        // Give callbacks time to be recorded (they use Task {})
        try await Task.sleep(for: .milliseconds(20))

        // Verify callbacks were called
        let restartingCalls = await tracker.restartingCalls
        let restartedNames = await tracker.restartedNames
        #expect(restartingCalls.contains(where: { $0.name == "crash-srv" }))
        #expect(restartedNames.contains("crash-srv"))

        // Verify mock was called to start server
        let startCount = await mock.startCallCount
        #expect(startCount >= 1)

        // Verify the started server name
        let started = await mock.startedServers
        #expect(started.contains("crash-srv"))

        await manager.dispose()
    }

    @Test("handleCrash fires maxRestartsReached when limit exceeded")
    func handleCrashMaxRestarts() async throws {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("doomed-srv")
        await mock.setShouldFailStart(true)  // All starts fail

        let tracker = CallbackTracker()
        let callbacks = tracker.makeCallbacks()

        let policy = RestartPolicy(
            maxRestarts: 2,
            backoffBaseMs: 10,
            backoffMaxMs: 20,
            resetAfterMs: 60000,
            healthCheckIntervalMs: 30000,
            hangTimeoutMs: 10000,
            hangThreshold: 3
        )

        let manager = ProcessLifecycleManager(
            clientManager: mock,
            policy: policy,
            callbacks: callbacks
        )
        await manager.monitor(serverName: "doomed-srv")

        // Trigger crash -- starts will fail, eventually hitting max restarts
        await manager.handleCrash(serverName: "doomed-srv")

        // Give callbacks time to be recorded
        try await Task.sleep(for: .milliseconds(20))

        let maxReachedNames = await tracker.maxRestartsReachedNames
        #expect(maxReachedNames.contains("doomed-srv"))

        // Verify multiple start attempts were made
        let startCount = await mock.startCallCount
        #expect(startCount == 2)  // maxRestarts = 2

        await manager.dispose()
    }

    @Test("isRestarting guard prevents concurrent restart attempts")
    func isRestartingGuard() async throws {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("guard-srv")

        let tracker = CallbackTracker()
        let callbacks = tracker.makeCallbacks()

        let policy = RestartPolicy(
            maxRestarts: 5,
            backoffBaseMs: 50,      // 50ms backoff
            backoffMaxMs: 100,
            resetAfterMs: 60000,
            healthCheckIntervalMs: 30000,
            hangTimeoutMs: 10000,
            hangThreshold: 3
        )

        let manager = ProcessLifecycleManager(
            clientManager: mock,
            policy: policy,
            callbacks: callbacks
        )
        await manager.monitor(serverName: "guard-srv")

        // Launch two concurrent crash handlers
        async let crash1: Void = manager.handleCrash(serverName: "guard-srv")
        // Small delay to let first one set isRestarting
        try await Task.sleep(for: .milliseconds(5))
        async let crash2: Void = manager.handleCrash(serverName: "guard-srv")

        await crash1
        await crash2

        // Give callbacks time to be recorded
        try await Task.sleep(for: .milliseconds(20))

        // Second call should have been skipped due to isRestarting guard
        // At most 1 restart cycle should have occurred
        let restartingCalls = await tracker.restartingCalls
        let guardServerCalls = restartingCalls.filter { $0.name == "guard-srv" }
        #expect(guardServerCalls.count <= 1)

        await manager.dispose()
    }
}

// MARK: - Shutdown Tests

@Suite("Health Shutdown and Dispose")
struct HealthShutdownTests {

    @Test("Graceful shutdown cancels health check tasks and stops servers")
    func gracefulShutdownCancelsHealthTasks() async throws {
        let mock = MockStdioClientManager()
        await mock.setActiveServers(["srv-1", "srv-2"])

        let policy = RestartPolicy(
            maxRestarts: 3,
            backoffBaseMs: 10,
            backoffMaxMs: 100,
            resetAfterMs: 60000,
            healthCheckIntervalMs: 20,  // 20ms for fast health check
            hangTimeoutMs: 10,
            hangThreshold: 3
        )

        let manager = ProcessLifecycleManager(
            clientManager: mock,
            policy: policy
        )

        // Monitor all -- starts health check tasks
        await manager.monitorAll()

        // Let health checks run briefly
        try await Task.sleep(for: .milliseconds(50))

        // Graceful shutdown should cancel health check tasks and stop servers
        await manager.gracefulShutdownAll()

        // Verify stopServer was called for monitored servers
        let stopCount = await mock.stopCallCount
        #expect(stopCount == 2)

        // Wait a bit more and verify health checks are no longer running
        // (no crashes from cancelled tasks)
        try await Task.sleep(for: .milliseconds(50))

        await manager.dispose()
    }

    @Test("Dispose marks manager as disposed and clears all state")
    func disposeMarksDisposed() async throws {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("disposable")

        let policy = RestartPolicy(
            healthCheckIntervalMs: 20,
            hangTimeoutMs: 10,
            hangThreshold: 3
        )

        let manager = ProcessLifecycleManager(
            clientManager: mock,
            policy: policy
        )

        await manager.monitor(serverName: "disposable")

        let stateBefore = await manager.getProcessState(serverName: "disposable")
        #expect(stateBefore != nil)

        await manager.dispose()

        // After dispose, state should be cleared
        let stateAfter = await manager.getProcessState(serverName: "disposable")
        #expect(stateAfter == nil)

        // Further monitor calls should be no-ops
        await manager.monitor(serverName: "new-server")
        let stateNew = await manager.getProcessState(serverName: "new-server")
        #expect(stateNew == nil)
    }

    @Test("resetRestartCount resets count and firstFailureAt after crash")
    func resetRestartCount() async throws {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("reset-srv")

        let policy = RestartPolicy(
            maxRestarts: 5,
            backoffBaseMs: 10,
            backoffMaxMs: 50,
            resetAfterMs: 60000,
            healthCheckIntervalMs: 30000,
            hangTimeoutMs: 10000,
            hangThreshold: 3
        )

        let manager = ProcessLifecycleManager(
            clientManager: mock,
            policy: policy
        )
        await manager.monitor(serverName: "reset-srv")

        // Trigger a crash to increment restart count (no longer reset on success;
        // resetAfterMs handles time-based reset instead)
        await manager.handleCrash(serverName: "reset-srv")

        let stateAfterCrash = await manager.getProcessState(serverName: "reset-srv")
        #expect(stateAfterCrash != nil)
        // restartCount remains 1 after successful restart (budget preserved)
        #expect(stateAfterCrash!.restartCount == 1)

        // Reset
        await manager.resetRestartCount(serverName: "reset-srv")
        let stateAfterReset = await manager.getProcessState(serverName: "reset-srv")
        #expect(stateAfterReset?.restartCount == 0)
        #expect(stateAfterReset?.firstFailureAt == nil)

        await manager.dispose()
    }
}
