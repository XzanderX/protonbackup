import XCTest
@testable import ProtonBackup

final class DiskSpaceUtilityTests: XCTestCase {

    func testFormatBytes() {
        XCTAssertEqual(DiskSpaceUtility.formatBytes(0), "Zero KB")
        XCTAssertTrue(DiskSpaceUtility.formatBytes(1024).contains("1"))
        XCTAssertTrue(DiskSpaceUtility.formatBytes(1_073_741_824).contains("GB") ||
                      DiskSpaceUtility.formatBytes(1_073_741_824).contains("1"))
    }

    func testAvailableSpaceForTempDir() {
        let tempPath = NSTemporaryDirectory()
        let space = DiskSpaceUtility.availableSpace(atPath: tempPath)
        XCTAssertNotNil(space)
        if let space {
            XCTAssertGreaterThan(space, 0)
        }
    }

    func testTotalSpaceForTempDir() {
        let tempPath = NSTemporaryDirectory()
        let space = DiskSpaceUtility.totalSpace(atPath: tempPath)
        XCTAssertNotNil(space)
        if let space {
            XCTAssertGreaterThan(space, 0)
        }
    }

    func testDirectorySizeForEmptyDir() throws {
        let tempDir = NSTemporaryDirectory() + "ProtonBackupTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let size = DiskSpaceUtility.directorySize(atPath: tempDir)
        XCTAssertEqual(size, 0)
    }

    func testDirectorySizeWithFiles() throws {
        let tempDir = NSTemporaryDirectory() + "ProtonBackupTest-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Write a test file
        let testData = Data(repeating: 0x42, count: 1024)
        let filePath = (tempDir as NSString).appendingPathComponent("test.bin")
        try testData.write(to: URL(fileURLWithPath: filePath))

        let size = DiskSpaceUtility.directorySize(atPath: tempDir)
        XCTAssertEqual(size, 1024)
    }

    func testCheckSpaceWarningForNonexistentPath() {
        let warning = DiskSpaceUtility.checkSpaceWarning(atPath: "/nonexistent/path", requiredBytes: 0)
        XCTAssertNotNil(warning)
    }

    func testCheckSpaceWarningWithSufficientSpace() {
        let tempPath = NSTemporaryDirectory()
        let warning = DiskSpaceUtility.checkSpaceWarning(atPath: tempPath, requiredBytes: 1024)
        // On most systems, temp dir has plenty of space
        XCTAssertNil(warning)
    }
}
