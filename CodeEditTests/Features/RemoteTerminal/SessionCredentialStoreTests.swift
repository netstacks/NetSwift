import XCTest
@testable import CodeEdit

final class SessionCredentialStoreTests: XCTestCase {

    // Use a unique prefix per test run so we never collide with real credentials,
    // and clean up in tearDown.
    private var store: SessionCredentialStore!
    private var sessionID: UUID!

    override func setUp() {
        super.setUp()
        let keychain = CodeEditKeychain(keyPrefix: "test-session-credential-\(UUID().uuidString)-")
        store = SessionCredentialStore(keychain: keychain)
        sessionID = UUID()
    }

    override func tearDown() {
        store.deletePassword(forSessionID: sessionID)
        super.tearDown()
    }

    func test_missingPassword_returnsNil() {
        XCTAssertNil(store.password(forSessionID: sessionID))
    }

    func test_setThenGetPassword() {
        store.setPassword("hunter2", forSessionID: sessionID)
        XCTAssertEqual(store.password(forSessionID: sessionID), "hunter2")
    }

    func test_overwritePassword() {
        store.setPassword("first", forSessionID: sessionID)
        store.setPassword("second", forSessionID: sessionID)
        XCTAssertEqual(store.password(forSessionID: sessionID), "second")
    }

    func test_deletePassword() {
        store.setPassword("secret", forSessionID: sessionID)
        store.deletePassword(forSessionID: sessionID)
        XCTAssertNil(store.password(forSessionID: sessionID))
    }
}
