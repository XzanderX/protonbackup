import XCTest
@testable import ProtonBackup

final class BackupLogEntryTests: XCTestCase {

    func testLogEntryDisplayLine() {
        let entry = BackupLogEntry(
            level: .info,
            category: .sync,
            message: "Test message"
        )

        XCTAssertTrue(entry.displayLine.contains("[INFO]"))
        XCTAssertTrue(entry.displayLine.contains("[sync]"))
        XCTAssertTrue(entry.displayLine.contains("Test message"))
    }

    func testLogEntryWithFilePath() {
        let entry = BackupLogEntry(
            level: .error,
            category: .backup,
            message: "Failed to copy",
            filePath: "Documents/test.pdf"
        )

        XCTAssertTrue(entry.displayLine.contains("Documents/test.pdf"))
    }

    func testLogLevelComparable() {
        XCTAssertTrue(LogLevel.debug < LogLevel.info)
        XCTAssertTrue(LogLevel.info < LogLevel.warning)
        XCTAssertTrue(LogLevel.warning < LogLevel.error)
        XCTAssertFalse(LogLevel.error < LogLevel.debug)
    }

    func testLogEntryCodable() throws {
        let entry = BackupLogEntry(
            level: .warning,
            category: .auth,
            message: "Test codable",
            filePath: "/some/path"
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(BackupLogEntry.self, from: data)

        XCTAssertEqual(entry.id, decoded.id)
        XCTAssertEqual(entry.level, decoded.level)
        XCTAssertEqual(entry.category, decoded.category)
        XCTAssertEqual(entry.message, decoded.message)
        XCTAssertEqual(entry.filePath, decoded.filePath)
    }
}
