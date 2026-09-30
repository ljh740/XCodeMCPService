import Foundation

// MARK: - DeviceUseGate

/// 判断一次工具调用何时真正需要使用真机。
public protocol DeviceUseGate: Sendable {
    /// 挂起直到 Xcode 需要使用设备；无法判断时立即返回。任务取消时抛出 `CancellationError`。
    func waitUntilDeviceNeeded(workspacePath: String?, since: Date) async throws
}

// MARK: - DerivedDataBuildGate

/// 以本次调用开始后出现的新构建日志作为构建完成的信号。
///
/// Xcode 在构建结束时向 `DerivedData/<Workspace>-<hash>/Logs/Build/` 写入 `.xcactivitylog`；
/// 此前处于编译阶段，设备即使锁定也不会阻塞，此后才开始安装、启动并需要设备解锁。
public struct DerivedDataBuildGate: DeviceUseGate {
    private let derivedDataRoot: URL
    private let pollInterval: Duration

    public init(
        derivedDataRoot: URL = Self.defaultDerivedDataRoot(),
        pollInterval: Duration = .seconds(2)
    ) {
        self.derivedDataRoot = derivedDataRoot
        self.pollInterval = pollInterval
    }

    public func waitUntilDeviceNeeded(workspacePath: String?, since: Date) async throws {
        guard let workspacePath,
            let buildLogDirectory = buildLogDirectory(forWorkspace: workspacePath)
        else {
            return
        }
        while !hasBuildLog(in: buildLogDirectory, since: since) {
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Xcode 的 DerivedData 位置：优先使用偏好设置中的自定义路径。
    public static func defaultDerivedDataRoot() -> URL {
        if let custom = UserDefaults(suiteName: "com.apple.dt.Xcode")?
            .string(forKey: "IDECustomDerivedDataLocation"),
            !custom.isEmpty
        {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
    }

    /// 按各目录 `info.plist` 中的 `WorkspacePath` 找到该 workspace 的构建日志目录。
    func buildLogDirectory(forWorkspace workspacePath: String) -> URL? {
        let target = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: derivedDataRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        for directory in candidates {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("info.plist")),
                let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let path = info["WorkspacePath"] as? String,
                URL(fileURLWithPath: path).standardizedFileURL.path == target
            else {
                continue
            }
            return directory.appendingPathComponent("Logs/Build", isDirectory: true)
        }
        return nil
    }

    func hasBuildLog(in directory: URL, since: Date) -> Bool {
        let logs = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return logs.contains { url in
            guard url.pathExtension == "xcactivitylog",
                let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
            else {
                return false
            }
            return modified >= since
        }
    }
}
