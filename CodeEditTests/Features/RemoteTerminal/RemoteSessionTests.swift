import XCTest
@testable import CodeEdit

final class RemoteSessionTests: XCTestCase {

    func test_defaultSSHPort() {
        let session = RemoteSession(name: "test", hostname: "host", username: "user")
        XCTAssertEqual(session.port, 22)
    }

    func test_defaultTelnetPort() {
        let session = RemoteSession(name: "test", protocol: .telnet, hostname: "host", username: "user")
        XCTAssertEqual(session.port, 23)
    }

    func test_explicitPortOverridesDefault() {
        let session = RemoteSession(name: "test", hostname: "host", port: 2222, username: "user")
        XCTAssertEqual(session.port, 2222)
    }

    func test_codableRoundTrip() throws {
        let original = RemoteSession(
            name: "Router-1",
            protocol: .ssh,
            hostname: "192.168.1.1",
            port: 22,
            username: "admin",
            authMethod: .password,
            notes: "Core router"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteSession.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.protocol, original.protocol)
        XCTAssertEqual(decoded.hostname, original.hostname)
        XCTAssertEqual(decoded.port, original.port)
        XCTAssertEqual(decoded.username, original.username)
        XCTAssertEqual(decoded.authMethod, original.authMethod)
        XCTAssertEqual(decoded.notes, original.notes)
        XCTAssertNil(decoded.lastConnectedAt)
    }

    func test_lastConnectedAtCodable() throws {
        var session = RemoteSession(name: "test", hostname: "host", username: "user")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        session.lastConnectedAt = date
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(RemoteSession.self, from: data)
        let decodedDate = try XCTUnwrap(decoded.lastConnectedAt)
        XCTAssertEqual(decodedDate.timeIntervalSince1970,
                       date.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func test_publicKeyAuthCodable() throws {
        let keyID = UUID()
        let session = RemoteSession(
            name: "test",
            hostname: "host",
            username: "user",
            authMethod: .publicKey(keyID: keyID)
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(RemoteSession.self, from: data)
        XCTAssertEqual(decoded.authMethod, .publicKey(keyID: keyID))
    }

    func test_uniqueIDs() {
        let sessionA = RemoteSession(name: "a", hostname: "host", username: "user")
        let sessionB = RemoteSession(name: "b", hostname: "host", username: "user")
        XCTAssertNotEqual(sessionA.id, sessionB.id)
    }
}
