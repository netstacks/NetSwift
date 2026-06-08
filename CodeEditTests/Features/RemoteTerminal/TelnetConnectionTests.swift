import XCTest
@testable import CodeEdit

final class TelnetConnectionTests: XCTestCase {

    private func makeSession() -> RemoteSession {
        RemoteSession(
            name: "telnet-test",
            protocol: .telnet,
            hostname: "127.0.0.1",
            username: "user"
        )
    }

    func test_initialState_notConnected() {
        let conn = TelnetConnection(session: makeSession())
        XCTAssertFalse(conn.isConnected)
    }

    func test_eachInstanceHasUniqueID() {
        let first = TelnetConnection(session: makeSession())
        let second = TelnetConnection(session: makeSession())
        XCTAssertNotEqual(first.id, second.id)
    }

    func test_disconnectWhileNotConnected_doesNotCrash() {
        let conn = TelnetConnection(session: makeSession())
        conn.disconnect()
        XCTAssertFalse(conn.isConnected)
    }

    func test_conformsToTerminalConnection() {
        let conn = TelnetConnection(session: makeSession())
        XCTAssertTrue((conn as AnyObject) is any TerminalConnection)
    }

    // Manual integration test. Requires a reachable telnet server.
    // Disabled by default so CI has no network dependency.
    func test_connectToLocalhost_manualOnly() async throws {
        throw XCTSkip("Enable manually: requires a telnet server on 127.0.0.1:23")

        let conn = TelnetConnection(session: makeSession())
        var received = false
        conn.onDataReceived = { _ in received = true }
        try await conn.connect()
        XCTAssertTrue(conn.isConnected)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(received)
        conn.disconnect()
        XCTAssertFalse(conn.isConnected)
    }
}
