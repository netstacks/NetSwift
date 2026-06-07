import XCTest
@testable import CodeEdit

final class ANSIStripperTests: XCTestCase {
    func test_stripsColorCode() {
        let input: [UInt8] = Array("\u{1B}[32mHello\u{1B}[0m".utf8)
        XCTAssertEqual(ANSIStripper.strip(input[...]), "Hello")
    }

    func test_stripsMovementCode() {
        let input: [UInt8] = Array("\u{1B}[2AText".utf8)
        XCTAssertEqual(ANSIStripper.strip(input[...]), "Text")
    }

    func test_plainTextPassthrough() {
        let input: [UInt8] = Array("plain".utf8)
        XCTAssertEqual(ANSIStripper.strip(input[...]), "plain")
    }

    func test_emptyInput() {
        XCTAssertEqual(ANSIStripper.strip([][...]), "")
    }

    func test_stripsTwoByteEscapeSequence() {
        // ESC M  (reverse index — two-byte sequence)
        let input: [UInt8] = [0x1B, 0x4D] + Array("line".utf8)
        XCTAssertEqual(ANSIStripper.strip(input[...]), "line")
    }

    func test_stripsOSCTitleSequence_BELTerminated() {
        // ESC ] 0 ; title BEL ok  — shell prompt title-setting sequence
        let input: [UInt8] = [0x1B, 0x5D, 0x30, 0x3B] + Array("title".utf8) + [0x07] + Array("ok".utf8)
        XCTAssertEqual(ANSIStripper.strip(input[...]), "ok")
    }

    func test_stripsOSCTitleSequence_STTerminated() {
        // ESC ] 0 ; title ESC \  — tmux/iTerm2 string-terminator form
        let input: [UInt8] = [0x1B, 0x5D, 0x30, 0x3B] + Array("title".utf8) + [0x1B, 0x5C] + Array("ok".utf8)
        XCTAssertEqual(ANSIStripper.strip(input[...]), "ok")
    }
}
