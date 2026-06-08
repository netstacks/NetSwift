import XCTest
@testable import CodeEdit

final class SessionManagerViewModelTests: XCTestCase {
    private var tempURL: URL!
    private var store: SessionStore!
    private var credentials: SessionCredentialStore!
    private var viewModel: SessionManagerViewModel!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-mgr-test-\(UUID().uuidString).db")
        store = try SessionStore(tempURL)
        let keychain = CodeEditKeychain(keyPrefix: "test-session-mgr-\(UUID().uuidString)-")
        credentials = SessionCredentialStore(keychain: keychain)
        viewModel = SessionManagerViewModel(store: store, credentials: credentials)
    }

    override func tearDownWithError() throws {
        viewModel = nil
        credentials = nil
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
    }

    func test_emptyTree_hasNoRootNodes() {
        XCTAssertTrue(viewModel.rootNodes.isEmpty)
    }

    func test_rootFolderIsNotShown() {
        // A root sentinel folder must never appear among the visible nodes.
        XCTAssertFalse(viewModel.rootNodes.contains { $0.id == SessionFolder.rootID })
    }

    func test_createSession_appearsAtRoot() {
        let session = RemoteSession(name: "Router-1", hostname: "10.0.0.1", username: "admin")
        viewModel.createSession(session, in: SessionFolder.rootID)
        XCTAssertEqual(viewModel.rootNodes.count, 1)
        XCTAssertEqual(viewModel.rootNodes.first?.id, session.id)
    }

    func test_createFolder_thenSessionInside() {
        let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
        let session = RemoteSession(name: "sw1", hostname: "h", username: "u")
        viewModel.createSession(session, in: folder.id)
        XCTAssertEqual(viewModel.rootNodes.map(\.id), [folder.id])
        XCTAssertEqual(viewModel.children(of: folder.id).map(\.id), [session.id])
    }

    func test_createPersistsAcrossReload() throws {
        let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
        viewModel.createSession(RemoteSession(name: "s", hostname: "h", username: "u"), in: folder.id)
        // New view model over the same store sees the same tree.
        let reopened = SessionManagerViewModel(store: store)
        XCTAssertEqual(reopened.rootNodes.map(\.name), ["Lab"])
        XCTAssertEqual(reopened.children(of: folder.id).count, 1)
    }

    func test_renameFolder() {
        let folder = viewModel.createFolder(name: "Old", in: SessionFolder.rootID)
        viewModel.renameFolder(folder.id, to: "New")
        XCTAssertEqual(viewModel.folder(folder.id)?.name, "New")
    }

    func test_updateSession() {
        let session = RemoteSession(name: "s", hostname: "h", username: "u")
        viewModel.createSession(session, in: SessionFolder.rootID)
        var edited = session
        edited.hostname = "10.0.0.9"
        viewModel.updateSession(edited)
        XCTAssertEqual(viewModel.session(session.id)?.hostname, "10.0.0.9")
    }

    func test_deleteSession_removesFromTreeAndStore() {
        let session = RemoteSession(name: "s", hostname: "h", username: "u")
        viewModel.createSession(session, in: SessionFolder.rootID)
        viewModel.deleteNode(session.id)
        XCTAssertTrue(viewModel.rootNodes.isEmpty)
        XCTAssertNil(viewModel.session(session.id))
    }

    func test_deleteFolder_recursivelyRemovesChildren() {
        let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
        let child = RemoteSession(name: "s", hostname: "h", username: "u")
        viewModel.createSession(child, in: folder.id)
        viewModel.deleteNode(folder.id)
        XCTAssertTrue(viewModel.rootNodes.isEmpty)
        XCTAssertNil(viewModel.session(child.id))
        XCTAssertNil(viewModel.folder(folder.id))
    }

    func test_duplicateSession_makesDistinctCopyInSameParent() {
        let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
        let session = RemoteSession(name: "s", hostname: "h", username: "u")
        viewModel.createSession(session, in: folder.id)
        let copy = viewModel.duplicateSession(session.id)
        XCTAssertNotNil(copy)
        XCTAssertNotEqual(copy?.id, session.id)
        XCTAssertEqual(viewModel.children(of: folder.id).count, 2)
        XCTAssertEqual(copy?.name, "s copy")
    }

    func test_deleteSession_removesStoredCredential() {
        let session = RemoteSession(name: "s", hostname: "h", username: "u")
        viewModel.createSession(session, in: SessionFolder.rootID)
        viewModel.setPassword("secret", for: session.id)
        XCTAssertEqual(credentials.password(forSessionID: session.id), "secret")
        viewModel.deleteNode(session.id)
        XCTAssertNil(credentials.password(forSessionID: session.id))
    }

    func test_deleteFolder_removesNestedSessionCredential() {
        let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
        let child = RemoteSession(name: "s", hostname: "h", username: "u")
        viewModel.createSession(child, in: folder.id)
        viewModel.setPassword("secret", for: child.id)
        viewModel.deleteNode(folder.id)
        XCTAssertNil(credentials.password(forSessionID: child.id))
    }

    func test_duplicateSession_copiesStoredCredential() {
        let session = RemoteSession(name: "s", hostname: "h", username: "u")
        viewModel.createSession(session, in: SessionFolder.rootID)
        viewModel.setPassword("secret", for: session.id)
        let copy = viewModel.duplicateSession(session.id)
        XCTAssertNotNil(copy)
        XCTAssertEqual(credentials.password(forSessionID: copy!.id), "secret")
        // Clean up the copy's keychain entry.
        if let copyID = copy?.id { credentials.deletePassword(forSessionID: copyID) }
    }

    func test_moveSessionIntoFolder() {
        let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
        let session = RemoteSession(name: "s", hostname: "h", username: "u")
        viewModel.createSession(session, in: SessionFolder.rootID)
        viewModel.move(session.id, to: folder.id, at: nil)
        XCTAssertTrue(viewModel.rootNodes.map(\.id).contains(folder.id))
        XCTAssertEqual(viewModel.children(of: folder.id).map(\.id), [session.id])
        XCTAssertEqual(viewModel.session(session.id)?.folderID, folder.id)
    }

    func test_reorderWithinParent() {
        let one = RemoteSession(name: "1", hostname: "h", username: "u")
        let two = RemoteSession(name: "2", hostname: "h", username: "u")
        viewModel.createSession(one, in: SessionFolder.rootID)
        viewModel.createSession(two, in: SessionFolder.rootID)
        XCTAssertEqual(viewModel.rootNodes.map(\.name), ["1", "2"])
        viewModel.move(two.id, to: SessionFolder.rootID, at: 0)
        XCTAssertEqual(viewModel.rootNodes.map(\.name), ["2", "1"])
    }

    func test_cannotMoveFolderIntoItsOwnDescendant() {
        let outer = viewModel.createFolder(name: "outer", in: SessionFolder.rootID)
        let inner = viewModel.createFolder(name: "inner", in: outer.id)
        viewModel.move(outer.id, to: inner.id, at: nil)
        // The illegal move is ignored — outer stays at root, inner stays under outer.
        XCTAssertTrue(viewModel.rootNodes.map(\.id).contains(outer.id))
        XCTAssertEqual(viewModel.children(of: outer.id).map(\.id), [inner.id])
    }

    func test_isDescendant() {
        let outer = viewModel.createFolder(name: "outer", in: SessionFolder.rootID)
        let inner = viewModel.createFolder(name: "inner", in: outer.id)
        XCTAssertTrue(viewModel.isDescendant(inner.id, of: outer.id))
        XCTAssertFalse(viewModel.isDescendant(outer.id, of: inner.id))
    }

    func test_searchMatchesNameHostUserNotes() {
        viewModel.createSession(
            RemoteSession(name: "Core", hostname: "10.0.0.1", username: "admin", notes: "primary"),
            in: SessionFolder.rootID
        )
        viewModel.createSession(
            RemoteSession(name: "Edge", hostname: "192.168.1.9", username: "ops", notes: "backup"),
            in: SessionFolder.rootID
        )
        XCTAssertEqual(viewModel.searchMatches(query: "core").map(\.name), ["Core"])
        XCTAssertEqual(viewModel.searchMatches(query: "192.168").map(\.name), ["Edge"])
        XCTAssertEqual(viewModel.searchMatches(query: "ADMIN").map(\.name), ["Core"])
        XCTAssertEqual(viewModel.searchMatches(query: "backup").map(\.name), ["Edge"])
        XCTAssertEqual(viewModel.searchMatches(query: "zzz").count, 0)
    }

    func test_passwordStorage() {
        let session = RemoteSession(name: "s", hostname: "h", username: "u")
        viewModel.createSession(session, in: SessionFolder.rootID)
        viewModel.setPassword("secret", for: session.id)
        XCTAssertEqual(viewModel.password(for: session.id), "secret")
        viewModel.setPassword(nil, for: session.id)
        XCTAssertNil(viewModel.password(for: session.id))
    }

    func test_bulkSetAuthMethodAcrossFolder() {
        let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
        let sub = viewModel.createFolder(name: "Sub", in: folder.id)
        let s1 = RemoteSession(name: "a", hostname: "h", username: "u")
        let s2 = RemoteSession(name: "b", hostname: "h", username: "u")
        viewModel.createSession(s1, in: folder.id)
        viewModel.createSession(s2, in: sub.id)
        viewModel.bulkSetAuthMethod(.keyboardInteractive, inFolder: folder.id)
        XCTAssertEqual(viewModel.session(s1.id)?.authMethod, .keyboardInteractive)
        XCTAssertEqual(viewModel.session(s2.id)?.authMethod, .keyboardInteractive)
    }
}
