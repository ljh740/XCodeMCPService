import Foundation
import Logging

// MARK: - FileLogHandler

/// 将日志写入文件的 LogHandler
struct FileLogHandler: LogHandler {
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info

    private let label: String
    private let writer: DailyRollingFileWriter

    init(label: String, writer: DailyRollingFileWriter) {
        self.label = label
        self.writer = writer
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
        writer.write(
            label: label,
            level: level,
            message: message,
            metadata: metadata,
            baseMetadata: self.metadata
        )
    }
}

// MARK: - Bootstrap

/// 全局初始化一次：注册 MultiplexLogHandler（stderr + 文件）
private let bootstrapOnce: Void = {
    LoggingSystem.bootstrap { label in
        var handlers: [LogHandler] = [
            StreamLogHandler.standardError(label: label)
        ]
        handlers.append(FileLogHandler(label: label, writer: sharedLogFileWriter))
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
