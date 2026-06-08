import XCTest
@testable import CodeEdit

final class SessionStoreTests: XCTestCase {

    private var tempURL: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-store-test-\(UUID().uuidString).db")
        store = try SessionStore(tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
    }

    func test_emptyStore_returnsNoSessions() {
        XCTAssertTrue(store.allSessions().isEmpty)
    }

    func test_saveThenFetchSession() {
        let session = RemoteSession(name: "Router-1", hostname: "10.0.0.1", username: "admin")
        store.saveSession(session)
        let all = store.allSessions()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, session.id)
        XCTAssertEqual(all.first?.hostname, "10.0.0.1")
    }

    func test_saveIsUpsert() {
        var session = RemoteSession(name: "Old", hostname: "h", username: "u")
        store.saveSession(session)
        session.name = "New"
        store.saveSession(session)
        let all = store.allSessions()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "New")
    }

    func test_deleteSession() {
        let session = RemoteSession(name: "s", hostname: "h", username: "u")
        store.saveSession(session)
        store.deleteSession(id: session.id)
        XCTAssertTrue(store.allSessions().isEmpty)
    }

    func test_authMethodAndFolderIDRoundTrip() {
        let keyID = UUID()
        let folderID = UUID()
        let session = RemoteSession(
            name: "s",
            hostname: "h",
            username: "u",
            authMethod: .publicKey(keyID: keyID),
            folderID: folderID
        )
        store.saveSession(session)
        let fetched = store.allSessions().first
        XCTAssertEqual(fetched?.authMethod, .publicKey(keyID: keyID))
        XCTAssertEqual(fetched?.folderID, folderID)
    }

    func test_saveThenFetchFolder() {
        let folder = SessionFolder(name: "Lab")
        store.saveFolder(folder)
        let all = store.allFolders()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Lab")
    }

    func test_deleteFolder() {
        let folder = SessionFolder(name: "Lab")
        store.saveFolder(folder)
        store.deleteFolder(id: folder.id)
        XCTAssertTrue(store.allFolders().isEmpty)
    }
}
