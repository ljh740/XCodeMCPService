import Foundation
import Testing
@testable import MCPServiceCore

// MARK: - Mocks

private actor MockLaunchInspector: XcodeLaunchInspecting {
    private var currentLaunches: [String: ResolvedServerLaunch] = [:]
    private var resolvedLaunches: [String: ResolvedServerLaunch] = [:]
    private(set) var resolveCallCount = 0

    func set(current: ResolvedServerLaunch, resolved: ResolvedServerLaunch, for name: String) {
        currentLaunches[name] = current
        resolvedLaunches[name] = resolved
    }

    func getActiveServers() -> [String] {
        Array(currentLaunches.keys)
    }

    func currentLaunch(name: String) -> ResolvedServerLaunch? {
        currentLaunches[name]
    }

    func resolveLaunch(name: String) throws -> ResolvedServerLaunch {
        resolveCallCount += 1
        guard let launch = resolvedLaunches[name] else {
            throw BridgeError.serverNotFound(name)
        }
        return launch
    }
}

private actor MockRestarter: OnDemandServerRestarting {
    private(set) var restartedServers: [String] = []
    private var queuedOutcomes: [ServerRestartOutcome] = []

    func queue(_ outcomes: [ServerRestartOutcome]) {
        queuedOutcomes = outcomes
    }

    func restartServer(serverName: String) -> ServerRestartOutcome {
        restartedServers.append(serverName)
        return queuedOutcomes.isEmpty ? .restarted : queuedOutcomes.removeFirst()
    }
}

private actor MockActivity: ServerActivityReporting {
    private var busyServers: Set<String> = []

    func setBusy(_ busy: Bool, server: String) {
        if busy {
            busyServers.insert(server)
        } else {
            busyServers.remove(server)
        }
    }

    func hasInFlightToolCalls(serverName: String) -> Bool {
        busyServers.contains(serverName)
    }
}

private func xcodeLaunch(
    path: String,
    connection: String = "headless-mcp-server",
    selection: XcodeSelectionSource = .singleRunning
) -> ResolvedServerLaunch {
    ResolvedServerLaunch(
        command: "xcrun",
        args: ["mcpbridge"],
        environment: [:],
        metadata: [
            "xcodePath": path,
            "xcodeConnection": connection,
            "xcodeSelection": selection.rawValue,
        ]
    )
}

private let betaPath = "/Applications/Xcode-27.1.0-Beta.app"
private let candidatePath = "/Applications/Xcode-27.1.0-Release.Candidate.app"

// MARK: - Coordinator Tests

@Suite("Xcode Runtime Switch Coordinator Tests")
struct XcodeRuntimeSwitchCoordinatorTests {

    private func makeCoordinator(
        inspector: MockLaunchInspector,
        restarter: MockRestarter,
        activity: MockActivity = MockActivity()
    ) -> XcodeRuntimeSwitchCoordinator {
        XcodeRuntimeSwitchCoordinator(
            inspector: inspector,
            restarter: restarter,
            activity: activity,
            debounceMs: 20,
            idleRetryMs: 20
        )
    }

    @Test("Server bound to a different Xcode is restarted")
    func restartsWhenBindingChanges() async {
        let inspector = MockLaunchInspector()
        let restarter = MockRestarter()
        await inspector.set(
            current: xcodeLaunch(path: betaPath, selection: .selectedDeveloperDirectory),
            resolved: xcodeLaunch(path: candidatePath),
            for: "xcode-tools"
        )
        let coordinator = makeCoordinator(inspector: inspector, restarter: restarter)

        await coordinator.xcodeApplicationsChanged()
        await coordinator.waitForPendingReconcile()

        #expect(await restarter.restartedServers == ["xcode-tools"])
    }

    @Test("Unchanged binding does not restart the server")
    func keepsServerWhenBindingUnchanged() async {
        let inspector = MockLaunchInspector()
        let restarter = MockRestarter()
        await inspector.set(
            current: xcodeLaunch(path: candidatePath),
            resolved: xcodeLaunch(path: candidatePath, selection: .activeRunning),
            for: "xcode-tools"
        )
        let coordinator = makeCoordinator(inspector: inspector, restarter: restarter)

        await coordinator.xcodeApplicationsChanged()
        await coordinator.waitForPendingReconcile()

        #expect(await restarter.restartedServers.isEmpty)
    }

    @Test("Explicit Xcode configuration is never switched automatically")
    func explicitConfigurationIsNotSwitched() async {
        let inspector = MockLaunchInspector()
        let restarter = MockRestarter()
        await inspector.set(
            current: xcodeLaunch(path: betaPath, selection: .explicitEnvironment),
            resolved: xcodeLaunch(path: candidatePath),
            for: "explicit-dir"
        )
        await inspector.set(
            current: xcodeLaunch(path: betaPath, connection: "running-xcode-explicit"),
            resolved: xcodeLaunch(path: candidatePath),
            for: "explicit-pid"
        )
        let coordinator = makeCoordinator(inspector: inspector, restarter: restarter)

        await coordinator.xcodeApplicationsChanged()
        await coordinator.waitForPendingReconcile()

        #expect(await restarter.restartedServers.isEmpty)
        #expect(await inspector.resolveCallCount == 0)
    }

