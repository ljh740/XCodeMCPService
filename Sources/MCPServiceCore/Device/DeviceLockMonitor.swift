import Foundation

// MARK: - DeviceLockEvent

/// 真机锁屏状态事件，供上层（状态栏）发出或回收提醒。
public enum DeviceLockEvent: Sendable, Equatable {
    /// 设备处于锁定状态，需要用户解锁
    case locked(deviceName: String)
    /// 设备已解锁，或已不再需要该设备
    case cleared(deviceName: String)
}

// MARK: - Lock State Provider

public protocol DeviceLockStateProviding: Sendable {
    /// 返回设备当前是否锁定（需要输入密码）。
    func isLocked(deviceName: String) async throws -> Bool
}

public enum DeviceLockStateError: Error, LocalizedError, Sendable {
    case commandFailed(status: Int32, message: String)
    case invalidResponse(String)
    case timedOut(milliseconds: Int)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let status, let message):
            return "devicectl lockState failed with exit code \(status): \(message)"
        case .invalidResponse(let message):
            return "Unable to decode devicectl lockState: \(message)"
        case .timedOut(let milliseconds):
            return "devicectl lockState timed out after \(milliseconds)ms"
        }
    }
}

/// 通过 `xcrun devicectl device info lockState` 查询真机锁屏状态。
public struct DevicectlLockStateProvider: DeviceLockStateProviding, Sendable {
    private let timeoutMilliseconds: Int

    public init(timeoutMilliseconds: Int = 5000) {
        self.timeoutMilliseconds = max(timeoutMilliseconds, 1)
    }

