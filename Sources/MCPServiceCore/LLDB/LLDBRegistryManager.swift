import Darwin
import Foundation
import Network
import os

struct LLDBRegistryEntry: Sendable, Equatable {
    let fileURL: URL
    let processIdentifier: Int32?
    let connectionURI: String?
    let contents: String
    let processExecutablePath: String?
    let parentProcessIdentifier: Int32?
    let parentProcessExecutablePath: String?

    init(
        fileURL: URL,
        processIdentifier: Int32?,
        connectionURI: String?,
        contents: String,
        processExecutablePath: String? = nil,
        parentProcessIdentifier: Int32? = nil,
        parentProcessExecutablePath: String? = nil
    ) {
        self.fileURL = fileURL
        self.processIdentifier = processIdentifier
        self.connectionURI = connectionURI
        self.contents = contents
        self.processExecutablePath = processExecutablePath
        self.parentProcessIdentifier = parentProcessIdentifier
        self.parentProcessExecutablePath = parentProcessExecutablePath
    }

    var belongsToLLDBMultiplexer: Bool {
        guard let processExecutablePath else { return false }
        return URL(fileURLWithPath: processExecutablePath).lastPathComponent == "lldb-mcp"
    }

    var wasSpawnedByLLDBMultiplexer: Bool {
        guard let parentProcessExecutablePath else { return false }
        return URL(fileURLWithPath: parentProcessExecutablePath).lastPathComponent == "lldb-mcp"
    }
}

struct LLDBRegistrySnapshot: Sendable, Equatable {
    let entries: [LLDBRegistryEntry]

    static let empty = LLDBRegistrySnapshot(entries: [])

    static func == (lhs: LLDBRegistrySnapshot, rhs: LLDBRegistrySnapshot) -> Bool {
        lhs.refreshRelevantEntries == rhs.refreshRelevantEntries
    }

    private var refreshRelevantEntries: [LLDBRegistryEntry] {
        entries.filter { !$0.belongsToLLDBMultiplexer }
    }

    func backendsSpawnedByMultiplexer(since previous: LLDBRegistrySnapshot) -> [LLDBRegistryEntry] {
        let previousProcessIdentifiers = Set(previous.entries.compactMap(\.processIdentifier))
        return entries.filter { entry in
            guard let processIdentifier = entry.processIdentifier else { return false }
            return !previousProcessIdentifiers.contains(processIdentifier)
                && entry.wasSpawnedByLLDBMultiplexer
        }
    }
}

protocol LLDBRegistryManaging: Sendable {
    func snapshot() async -> LLDBRegistrySnapshot
    func quarantineConfirmedStaleEntries() async -> [String]
    func terminateOwnedBackendProcesses(_ entries: [LLDBRegistryEntry]) async -> [Int32]
}

protocol LLDBProcessChecking: Sendable {
    func isProcessRunning(_ processIdentifier: Int32) -> Bool
    func executablePath(for processIdentifier: Int32) -> String?
    func parentProcessIdentifier(for processIdentifier: Int32) -> Int32?
}

struct DefaultLLDBProcessChecker: LLDBProcessChecking, Sendable {
    func isProcessRunning(_ processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0 else { return false }
        if kill(pid_t(processIdentifier), 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    func executablePath(for processIdentifier: Int32) -> String? {
        guard processIdentifier > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let terminatorIndex = buffer.firstIndex(of: 0) ?? min(Int(length), buffer.count)
        let bytes = buffer[..<terminatorIndex].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    func parentProcessIdentifier(for processIdentifier: Int32) -> Int32? {
        guard processIdentifier > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout.size(ofValue: info))
        )
        guard size == MemoryLayout.size(ofValue: info) else { return nil }
        return Int32(info.pbi_ppid)
    }
}

protocol LLDBConnectionChecking: Sendable {
    func isReachable(connectionURI: String) async -> Bool
}

struct DefaultLLDBConnectionChecker: LLDBConnectionChecking, Sendable {
    private let timeoutMilliseconds: Int

    init(timeoutMilliseconds: Int = 250) {
        self.timeoutMilliseconds = max(timeoutMilliseconds, 1)
    }

    func isReachable(connectionURI: String) async -> Bool {
        guard let components = URLComponents(string: connectionURI),
              components.scheme == "connection",
              let rawHost = components.host,
              let portValue = components.port,
              let rawPort = UInt16(exactly: portValue),
              let port = NWEndpoint.Port(rawValue: rawPort)
        else {
            return false
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return false }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: port,
                using: .tcp
            )
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let queue = DispatchQueue(label: "com.ljh740.XCodeMCPService.lldb-registry-probe")

            let finish: @Sendable (Bool) -> Void = { reachable in
                let shouldResume = resumed.withLock { value -> Bool in
                    guard !value else { return false }
                    value = true
                    return true
                }
                guard shouldResume else { return }
                connection.cancel()
                continuation.resume(returning: reachable)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds)) {
                finish(false)
            }
        }
    }
}