    @Test("Bursts of Xcode events are debounced into one restart")
    func debouncesEventBursts() async {
        let inspector = MockLaunchInspector()
        let restarter = MockRestarter()
        await inspector.set(
            current: xcodeLaunch(path: betaPath),
            resolved: xcodeLaunch(path: candidatePath),
            for: "xcode-tools"
        )
        let coordinator = makeCoordinator(inspector: inspector, restarter: restarter)

        await coordinator.xcodeApplicationsChanged()
        await coordinator.xcodeApplicationsChanged()
        await coordinator.xcodeApplicationsChanged()
        await coordinator.waitForPendingReconcile()

        #expect(await restarter.restartedServers == ["xcode-tools"])
        #expect(await inspector.resolveCallCount == 1)
    }

    @Test("Restart waits until in-flight tool calls finish")
    func defersRestartWhileBusy() async throws {
        let inspector = MockLaunchInspector()
        let restarter = MockRestarter()
        let activity = MockActivity()
        await inspector.set(
            current: xcodeLaunch(path: betaPath),
            resolved: xcodeLaunch(path: candidatePath),
            for: "xcode-tools"
        )
        await activity.setBusy(true, server: "xcode-tools")
        let coordinator = makeCoordinator(inspector: inspector, restarter: restarter, activity: activity)

        await coordinator.xcodeApplicationsChanged()
        try await Task.sleep(for: .milliseconds(120))
        #expect(await restarter.restartedServers.isEmpty)

        await activity.setBusy(false, server: "xcode-tools")
        await coordinator.waitForPendingReconcile()

        #expect(await restarter.restartedServers == ["xcode-tools"])
    }

    @Test("Busy lifecycle manager is retried until the restart happens")
    func retriesWhenLifecycleBusy() async {
        let inspector = MockLaunchInspector()
        let restarter = MockRestarter()
        await restarter.queue([.busy, .restarted])
        await inspector.set(
            current: xcodeLaunch(path: betaPath),
            resolved: xcodeLaunch(path: candidatePath),
            for: "xcode-tools"
        )
        let coordinator = makeCoordinator(inspector: inspector, restarter: restarter)

        await coordinator.xcodeApplicationsChanged()
        await coordinator.waitForPendingReconcile()

        #expect(await restarter.restartedServers == ["xcode-tools", "xcode-tools"])
    }

    @Test("Shutdown cancels a pending reconcile")
    func shutdownCancelsPendingReconcile() async {
        let inspector = MockLaunchInspector()
        let restarter = MockRestarter()
        await inspector.set(
            current: xcodeLaunch(path: betaPath),
            resolved: xcodeLaunch(path: candidatePath),
            for: "xcode-tools"
        )
        let coordinator = makeCoordinator(inspector: inspector, restarter: restarter)

        await coordinator.xcodeApplicationsChanged()
        await coordinator.shutdown()
        await coordinator.xcodeApplicationsChanged()
        try? await Task.sleep(for: .milliseconds(80))

        #expect(await restarter.restartedServers.isEmpty)
    }
}

// MARK: - On-demand Restart Tests

@Suite("ProcessLifecycleManager On-demand Restart Tests")
struct OnDemandRestartTests {

    @Test("On-demand restart stops and starts the server and reports callbacks")
    func restartsMonitoredServer() async {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("xcode-tools")
        let tracker = CallbackTracker()
        let manager = ProcessLifecycleManager(
            clientManager: mock,
            policy: RestartPolicy(healthCheckIntervalMs: 60000),
            callbacks: tracker.makeCallbacks()
        )
        await manager.monitorAll()
        let generationBefore = await manager.currentHealthGeneration(serverName: "xcode-tools")

        let outcome = await manager.restartServer(serverName: "xcode-tools")

        #expect(outcome == .restarted)
        #expect(await mock.stoppedServers == ["xcode-tools"])
        #expect(await mock.startedServers == ["xcode-tools"])
        #expect(await manager.currentHealthGeneration(serverName: "xcode-tools") == (generationBefore ?? 0) + 1)
        #expect(await manager.getProcessState(serverName: "xcode-tools")?.restartCount == 0)
        #expect(await tracker.waitUntilRestarted(name: "xcode-tools"))
        await manager.dispose()
    }

    @Test("Unmonitored server is not restarted")
    func ignoresUnmonitoredServer() async {
        let mock = MockStdioClientManager()
        let manager = ProcessLifecycleManager(clientManager: mock)

        let outcome = await manager.restartServer(serverName: "xcode-tools")

        #expect(outcome == .notMonitored)
        #expect(await mock.startCallCount == 0)
        #expect(await mock.stopCallCount == 0)
    }

    @Test("Failed on-demand restart falls back to crash recovery")
    func failedRestartFallsBackToCrashRecovery() async {
        let mock = MockStdioClientManager()
        await mock.addActiveServer("xcode-tools")
        await mock.setShouldFailStart(true)
        let tracker = CallbackTracker()
        let manager = ProcessLifecycleManager(
            clientManager: mock,
            policy: RestartPolicy(maxRestarts: 1, backoffBaseMs: 1, backoffMaxMs: 1, healthCheckIntervalMs: 60000),
            callbacks: tracker.makeCallbacks()
        )
        await manager.monitorAll()

        let outcome = await manager.restartServer(serverName: "xcode-tools")

        #expect(outcome == .failed)
        // 首次按需启动 + 崩溃恢复的一次重试
        #expect(await mock.startCallCount == 2)
        #expect(await manager.getProcessState(serverName: "xcode-tools")?.isRestarting == false)
        await manager.dispose()
    }
}