    public func isLocked(deviceName: String) async throws -> Bool {
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "info", "lockState", "--device", deviceName, "-j", "-"]
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(timeoutMilliseconds))
        do {
            while process.isRunning {
                if clock.now >= deadline {
                    process.terminate()
                    outputPipe.fileHandleForReading.closeFile()
                    throw DeviceLockStateError.timedOut(milliseconds: timeoutMilliseconds)
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        return try Self.decodeLockState(outputData, terminationStatus: process.terminationStatus)
    }

    static func decodeLockState(_ data: Data, terminationStatus: Int32) throws -> Bool {
        let payload: LockStatePayload
        do {
            payload = try JSONDecoder().decode(LockStatePayload.self, from: data)
        } catch {
            guard terminationStatus == 0 else {
                throw DeviceLockStateError.commandFailed(status: terminationStatus, message: "unknown error")
            }
            throw DeviceLockStateError.invalidResponse(String(describing: error))
        }
        guard payload.info.outcome == "success", let result = payload.result else {
            throw DeviceLockStateError.commandFailed(
                status: terminationStatus,
                message: payload.error?.userInfo?.NSLocalizedDescription?.string ?? payload.info.outcome
            )
        }
        return result.passcodeRequired
    }

    private struct LockStatePayload: Decodable {
        struct Info: Decodable {
            let outcome: String
        }

        struct Result: Decodable {
            let passcodeRequired: Bool
        }

        struct ErrorPayload: Decodable {
            struct UserInfo: Decodable {
                struct Description: Decodable {
                    let string: String?
                }

                let NSLocalizedDescription: Description?
            }

            let userInfo: UserInfo?
        }

        let info: Info
        let result: Result?
        let error: ErrorPayload?
    }
}

// MARK: - Run Destination

/// 从 Xcode 的运行目标中识别需要盯锁屏状态的真机。
enum DeviceRunDestination {
    /// 调用期间需要真机保持解锁的上游工具。
    static let watchedToolNames: Set<String> = ["RunAllTests", "RunSomeTests", "RunProject"]

    /// 查询运行目标的上游工具。
    static let listToolName = "XcodeListRunDestinations"

    /// 列出已打开 workspace 的上游工具。
    static let listWorkspacesToolName = "XcodeListWorkspaces"

    /// 解析 `XcodeListWorkspaces` 的文本，得到指定 workspace 的路径；
    /// 未指定标识时仅在唯一打开的 workspace 下返回其路径。
    static func workspacePath(identifier: String?, fromListOutput text: String) -> String? {
        let entries: [(identifier: String, path: String)] = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                guard let idRange = line.range(of: "workspaceIdentifier: "),
                    let pathRange = line.range(of: ", workspacePath: ")
                else {
                    return nil
                }
                let identifier = String(line[idRange.upperBound..<pathRange.lowerBound])
                let path = String(line[pathRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                return (identifier, path)
            }
        guard let identifier else {
            return entries.count == 1 ? entries[0].path : nil
        }
        return entries.first { $0.identifier == identifier }?.path
    }

    /// 解析 `XcodeListRunDestinations` 的 JSON 文本，活跃目标是 iOS 系真机时返回其名称。
    static func activePhysicalDeviceName(fromListOutput text: String) -> String? {
        struct Payload: Decodable {
            struct Destination: Decodable {
                let displayTitle: String
                let isActive: Bool
                let isSimulator: Bool
                let isGenericDevice: Bool
                let platformIdentifier: String?
            }

            let destinations: [Destination]
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(text.utf8)),
            let active = payload.destinations.first(where: \.isActive),
            !active.isSimulator,
            !active.isGenericDevice,
            active.platformIdentifier != "com.apple.platform.macosx"
        else {
            return nil
        }
        return active.displayTitle
    }
}

// MARK: - DeviceLockMonitor

/// 在工具调用期间轮询真机锁屏状态，设备持续锁定超过宽限期才发出 `locked`。
///
/// 测试在真机上正常执行时，devicectl 也会短暂报告锁定（实测连续不超过约 16 秒），
/// 只有持续锁定才说明 Xcode 在等待解锁；任一次读到解锁即重新计时并回收提醒。
///
/// 同一设备的多个并发调用共享一个轮询任务；最后一个调用结束时停止轮询，
/// 若此前报告过锁定则补发 `cleared`，保证上层提醒总能被回收。
public actor DeviceLockMonitor {

    private struct Poller {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let provider: any DeviceLockStateProviding
    private let pollInterval: Duration
    private let lockedGracePeriod: Duration
    private let onEvent: @Sendable (DeviceLockEvent) -> Void
    private let logger: BridgeLogger

    private var watchers: [UUID: String] = [:]
    private var pollers: [String: Poller] = [:]
    /// 设备本轮连续锁定的起始时间
    private var lockedSince: [String: ContinuousClock.Instant] = [:]
    /// 已发出 `locked` 的设备
    private var alertedDevices: Set<String> = []

    public init(
        provider: any DeviceLockStateProviding = DevicectlLockStateProvider(),
        pollInterval: Duration = .seconds(3),
        lockedGracePeriod: Duration = .seconds(30),
        onEvent: @escaping @Sendable (DeviceLockEvent) -> Void
    ) {
        self.provider = provider
        self.pollInterval = pollInterval
        self.lockedGracePeriod = lockedGracePeriod
        self.onEvent = onEvent
        self.logger = bridgeLogger.child(label: "device-lock-monitor")
    }

    /// 开始关注设备，返回的 token 用于 `unregister`。
    public func register(deviceName: String) -> UUID {
        let token = UUID()
        watchers[token] = deviceName
        if pollers[deviceName] == nil {
            let pollerID = UUID()
            let task = Task { await self.poll(deviceName: deviceName, pollerID: pollerID) }
            pollers[deviceName] = Poller(id: pollerID, task: task)
        }
        return token
    }

    /// 结束一次关注；设备无人关注时停止轮询并回收锁定提醒。
    public func unregister(_ token: UUID) {
        guard let deviceName = watchers.removeValue(forKey: token),
            !watchers.values.contains(deviceName)
        else {
            return
        }
        stopPolling(deviceName: deviceName)
    }

    /// 停止所有轮询并回收所有锁定提醒。
    public func shutdown() {
        watchers.removeAll()
        for deviceName in Array(pollers.keys) {
            stopPolling(deviceName: deviceName)
        }
    }

    private func stopPolling(deviceName: String) {
        pollers.removeValue(forKey: deviceName)?.task.cancel()
        lockedSince.removeValue(forKey: deviceName)
        if alertedDevices.remove(deviceName) != nil {
            onEvent(.cleared(deviceName: deviceName))
        }
    }

    /// 停止轮询时任务被取消，sleep 抛出 CancellationError 即结束循环
    private func poll(deviceName: String, pollerID: UUID) async {
        repeat {
            do {
                let locked = try await provider.isLocked(deviceName: deviceName)
                apply(locked: locked, deviceName: deviceName, pollerID: pollerID)
            } catch {
                // 查询失败时保持当前状态，下一轮继续尝试
                logger.debug("Device lock state query failed", metadata: [
                    "device": deviceName,
                    "error": "\(error)",
                ])
            }
        } while (try? await Task.sleep(for: pollInterval)) != nil
    }

    private func apply(locked: Bool, deviceName: String, pollerID: UUID) {
        // 丢弃已停止或已被替换的轮询任务迟到的结果
        guard pollers[deviceName]?.id == pollerID else { return }

        if locked {
            let now = ContinuousClock.now
            let since = lockedSince[deviceName] ?? now
            lockedSince[deviceName] = since
            guard now - since >= lockedGracePeriod,
                alertedDevices.insert(deviceName).inserted
            else {
                return
            }
            logger.warning("Device is locked, waiting for unlock", metadata: ["device": deviceName])
            onEvent(.locked(deviceName: deviceName))
        } else {
            lockedSince.removeValue(forKey: deviceName)
            guard alertedDevices.remove(deviceName) != nil else { return }
            logger.info("Device unlocked", metadata: ["device": deviceName])
            onEvent(.cleared(deviceName: deviceName))
        }
    }
}
