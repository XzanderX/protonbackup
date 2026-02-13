import XCTest
@testable import Neutrony

final class SyncStateTests: XCTestCase {

    func testInitialState() {
        let state = SyncState()
        XCTAssertFalse(state.isSyncing)
        XCTAssertFalse(state.isBacking)
        XCTAssertFalse(state.pendingBackup)
        XCTAssertNil(state.pendingRemoteChanges)
        XCTAssertFalse(state.isLocked)
    }

    func testIsLockedWhenSyncing() {
        var state = SyncState()
        state.isSyncing = true
        XCTAssertTrue(state.isLocked)
    }

    func testIsLockedWhenBacking() {
        var state = SyncState()
        state.isBacking = true
        XCTAssertTrue(state.isLocked)
    }

    func testResetAfterBackup() {
        var state = SyncState()
        state.isBacking = true
        state.pendingBackup = true
        state.pendingRemoteChanges = [.deleted(relativePath: "test")]

        state.resetAfterBackup()

        XCTAssertFalse(state.isBacking)
        XCTAssertFalse(state.pendingBackup)
        XCTAssertNil(state.pendingRemoteChanges)
    }

    func testRemoteCheckResult() {
        let emptyResult = RemoteCheckResult(changes: [], checkedAt: Date())
        XCTAssertFalse(emptyResult.hasChanges)

        let file = ProtonFile(
            id: "1", parentID: nil, name: "test.txt", mimeType: nil,
            size: 100, contentHash: nil, modifiedDate: Date(), createdDate: Date(),
            isFolder: false, relativePath: nil
        )
        let withChanges = RemoteCheckResult(changes: [.added(file)], checkedAt: Date())
        XCTAssertTrue(withChanges.hasChanges)
    }

    func testVolumeInfoFormatting() {
        let volume = VolumeInfo(
            id: "test-uuid",
            name: "Backup Drive",
            mountPath: "/Volumes/Backup",
            totalCapacity: 1_000_000_000_000, // 1 TB
            availableCapacity: 500_000_000_000, // 500 GB
            isExternal: true,
            isEjectable: true
        )

        XCTAssertFalse(volume.formattedAvailableSpace.isEmpty)
        XCTAssertFalse(volume.formattedTotalSpace.isEmpty)
        XCTAssertEqual(volume.id, "test-uuid")
        XCTAssertTrue(volume.isExternal)
    }
}
