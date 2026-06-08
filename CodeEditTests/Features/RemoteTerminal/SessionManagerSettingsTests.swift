import XCTest
@testable import CodeEdit

final class SessionManagerSettingsTests: XCTestCase {

    func test_defaults() {
        let settings = SessionManagerSettings()
        XCTAssertEqual(settings.defaultProtocol, .ssh)
        XCTAssertEqual(settings.defaultUsername, "")
        XCTAssertEqual(settings.defaultAuthMethod, .password)
    }

    func test_codableRoundTrip() throws {
        var settings = SessionManagerSettings()
        settings.defaultProtocol = .telnet
        settings.defaultUsername = "admin"
        settings.defaultAuthMethod = .keyboardInteractive
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SessionManagerSettings.self, from: data)
        XCTAssertEqual(decoded.defaultProtocol, .telnet)
        XCTAssertEqual(decoded.defaultUsername, "admin")
        XCTAssertEqual(decoded.defaultAuthMethod, .keyboardInteractive)
    }

    func test_searchKeysNonEmpty() {
        XCTAssertFalse(SessionManagerSettings().searchKeys.isEmpty)
    }

    func test_settingsDataIncludesSessionManager() {
        XCTAssertEqual(SettingsData().sessionManager.defaultProtocol, .ssh)
    }
}
