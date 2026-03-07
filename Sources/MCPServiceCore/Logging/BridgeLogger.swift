import Foundation
import Logging

// MARK: - FileLogHandler

/// 日志时间戳格式（值类型，线程安全）
private let logDateFormatStyle = Date.ISO8601FormatStyle(
    dateSeparator: .dash,
    dateTimeSeparator: .standard,
    timeSeparator: .colon,
    timeZoneSeparator: .omitted,
    includingFractionalSeconds: true
)

/// 将日志写入文件的 LogHandler
struct FileLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info

    private let label: String
    private let fileHandle: FileHandle

    init(label: String, fileHandle: FileHandle) {
        self.label = label
        self.fileHandle = fileHandle
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let timestamp = Date.now.formatted(logDateFormatStyle)
        let merged = self.metadata.merging(metadata ?? [:]) { _, new in new }
        let metaStr = merged.isEmpty ? "" : " \(merged.map { "\($0)=\($1)" }.joined(separator: " "))"
        let text = "\(timestamp) [\(level)] [\(label)] \(message)\(metaStr)\n"
        if let data = text.data(using: .utf8) {
            fileHandle.write(data)
        }
    }
}

// MARK: - Log Directory

/// 日志目录：~/Library/Application Support/XCodeMCPService/logs/
public let logDirectory: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Application Support/XCodeMCPService/logs"
}()

/// 创建日志文件并返回 FileHandle，失败返回 nil
private func createLogFileHandle() -> FileHandle? {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: logDirectory, withIntermediateDirectories: true)

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let dateStr = formatter.string(from: Date())
    let logPath = "\(logDirectory)/\(dateStr).log"

    if !fm.fileExists(atPath: logPath) {
        fm.createFile(atPath: logPath, contents: nil)
    }
    return FileHandle(forWritingAtPath: logPath).map { handle in
        handle.seekToEndOfFile()
        return handle
    }
}

// MARK: - Bootstrap

/// 全局初始化一次：注册 MultiplexLogHandler（stderr + 文件）
private let bootstrapOnce: Void = {
    let fileHandle = createLogFileHandle()
    LoggingSystem.bootstrap { label in
        var handlers: [LogHandler] = [
            StreamLogHandler.standardError(label: label)
        ]
        if let fileHandle {
            handlers.append(FileLogHandler(label: label, fileHandle: fileHandle))
        }
        return MultiplexLogHandler(handlers)
    }
}()

// MARK: - BridgeLogger

/// 基于 swift-log 的日志封装
public struct BridgeLogger: Sendable {
    private var logger: Logger

    public init(label: String = "mcp-forward") {
        _ = bootstrapOnce
        self.logger = Logger(label: label)
    }

    /// 创建子 logger，label 格式为 `父label.子label`
    public func child(label: String) -> BridgeLogger {
        BridgeLogger(label: "\(logger.label).\(label)")
    }

    public func debug(_ message: String, metadata: [String: String]? = nil) {
        logger.debug("\(message)", metadata: metadata?.loggerMetadata)
    }

    public func info(_ message: String, metadata: [String: String]? = nil) {
        logger.info("\(message)", metadata: metadata?.loggerMetadata)
    }

    public func warning(_ message: String, metadata: [String: String]? = nil) {
        logger.warning("\(message)", metadata: metadata?.loggerMetadata)
    }

    public func error(_ message: String, metadata: [String: String]? = nil) {
        logger.error("\(message)", metadata: metadata?.loggerMetadata)
    }

    public mutating func setLogLevel(_ level: Logger.Level) {
        logger.logLevel = level
    }
}

// MARK: - Metadata Conversion

extension [String: String] {
    fileprivate var loggerMetadata: Logger.Metadata {
        mapValues { Logger.MetadataValue.string($0) }
    }
}

// MARK: - Global Instance

/// 全局便捷日志实例
public let bridgeLogger = BridgeLogger()
