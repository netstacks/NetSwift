//
//  LocalShellConnectionTests.swift
//  CodeEditTests
//

import XCTest
@testable import CodeEdit

final class LocalShellConnectionTests: XCTestCase {

    func test_initialState_notConnected() {
        let conn = LocalShellConnection(workspaceURL: nil)
        XCTAssertFalse(conn.isConnected)
    }

    func test_eachInstanceHasUniqueID() {
        let connA = LocalShellConnection(workspaceURL: nil)
        let connB = LocalShellConnection(workspaceURL: nil)
        XCTAssertNotEqual(connA.id, connB.id)
    }

    func test_disconnectWhileNotConnected_doesNotCrash() {
        let conn = LocalShellConnection(workspaceURL: nil)
        conn.disconnect()
        XCTAssertFalse(conn.isConnected)
    }

    func test_conformsToTerminalConnection() {
        let conn = LocalShellConnection(workspaceURL: nil)
        XCTAssertTrue((conn as AnyObject) is any TerminalConnection)
    }
}
