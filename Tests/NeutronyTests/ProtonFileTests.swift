import XCTest
@testable import Neutrony

final class ProtonFileTests: XCTestCase {

    func testProtonFileIsFolder() {
        let folder = ProtonFile(
            id: "1",
            parentID: nil,
            name: "Documents",
            mimeType: nil,
            size: 0,
            contentHash: nil,
            modifiedDate: Date(),
            createdDate: Date(),
            isFolder: true,
            relativePath: "Documents"
        )

        XCTAssertTrue(folder.isFolder)
        XCTAssertFalse(folder.isFile)
    }

    func testProtonFileIsFile() {
        let file = ProtonFile(
            id: "2",
            parentID: "1",
            name: "report.pdf",
            mimeType: "application/pdf",
            size: 1024,
            contentHash: "abc123",
            modifiedDate: Date(),
            createdDate: Date(),
            isFolder: false,
            relativePath: "Documents/report.pdf"
        )

        XCTAssertFalse(file.isFolder)
        XCTAssertTrue(file.isFile)
    }

    func testMirrorIndexEmpty() {
        let index = MirrorIndex.empty
        XCTAssertTrue(index.entries.isEmpty)
        XCTAssertNil(index.lastIndexDate)
    }

    func testMirrorIndexCodable() throws {
        var index = MirrorIndex.empty
        index.entries["test/file.txt"] = MirrorEntry(
            protonFileID: "123",
            relativePath: "test/file.txt",
            contentHash: "hash123",
            size: 512,
            modifiedDate: Date(),
            isFolder: false
        )
        index.lastIndexDate = Date()

        let data = try JSONEncoder().encode(index)
        let decoded = try JSONDecoder().decode(MirrorIndex.self, from: data)

        XCTAssertEqual(index.entries.count, decoded.entries.count)
        XCTAssertEqual(index.entries["test/file.txt"]?.protonFileID, decoded.entries["test/file.txt"]?.protonFileID)
    }

    func testFileChangeDescription() {
        let file = ProtonFile(
            id: "1", parentID: nil, name: "test.txt", mimeType: nil,
            size: 100, contentHash: nil, modifiedDate: Date(), createdDate: Date(),
            isFolder: false, relativePath: "docs/test.txt"
        )

        let added = FileChange.added(file)
        XCTAssertTrue(added.description.contains("Added"))
        XCTAssertTrue(added.description.contains("docs/test.txt"))

        let modified = FileChange.modified(file)
        XCTAssertTrue(modified.description.contains("Modified"))

        let deleted = FileChange.deleted(relativePath: "old/file.txt")
        XCTAssertTrue(deleted.description.contains("Deleted"))
        XCTAssertTrue(deleted.description.contains("old/file.txt"))
    }
}
