import XCTest
@testable import CodeEdit

final class SecureCRTImporterTests: XCTestCase {

    func test_parsesSSHSession() {
        let ini = """
        S:"Protocol Name"=SSH2
        S:"Hostname"=10.0.0.1
        S:"Username"=admin
        D:"[SSH2] Port"=00000016
        """
        let session = SecureCRTImporter.parseSession(ini: ini, name: "Core Router")
        XCTAssertEqual(session?.name, "Core Router")
        XCTAssertEqual(session?.protocol, .ssh)
        XCTAssertEqual(session?.hostname, "10.0.0.1")
        XCTAssertEqual(session?.username, "admin")
        XCTAssertEqual(session?.port, 22)
    }

    func test_parsesTelnetSessionWithDefaultPort() {
        let ini = """
        S:"Protocol Name"=Telnet
        S:"Hostname"=192.168.1.9
        """
        let session = SecureCRTImporter.parseSession(ini: ini, name: "Switch")
        XCTAssertEqual(session?.protocol, .telnet)
        XCTAssertEqual(session?.port, 23)   // no port key -> protocol default
        XCTAssertEqual(session?.username, "")
    }

    func test_parsesHexPort() {
        let ini = """
        S:"Protocol Name"=SSH2
        S:"Hostname"=h
        D:"[SSH2] Port"=000008AE
        """
        // 0x8AE = 2222
        XCTAssertEqual(SecureCRTImporter.parseSession(ini: ini, name: "x")?.port, 2222)
    }

    func test_missingHostname_returnsNil() {
        let ini = "S:\"Protocol Name\"=SSH2\nS:\"Username\"=admin"
        XCTAssertNil(SecureCRTImporter.parseSession(ini: ini, name: "x"))
    }

    func test_unknownProtocolDefaultsToSSH() {
        let ini = "S:\"Protocol Name\"=RDP\nS:\"Hostname\"=h"
        XCTAssertEqual(SecureCRTImporter.parseSession(ini: ini, name: "x")?.protocol, .ssh)
    }
}
