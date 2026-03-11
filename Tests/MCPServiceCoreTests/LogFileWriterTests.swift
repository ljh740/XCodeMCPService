import Foundation
import Logging
import Testing
@testable import MCPServiceCore

@Suite("Log File Writer Tests")
struct LogFileWriterTests {

    @Test("rotates log file when local date changes")
    func rotatesLogFileWhenLocalDateChanges() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let writer = DailyRollingFileWriter(
            configuration: .init(
                directory: tempDirectory.path,
                timeZone: try #require(TimeZone(secondsFromGMT: 8 * 60 * 60))
            )
        )

        let beforeMidnight = try makeDate("2026-03-10T15:59:59.123Z")
        let afterMidnight = try makeDate("2026-03-10T16:00:00.456Z")

        writer.write(
            label: "mcp-forward.test",
            level: .info,
            message: "before-midnight",
            metadata: ["request": "one"],
            baseMetadata: [:],
            at: beforeMidnight
        )
        writer.write(
            label: "mcp-forward.test",
            level: .error,
            message: "after-midnight",
            metadata: ["request": "two"],
            baseMetadata: ["server": "xcode-tools"],
            at: afterMidnight
        )

        let firstPath = writer.logPath(for: beforeMidnight)
        let secondPath = writer.logPath(for: afterMidnight)

        #expect(firstPath.hasSuffix("2026-03-10.log"))
        #expect(secondPath.hasSuffix("2026-03-11.log"))
        #expect(firstPath != secondPath)

        let firstContent = try String(contentsOfFile: firstPath, encoding: .utf8)
        let secondContent = try String(contentsOfFile: secondPath, encoding: .utf8)

        #expect(firstContent.contains("2026-03-10T23:59:59.123+08:00"))
        #expect(firstContent.contains("[info] [mcp-forward.test] before-midnight request=one"))
        #expect(secondContent.contains("2026-03-11T00:00:00.456+08:00"))
        #expect(secondContent.contains("[error] [mcp-forward.test] after-midnight request=two server=xcode-tools"))
    }

    private func makeDate(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(formatter.date(from: text))
    }
}
