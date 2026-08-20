import Foundation
import MCP

actor LLDBSessionController {
    private let developerDirectoryOverride: String?
    private let runtimeResolver: any XcodeRuntimeResolving
    private let registryManager: any LLDBRegistryManaging
    private let clientFactory: LLDBMCPClientFactory
    private let logger = bridgeLogger.child(label: "lldb-session")

    private var client: (any LLDBMCPClient)?
    private var runtime: XcodeRuntime?
    private var registrySnapshot = LLDBRegistrySnapshot.empty
    private var availableToolNames: Set<String> = []
    private var ownedSessionURIs: Set<String> = []
    private var ownedBackendEntries: [Int32: LLDBRegistryEntry] = [:]
    private var untrackedOwnedSessionCount = 0
    private var activeCallCount = 0
    private var generation = 0
    private var lastFailure: String?
    private var transitionTask: Task<AdapterTransition, Never>?
    private var appliedTransitionIdentifier: UUID?

    init(
        developerDirectoryOverride: String? = nil,
        runtimeResolver: any XcodeRuntimeResolving = DefaultXcodeRuntimeResolver(),
        registryManager: any LLDBRegistryManaging = DefaultLLDBRegistryManager(),
        clientFactory: @escaping LLDBMCPClientFactory = { runtime in
            StdioLLDBMCPClient(runtime: runtime)
        }
    ) {
        self.developerDirectoryOverride = developerDirectoryOverride
        self.runtimeResolver = runtimeResolver
        self.registryManager = registryManager
        self.clientFactory = clientFactory
    }

    // MARK: - Stable MCP Surface

    nonisolated static func advertisedTools() -> [Tool] {
        LLDBToolCatalog.advertisedTools()
    }

    func routeToolCall(
        toolName: String,
        args: [String: Value]?
    ) async -> RouteResult<ToolCallResult>? {
        if toolName == LLDBToolCatalog.refreshToolName {
            let force = args?["force"]?.boolValue ?? false
            return .success(await refresh(force: force))
        }

        guard let downstreamName = LLDBToolCatalog.stableDownstreamName(from: toolName) else {
            return nil
        }

        let preparation = await prepareForOperation(autoRefreshWhenChanged: true)
        switch preparation {
        case .ready(let readyClient, let warning):
            guard let actualDownstreamName = LLDBToolCatalog.actualDownstreamName(
                for: downstreamName,
                availableToolNames: availableToolNames
            ) else {
                return .success(capabilityUnavailableResult(requestedToolName: downstreamName))
            }
            return .success(await callDownstreamTool(
                client: readyClient,
                downstreamName: actualDownstreamName,
                semanticName: downstreamName,
                args: args,
                warning: warning
            ))
        case .unsupported(let context):
            return .success(unsupportedToolResult(context))
        case .failed(let context, let message):
            return .success(errorToolResult(
                action: "failed",
                reason: context.reason,
                message: message,
                context: context
            ))
        }
    }

    func listResources() async -> [Resource] {
        let preparation = await prepareForOperation(autoRefreshWhenChanged: true)
        guard case .ready(let readyClient, _) = preparation else { return [] }

        do {
            let resources = try await readyClient.listResources()
            return resources.map { resource in
                Resource(
                    name: resource.name,
                    uri: LLDBToolCatalog.resourcePrefix + resource.uri,
                    title: resource.title,
                    description: resource.description,
                    mimeType: resource.mimeType,
                    size: resource.size,
                    annotations: resource.annotations,
                    icons: resource.icons,
                    _meta: resource._meta
                )
            }
        } catch {
            logger.warning("Unable to list LLDB resources", metadata: [
                "error": String(describing: error)
            ])
            return []
        }
    }

    func routeResourceRead(prefixedURI: String) async -> RouteResult<ResourceReadResult>? {
        guard prefixedURI.hasPrefix(LLDBToolCatalog.resourcePrefix) else { return nil }
        let originalURI = String(prefixedURI.dropFirst(LLDBToolCatalog.resourcePrefix.count))
        guard !originalURI.isEmpty else {
            return .failure(
                code: ErrorCodes.invalidParams,
                message: "Invalid LLDB resource URI: \(prefixedURI)"
            )
        }

        let preparation = await prepareForOperation(autoRefreshWhenChanged: true)
        switch preparation {
        case .ready(let readyClient, _):
            do {
                let contents = try await readyClient.readResource(uri: originalURI)
                return .success(ResourceReadResult(contents: contents))
            } catch {
                return .failure(
                    code: ErrorCodes.bridgeError,
                    message: "LLDB resource read failed: \(error)"
                )
            }
        case .unsupported(let context):
            return .failure(code: ErrorCodes.bridgeError, message: context.message)
        case .failed(_, let message):
            return .failure(code: ErrorCodes.bridgeError, message: message)
        }
    }

    func shutdown() async {
        if let transitionTask {
            let transition = await transitionTask.value
            apply(transition)
        }
        self.transitionTask = nil

        if let client {
            await client.stop()
        }
        _ = await registryManager.terminateOwnedBackendProcesses(
            Array(ownedBackendEntries.values)
        )
        _ = await registryManager.quarantineConfirmedStaleEntries()
        self.client = nil
        runtime = nil
        availableToolNames.removeAll()
        registrySnapshot = .empty
        ownedSessionURIs.removeAll()
        ownedBackendEntries.removeAll()
        untrackedOwnedSessionCount = 0
    }

    // MARK: - Refresh

    private func refresh(force: Bool) async -> ToolCallResult {
        let support = await resolveSupport()
        switch support {
        case .unsupported(let context):
            if ownedSessionCount > 0 {
                return reportToolResult(LLDBToolReport(
                    action: "blocked",
                    supported: false,
                    generation: generation,
                    reason: context.reason,
                    message: "\(context.message) The current adapter was preserved because this connection owns active LLDB sessions.",
                    xcodeVersion: context.xcodeVersion,
                    xcodeBuild: context.xcodeBuild,
                    xcodePath: context.xcodePath,
                    quarantinedRegistryEntries: [],
                    ownedSessions: Array(ownedSessionURIs).sorted(),
                    ownedSessionCount: ownedSessionCount,
                    destroyedOwnedSessionCount: 0,
                    sessions: []
                ))
            }
            if let client {
                await client.stop()
                _ = await registryManager.terminateOwnedBackendProcesses(
                    Array(ownedBackendEntries.values)
                )
                _ = await registryManager.quarantineConfirmedStaleEntries()
                self.client = nil
                runtime = nil
                availableToolNames.removeAll()
                registrySnapshot = .empty
                ownedBackendEntries.removeAll()
            }
            return reportToolResult(LLDBToolReport(
                action: "unsupported",
                supported: false,
                generation: generation,
                reason: context.reason,
                message: context.message,
                xcodeVersion: context.xcodeVersion,
                xcodeBuild: context.xcodeBuild,
                xcodePath: context.xcodePath,
                quarantinedRegistryEntries: [],
                ownedSessions: [],
                ownedSessionCount: 0,
                destroyedOwnedSessionCount: 0,
                sessions: []
            ))

        case .supported(let selectedRuntime):
            if activeCallCount > 0 {
                return blockedRefreshResult(
                    runtime: selectedRuntime,
                    message: "LLDB refresh is blocked while another LLDB operation is in progress. Retry after it completes."
                )
            }
            if ownedSessionCount > 0, !force {
                return blockedRefreshResult(
                    runtime: selectedRuntime,
                    message: "LLDB refresh would destroy sessions created by this MCP connection. Close them first or retry with force=true."
                )
            }

            let previousClientExisted = client != nil
            let previousFailure = lastFailure
            let destroyedOwnedSessionCount = force ? ownedSessionCount : 0
            let transition = await transition(to: selectedRuntime)
            switch transition {
            case .ready(_, let readyRuntime, let snapshot, _, _, let quarantinedEntries, _):
                let sessions = await listSessionsForReport()
                let action: String
                if !quarantinedEntries.isEmpty || previousFailure != nil {
                    action = "recovered"
                } else if previousClientExisted {
                    action = "restarted"
                } else {
                    action = "started"
                }
                registrySnapshot = snapshot
                return reportToolResult(LLDBToolReport(
                    action: action,
                    supported: true,
                    generation: generation,
                    reason: nil,
                    message: "LLDB MCP is ready and currently running sessions were rediscovered.",
                    xcodeVersion: readyRuntime.version,
                    xcodeBuild: readyRuntime.buildVersion,
                    xcodePath: readyRuntime.applicationURL.path,
                    quarantinedRegistryEntries: quarantinedEntries,
                    ownedSessions: [],
                    ownedSessionCount: 0,
                    destroyedOwnedSessionCount: destroyedOwnedSessionCount,
                    sessions: sessions
                ))
            case .failed(_, let context, let message, let quarantinedEntries, _):
                return reportToolResult(LLDBToolReport(
                    action: "failed",
                    supported: true,
                    generation: generation,
                    reason: context.reason,
                    message: message,
                    xcodeVersion: context.xcodeVersion,
                    xcodeBuild: context.xcodeBuild,
                    xcodePath: context.xcodePath,
                    quarantinedRegistryEntries: quarantinedEntries,
                    ownedSessions: [],
                    ownedSessionCount: 0,
                    destroyedOwnedSessionCount: destroyedOwnedSessionCount,
                    sessions: []
                ), isError: true)
            }
        }
    }

    // MARK: - Preparation

    private func prepareForOperation(autoRefreshWhenChanged: Bool) async -> Preparation {
        let support = await resolveSupport()
        switch support {
        case .unsupported(let context):
            if let client, ownedSessionCount > 0, await client.isRunning() {
                return .ready(
                    client,
                    "The selected Xcode no longer provides lldb-mcp. The existing adapter remains active to preserve sessions created by this connection."
                )
            }
            if let client {
                await client.stop()
                _ = await registryManager.terminateOwnedBackendProcesses(
                    Array(ownedBackendEntries.values)
                )
                _ = await registryManager.quarantineConfirmedStaleEntries()
                self.client = nil
                runtime = nil
                availableToolNames.removeAll()
                registrySnapshot = .empty
                ownedBackendEntries.removeAll()
            }
            return .unsupported(context)

        case .supported(let selectedRuntime):
            let currentSnapshot = await registryManager.snapshot()
            let runtimeChanged = runtime?.developerDirectoryURL != selectedRuntime.developerDirectoryURL
            let registryChanged = client != nil && currentSnapshot != registrySnapshot
            let adapterRunning = if let client { await client.isRunning() } else { false }
            let needsTransition = client == nil
                || !adapterRunning
                || runtimeChanged
                || (autoRefreshWhenChanged && registryChanged)

            guard needsTransition else {
                guard let client else {
                    return .failed(
                        LLDBSupportContext.runtime(selectedRuntime, reason: "lldb_adapter_unavailable"),
                        "LLDB MCP adapter is unavailable."
                    )
                }
                return .ready(client, nil)
            }

            if (ownedSessionCount > 0 || activeCallCount > 0),
               let client,
               adapterRunning
            {
                return .ready(
                    client,
                    "LLDB environment changed, but automatic refresh was deferred to preserve an active operation or an owned session. Call lldb_refresh_sessions after closing owned sessions."
                )
            }

            let transition = await transition(to: selectedRuntime)
            switch transition {
            case .ready(let readyClient, _, _, _, _, _, _):
                return .ready(readyClient, nil)
            case .failed(_, let context, let message, _, _):
                return .failed(context, message)
            }
        }
    }

    private func resolveSupport() async -> SupportResolution {
        do {
            let selectedRuntime = try await runtimeResolver.resolve(
                developerDirectoryOverride: developerDirectoryOverride
            )
            let executableURL = selectedRuntime.developerDirectoryURL
                .appendingPathComponent("usr", isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("lldb-mcp")

            guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
                let majorVersion = Self.majorVersion(from: selectedRuntime.version)
                let reason = majorVersion.map { $0 < 27 } == true
                    ? "xcode_version_unsupported"
                    : "lldb_mcp_missing"
                let message = majorVersion.map { $0 < 27 } == true
                    ? "Selected Xcode \(selectedRuntime.version) does not provide lldb-mcp. Xcode 27 or newer is required. Existing Xcode project, build, and test tools remain available."
                    : "Selected Xcode \(selectedRuntime.version) does not contain an executable lldb-mcp. Existing Xcode tools remain available."
                return .unsupported(LLDBSupportContext.runtime(
                    selectedRuntime,
                    reason: reason,
                    message: message
                ))
            }
            return .supported(selectedRuntime)
        } catch {
            return .unsupported(LLDBSupportContext(
                reason: "xcode_unavailable",
                message: "Unable to select an Xcode installation for LLDB MCP: \(error.localizedDescription)",
                xcodeVersion: nil,
                xcodeBuild: nil,
                xcodePath: nil
            ))
        }
    }

    // MARK: - Adapter Transition

    private func transition(to selectedRuntime: XcodeRuntime) async -> AdapterTransition {
        if let transitionTask {
            let transition = await transitionTask.value
            apply(transition)
            return transition
        }

        let identifier = UUID()
        let previousClient = client
        let previousOwnedBackendEntries = Array(ownedBackendEntries.values)
        client = nil
        runtime = nil
        availableToolNames.removeAll()
        registrySnapshot = .empty
        ownedBackendEntries.removeAll()

        let registryManager = self.registryManager
        let clientFactory = self.clientFactory
        let task = Task<AdapterTransition, Never> {
            if let previousClient {
                await previousClient.stop()
            }
            _ = await registryManager.terminateOwnedBackendProcesses(
                previousOwnedBackendEntries
            )

            let quarantinedEntries = await registryManager.quarantineConfirmedStaleEntries()
            let snapshotBeforeStart = await registryManager.snapshot()
            let nextClient = clientFactory(selectedRuntime)
            do {
                try await nextClient.start()
                let tools = try await nextClient.listTools()
                let snapshot = await registryManager.snapshot()
                let ownedBackends = snapshot.backendsSpawnedByMultiplexer(
                    since: snapshotBeforeStart
                )
                return .ready(
                    nextClient,
                    selectedRuntime,
                    snapshot,
                    Set(tools.map(\.name)),
                    ownedBackends,
                    quarantinedEntries,
                    identifier
                )
            } catch {
                await nextClient.stop()
                let snapshotAfterFailure = await registryManager.snapshot()
                let ownedBackends = snapshotAfterFailure.backendsSpawnedByMultiplexer(
                    since: snapshotBeforeStart
                )
                _ = await registryManager.terminateOwnedBackendProcesses(ownedBackends)
                let context = LLDBSupportContext.runtime(
                    selectedRuntime,
                    reason: "lldb_adapter_start_failed"
                )
                return .failed(
                    selectedRuntime,
                    context,
                    "Unable to start lldb-mcp from Xcode \(selectedRuntime.version): \(error.localizedDescription)",
                    quarantinedEntries,
                    identifier
                )
            }
        }
        transitionTask = task

        let transition = await task.value
        apply(transition)
        if appliedTransitionIdentifier == identifier {
            transitionTask = nil
        }
        return transition
    }

    private func apply(_ transition: AdapterTransition) {
        guard appliedTransitionIdentifier != transition.identifier else { return }
        appliedTransitionIdentifier = transition.identifier

        switch transition {
        case .ready(
            let readyClient,
            let readyRuntime,
            let snapshot,
            let toolNames,
            let ownedBackends,
            _,
            _
        ):
            client = readyClient
            runtime = readyRuntime
            registrySnapshot = snapshot
            availableToolNames = toolNames
            ownedBackendEntries = Dictionary(
                uniqueKeysWithValues: ownedBackends.compactMap { entry in
                    entry.processIdentifier.map { ($0, entry) }
                }
            )
            ownedSessionURIs.removeAll()
            untrackedOwnedSessionCount = 0
            generation += 1
            lastFailure = nil
        case .failed(_, _, let message, _, _):
            client = nil
            runtime = nil
            registrySnapshot = .empty
            availableToolNames.removeAll()
            ownedBackendEntries.removeAll()
            ownedSessionURIs.removeAll()
            untrackedOwnedSessionCount = 0
            lastFailure = message
        }
    }

    // MARK: - Downstream Calls

    private func callDownstreamTool(
        client: any LLDBMCPClient,
        downstreamName: String,
        semanticName: String,
        args: [String: Value]?,
        warning: String?
    ) async -> ToolCallResult {
        activeCallCount += 1
        let snapshotBeforeCall = semanticName == "session_create"
            ? await registryManager.snapshot()
            : nil
        do {
            var result = try await client.callTool(name: downstreamName, arguments: args)
            activeCallCount -= 1

            if result.isError != true {
                trackOwnershipAfterSuccessfulCall(
                    downstreamName: semanticName,
                    args: args,
                    content: result.content
                )
                if let snapshotBeforeCall {
                    let snapshotAfterCall = await registryManager.snapshot()
                    for entry in snapshotAfterCall.backendsSpawnedByMultiplexer(
                        since: snapshotBeforeCall
                    ) {
                        if let processIdentifier = entry.processIdentifier {
                            ownedBackendEntries[processIdentifier] = entry
                        }
                    }
                    registrySnapshot = snapshotAfterCall
                }
            }
            if let warning {
                result = LLDBToolResponse(
                    content: result.content + [LLDBToolCatalog.textContent("Warning: \(warning)")],
                    isError: result.isError
                )
            }
            return ToolCallResult(content: result.content, isError: result.isError)
        } catch {
            activeCallCount -= 1
            return errorToolResult(
                action: "failed",
                reason: "lldb_tool_call_failed",
                message: "LLDB tool '\(downstreamName)' failed: \(error.localizedDescription)"
            )
        }
    }

    private func trackOwnershipAfterSuccessfulCall(
        downstreamName: String,
        args: [String: Value]?,
        content: [Tool.Content]
    ) {
        switch downstreamName {
        case "session_create":
            if let sessionURI = LLDBToolCatalog.sessionURIs(from: content).first {
                ownedSessionURIs.insert(sessionURI)
            } else {
                untrackedOwnedSessionCount += 1
            }
        case "session_close":
            if let sessionURI = args?["session"]?.stringValue,
               ownedSessionURIs.remove(sessionURI) != nil
            {
                return
            }
            if untrackedOwnedSessionCount > 0 {
                untrackedOwnedSessionCount -= 1
            }
        default:
            break
        }
    }

    private func listSessionsForReport() async -> [String] {
        guard let client,
              let downstreamName = LLDBToolCatalog.actualDownstreamName(
                  for: "sessions_list",
                  availableToolNames: availableToolNames
              )
        else {
            return []
        }
        do {
            let result = try await client.callTool(name: downstreamName, arguments: nil)
            return LLDBToolCatalog.sessionURIs(from: result.content)
        } catch {
            logger.warning("Unable to list LLDB sessions after refresh", metadata: [
                "error": String(describing: error)
            ])
            return []
        }
    }

    // MARK: - Results

    private var ownedSessionCount: Int {
        ownedSessionURIs.count + untrackedOwnedSessionCount
    }

    private func blockedRefreshResult(runtime: XcodeRuntime, message: String) -> ToolCallResult {
        reportToolResult(LLDBToolReport(
            action: "blocked",
            supported: true,
            generation: generation,
            reason: "active_owned_sessions",
            message: message,
            xcodeVersion: runtime.version,
            xcodeBuild: runtime.buildVersion,
            xcodePath: runtime.applicationURL.path,
            quarantinedRegistryEntries: [],
            ownedSessions: Array(ownedSessionURIs).sorted(),
            ownedSessionCount: ownedSessionCount,
            destroyedOwnedSessionCount: 0,
            sessions: []
        ))
    }

    private func unsupportedToolResult(_ context: LLDBSupportContext) -> ToolCallResult {
        errorToolResult(
            action: "unsupported",
            reason: context.reason,
            message: context.message,
            context: context,
            supported: false
        )
    }

    private func capabilityUnavailableResult(requestedToolName: String) -> ToolCallResult {
        let available = availableToolNames.sorted()
        let selectedVersion = runtime?.version ?? "unknown"
        let message: String
        if availableToolNames.contains("debugger_list"),
           !availableToolNames.contains("sessions_list")
        {
            message = "Selected Xcode \(selectedVersion) contains the early lldb-mcp tool set [\(available.joined(separator: ", "))]. The '\(requestedToolName)' capability is not available in this build. Existing Xcode-attached debugger sessions can still be listed with lldb__sessions_list and controlled with lldb__command."
        } else {
            message = "Selected Xcode \(selectedVersion) lldb-mcp does not expose the '\(requestedToolName)' capability. Available downstream tools: [\(available.joined(separator: ", "))]."
        }
        return errorToolResult(
            action: "unavailable",
            reason: "lldb_capability_unavailable",
            message: message,
            context: runtime.map {
                LLDBSupportContext.runtime($0, reason: "lldb_capability_unavailable", message: message)
            }
        )
    }

    private func errorToolResult(
        action: String,
        reason: String,
        message: String,
        context: LLDBSupportContext? = nil,
        supported: Bool = true
    ) -> ToolCallResult {
        reportToolResult(LLDBToolReport(
            action: action,
            supported: supported,
            generation: generation,
            reason: reason,
            message: message,
            xcodeVersion: context?.xcodeVersion,
            xcodeBuild: context?.xcodeBuild,
            xcodePath: context?.xcodePath,
            quarantinedRegistryEntries: [],
            ownedSessions: Array(ownedSessionURIs).sorted(),
            ownedSessionCount: ownedSessionCount,
            destroyedOwnedSessionCount: 0,
            sessions: []
        ), isError: true)
    }

    private func reportToolResult(_ report: LLDBToolReport, isError: Bool = false) -> ToolCallResult {
        report.toolResult(isError: isError)
    }

    // MARK: - Helpers

    private nonisolated static func majorVersion(from version: String) -> Int? {
        let component = version.split(separator: ".", maxSplits: 1).first
        return component.flatMap { Int($0) }
    }

}

private extension LLDBSessionController {
    enum Preparation {
        case ready(any LLDBMCPClient, String?)
        case unsupported(LLDBSupportContext)
        case failed(LLDBSupportContext, String)
    }

    enum SupportResolution {
        case supported(XcodeRuntime)
        case unsupported(LLDBSupportContext)
    }

    enum AdapterTransition: Sendable {
        case ready(
            any LLDBMCPClient,
            XcodeRuntime,
            LLDBRegistrySnapshot,
            Set<String>,
            [LLDBRegistryEntry],
            [String],
            UUID
        )
        case failed(XcodeRuntime, LLDBSupportContext, String, [String], UUID)

        var identifier: UUID {
            switch self {
            case .ready(_, _, _, _, _, _, let identifier),
                 .failed(_, _, _, _, let identifier):
                identifier
            }
        }
    }

}