struct DefaultLLDBRegistryManager: LLDBRegistryManaging, Sendable {
    private let directoryURL: URL
    private let processChecker: any LLDBProcessChecking
    private let connectionChecker: any LLDBConnectionChecking

    init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lldb", isDirectory: true),
        processChecker: any LLDBProcessChecking = DefaultLLDBProcessChecker(),
        connectionChecker: any LLDBConnectionChecking = DefaultLLDBConnectionChecker()
    ) {
        self.directoryURL = directoryURL
        self.processChecker = processChecker
        self.connectionChecker = connectionChecker
    }

    func snapshot() async -> LLDBRegistrySnapshot {
        LLDBRegistrySnapshot(entries: readEntries())
    }

    func quarantineConfirmedStaleEntries() async -> [String] {
        let entries = readEntries()
        var quarantined: [String] = []

        for entry in entries {
            guard let processIdentifier = entry.processIdentifier,
                  !processChecker.isProcessRunning(processIdentifier)
            else {
                continue
            }

            if let connectionURI = entry.connectionURI,
               await connectionChecker.isReachable(connectionURI: connectionURI)
            {
                continue
            }

            do {
                let destinationURL = try quarantineDestination(for: entry.fileURL)
                try FileManager.default.moveItem(at: entry.fileURL, to: destinationURL)
                quarantined.append(destinationURL.path)
            } catch CocoaError.fileNoSuchFile {
                // 另一个会话可能已经完成隔离。
                continue
            } catch {
                bridgeLogger.warning("Unable to quarantine stale LLDB registry entry", metadata: [
                    "path": entry.fileURL.path,
                    "error": String(describing: error),
                ])
            }
        }

        return quarantined.sorted()
    }

    func terminateOwnedBackendProcesses(_ entries: [LLDBRegistryEntry]) async -> [Int32] {
        var terminated: [Int32] = []

        for entry in entries {
            guard entry.wasSpawnedByLLDBMultiplexer,
                  let processIdentifier = entry.processIdentifier,
                  processChecker.isProcessRunning(processIdentifier),
                  let capturedExecutablePath = entry.processExecutablePath,
                  URL(fileURLWithPath: capturedExecutablePath).lastPathComponent == "lldb",
                  processChecker.executablePath(for: processIdentifier) == capturedExecutablePath
            else {
                continue
            }

            kill(pid_t(processIdentifier), SIGTERM)
            for _ in 0..<20 where processChecker.isProcessRunning(processIdentifier) {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if processChecker.isProcessRunning(processIdentifier) {
                kill(pid_t(processIdentifier), SIGKILL)
                for _ in 0..<10 where processChecker.isProcessRunning(processIdentifier) {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            terminated.append(processIdentifier)
        }

        return terminated.sorted()
    }

    private func readEntries() -> [LLDBRegistryEntry] {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return fileURLs.compactMap { fileURL in
            guard let processIdentifier = Self.processIdentifier(from: fileURL.lastPathComponent)
            else {
                return nil
            }

            let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let parentProcessIdentifier = processChecker.parentProcessIdentifier(
                for: processIdentifier
            )
            return LLDBRegistryEntry(
                fileURL: fileURL,
                processIdentifier: processIdentifier,
                connectionURI: Self.connectionURI(from: contents),
                contents: contents,
                processExecutablePath: processChecker.executablePath(for: processIdentifier),
                parentProcessIdentifier: parentProcessIdentifier,
                parentProcessExecutablePath: parentProcessIdentifier.flatMap(
                    processChecker.executablePath(for:)
                )
            )
        }
        .sorted { $0.fileURL.lastPathComponent < $1.fileURL.lastPathComponent }
    }

    private func quarantineDestination(for sourceURL: URL) throws -> URL {
        let quarantineDirectoryURL = directoryURL
            .appendingPathComponent("XCodeMCPService-Stale", isDirectory: true)
        try FileManager.default.createDirectory(
            at: quarantineDirectoryURL,
            withIntermediateDirectories: true
        )
        return quarantineDirectoryURL.appendingPathComponent(
            "\(sourceURL.lastPathComponent).stale-\(UUID().uuidString)"
        )
    }

    private static func processIdentifier(from fileName: String) -> Int32? {
        let prefix = "lldb-mcp-"
        let suffix = ".json"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return nil }
        let start = fileName.index(fileName.startIndex, offsetBy: prefix.count)
        let end = fileName.index(fileName.endIndex, offsetBy: -suffix.count)
        return Int32(fileName[start..<end])
    }

    private static func connectionURI(from contents: String) -> String? {
        guard let data = contents.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object["connection_uri"] as? String
    }
}
