import Darwin
import Foundation
import Logging

private enum LogFileConstants {
    static let dayFormat = "yyyy-MM-dd"
    static let timestampFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
    static let fileExtension = ".log"
    static let filePermissions = mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

/// 日志目录：~/Library/Application Support/XCodeMCPService/logs/
public let logDirectory: String = {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/Library/Application Support/XCodeMCPService/logs"
}()

/// 按本地日期切分日志文件，并使用 O_APPEND 保证多进程追加写安全。
final class DailyRollingFileWriter: @unchecked Sendable {

    struct Configuration {
        let directory: String
        let timeZone: TimeZone
        let locale: Locale

        init(
            directory: String,
            timeZone: TimeZone = .autoupdatingCurrent,
            locale: Locale = Locale(identifier: "en_US_POSIX")
        ) {
            self.directory = directory
            self.timeZone = timeZone
            self.locale = locale
        }
    }

    private let configuration: Configuration
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let dayFormatter: DateFormatter
    private let timestampFormatter: DateFormatter

    private var activeDay: String?
    private var fileHandle: FileHandle?

    init(configuration: Configuration) {
        self.configuration = configuration
        self.dayFormatter = DailyRollingFileWriter.makeFormatter(
            format: LogFileConstants.dayFormat,
            timeZone: configuration.timeZone,
            locale: configuration.locale
        )
        self.timestampFormatter = DailyRollingFileWriter.makeFormatter(
            format: LogFileConstants.timestampFormat,
            timeZone: configuration.timeZone,
            locale: configuration.locale
        )
    }

    deinit {
        try? fileHandle?.close()
    }

    func write(
        label: String,
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        baseMetadata: Logger.Metadata,
        at date: Date = Date()
    ) {
        lock.withLock {
            let day = dayFormatter.string(from: date)
            guard let handle = rotateIfNeeded(for: day) else { return }

            let mergedMetadata = baseMetadata.merging(metadata ?? [:]) { _, new in new }
            let line = makeLine(
                timestamp: timestampFormatter.string(from: date),
                label: label,
                level: level,
                message: message,
                metadata: mergedMetadata
            )

            guard let data = line.data(using: .utf8) else { return }
            handle.write(data)
        }
    }

    func logPath(for date: Date) -> String {
        "\(configuration.directory)/\(dayFormatter.string(from: date))\(LogFileConstants.fileExtension)"
    }

    private func rotateIfNeeded(for day: String) -> FileHandle? {
        if activeDay == day, let fileHandle {
            return fileHandle
        }

        closeCurrentHandle()

        do {
            try fileManager.createDirectory(
                atPath: configuration.directory,
                withIntermediateDirectories: true
            )
        } catch {
            writeDirectlyToStandardError("Failed to create log directory '\(configuration.directory)': \(error)")
            return nil
        }

        let path = "\(configuration.directory)/\(day)\(LogFileConstants.fileExtension)"
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, LogFileConstants.filePermissions)
        guard fd >= 0 else {
            writeDirectlyToStandardError("Failed to open log file '\(path)': errno=\(errno)")
            return nil
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        activeDay = day
        fileHandle = handle
        return handle
    }

    private func closeCurrentHandle() {
        try? fileHandle?.close()
        fileHandle = nil
        activeDay = nil
    }

    private func makeLine(
        timestamp: String,
        label: String,
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata
    ) -> String {
        let metadataText = formatMetadata(metadata)
        return "\(timestamp) [\(level)] [\(label)] \(message)\(metadataText)\n"
    }

    private func formatMetadata(_ metadata: Logger.Metadata) -> String {
        guard !metadata.isEmpty else { return "" }
        let text = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        return " \(text)"
    }

    private static func makeFormatter(
        format: String,
        timeZone: TimeZone,
        locale: Locale
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private func writeDirectlyToStandardError(_ message: String) {
        guard let data = "log-writer error: \(message)\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

let sharedLogFileWriter = DailyRollingFileWriter(
    configuration: .init(directory: logDirectory)
)
