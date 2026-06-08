import XCTest
@testable import CodeEdit

final class SessionFolderTests: XCTestCase {

    func test_defaults() {
        let folder = SessionFolder(name: "Routers")
        XCTAssertEqual(folder.name, "Routers")
        XCTAssertNil(folder.parentID)
        XCTAssertTrue(folder.childIDs.isEmpty)
    }

    func test_uniqueIDs() {
        let first = SessionFolder(name: "first")
        let second = SessionFolder(name: "second")
        XCTAssertNotEqual(first.id, second.id)
    }

    func test_codableRoundTrip() throws {
        let parent = UUID()
        let child = UUID()
        let original = SessionFolder(name: "Lab", parentID: parent, childIDs: [child])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionFolder.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, "Lab")
        XCTAssertEqual(decoded.parentID, parent)
        XCTAssertEqual(decoded.childIDs, [child])
    }

    func test_remoteSession_defaultFolderIDisNil() {
        let session = RemoteSession(name: "s", hostname: "h", username: "u")
        XCTAssertNil(session.folderID)
    }

    func test_remoteSession_folderIDRoundTrips() throws {
        let folderID = UUID()
        let session = RemoteSession(name: "s", hostname: "h", username: "u", folderID: folderID)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(RemoteSession.self, from: data)
        XCTAssertEqual(decoded.folderID, folderID)
    }
}
