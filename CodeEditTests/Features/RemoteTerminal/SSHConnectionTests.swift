//
//  SSHConnectionTests.swift
//  CodeEditTests
//

import XCTest
@testable import CodeEdit

final class SSHConnectionTests: XCTestCase {
    // Run this test manually with Remote Login enabled on localhost.
    // Disabled by default to avoid CI dependency on system SSH.
    func test_connectToLocalhost_manualOnly() async throws {
        throw XCTSkip("Enable manually: requires Remote Login enabled")

        let session = RemoteSession(
            name: "localhost",
            hostname: "127.0.0.1",
            port: 22,
            username: NSUserName(),
            authMethod: .password
        )
        let conn = SSHConnection(session: session, password: "YOUR_PASSWORD")

        var receivedData = false
        conn.onDataReceived = { _ in receivedData = true }

        try await conn.connect()
        XCTAssertTrue(conn.isConnected)

        conn.send(data: Array("echo hello\n".utf8)[...])
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 s
        XCTAssertTrue(receivedData)

        conn.disconnect()
        XCTAssertFalse(conn.isConnected)
    }
}
