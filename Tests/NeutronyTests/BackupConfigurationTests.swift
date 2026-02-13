import XCTest
@testable import Neutrony

final class BackupConfigurationTests: XCTestCase {

    func testDefaultConfiguration() {
        let config = BackupConfiguration.default
        XCTAssertNil(config.destinationBookmark)
        XCTAssertNil(config.destinationDisplayName)
        XCTAssertEqual(config.pollingIntervalMinutes, 30)
        XCTAssertEqual(config.deletionPolicy, .mirrorWithVersions)
        XCTAssertTrue(config.keepVersions)
        XCTAssertTrue(config.notificationsEnabled)
        XCTAssertFalse(config.startAtLogin)
        XCTAssertNil(config.lastSuccessfulBackup)
        XCTAssertNil(config.lastSuccessfulSync)
        XCTAssertFalse(config.setupCompleted)
    }

    func testDefaultMirrorPathContainsNeutrony() {
        let path = BackupConfiguration.defaultMirrorPath
        XCTAssertTrue(path.contains("Neutrony"))
        XCTAssertTrue(path.contains("Mirror"))
    }

    func testDeletionPolicyDisplayNames() {
        XCTAssertFalse(DeletionPolicy.mirrorDeletions.displayName.isEmpty)
        XCTAssertFalse(DeletionPolicy.mirrorWithVersions.displayName.isEmpty)
        XCTAssertFalse(DeletionPolicy.neverDelete.displayName.isEmpty)
    }

    func testDeletionPolicyExplanations() {
        for policy in DeletionPolicy.allCases {
            XCTAssertFalse(policy.explanation.isEmpty)
        }
    }

    func testConfigurationCodable() throws {
        var config = BackupConfiguration.default
        config.pollingIntervalMinutes = 15
        config.deletionPolicy = .neverDelete
        config.keepVersions = false
        config.setupCompleted = true

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(BackupConfiguration.self, from: data)

        XCTAssertEqual(config, decoded)
    }
}
