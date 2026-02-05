import XCTest
@testable import ProtonBackup

final class BackupStatusTests: XCTestCase {

    func testBackupStateIsRunning() {
        let progress = BackupProgress(totalFiles: 10, completedFiles: 5)

        XCTAssertTrue(BackupState.syncing(progress: progress).isRunning)
        XCTAssertTrue(BackupState.backing(progress: progress).isRunning)
        XCTAssertFalse(BackupState.idle.isRunning)
        XCTAssertFalse(BackupState.upToDate.isRunning)
        XCTAssertFalse(BackupState.destinationDisconnected.isRunning)
        XCTAssertFalse(BackupState.error(message: "test").isRunning)
        XCTAssertFalse(BackupState.notConfigured.isRunning)
    }

    func testBackupStateStatusText() {
        XCTAssertEqual(BackupState.idle.statusText, "Idle")
        XCTAssertEqual(BackupState.upToDate.statusText, "Up to date")
        XCTAssertEqual(BackupState.destinationDisconnected.statusText, "Destination not connected")
        XCTAssertEqual(BackupState.notConfigured.statusText, "Setup required")
        XCTAssertTrue(BackupState.error(message: "disk full").statusText.contains("disk full"))
    }

    func testBackupProgressFraction() {
        let full = BackupProgress(totalFiles: 100, completedFiles: 50)
        XCTAssertEqual(full.fraction, 0.5, accuracy: 0.001)

        let empty = BackupProgress(totalFiles: 0, completedFiles: 0)
        XCTAssertEqual(empty.fraction, 0)

        let complete = BackupProgress(totalFiles: 10, completedFiles: 10)
        XCTAssertEqual(complete.fraction, 1.0, accuracy: 0.001)
    }

    func testBackupProgressSummary() {
        let progress = BackupProgress(totalFiles: 10, completedFiles: 3)
        XCTAssertEqual(progress.summary, "3/10 files")

        let scanning = BackupProgress(totalFiles: 0, completedFiles: 0)
        XCTAssertTrue(scanning.summary.contains("Scanning"))
    }

    func testBackupSummaryDisplayText() {
        let summary = BackupSummary(
            filesUpdated: 5,
            filesDeleted: 2,
            filesSkipped: 10,
            errors: [],
            startTime: Date().addingTimeInterval(-60),
            endTime: Date()
        )

        XCTAssertTrue(summary.succeeded)
        XCTAssertTrue(summary.displayText.contains("5 updated"))
        XCTAssertTrue(summary.displayText.contains("2 deleted"))
        XCTAssertTrue(summary.displayText.contains("10 skipped"))
    }

    func testBackupSummaryWithErrors() {
        let summary = BackupSummary(
            filesUpdated: 1,
            filesDeleted: 0,
            filesSkipped: 0,
            errors: ["Error 1", "Error 2"],
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertFalse(summary.succeeded)
        XCTAssertTrue(summary.displayText.contains("2 errors"))
    }

    func testBackupSummaryNoChanges() {
        let summary = BackupSummary(
            filesUpdated: 0,
            filesDeleted: 0,
            filesSkipped: 0,
            errors: [],
            startTime: Date(),
            endTime: Date()
        )

        XCTAssertTrue(summary.succeeded)
        XCTAssertTrue(summary.displayText.contains("No changes"))
    }
}
