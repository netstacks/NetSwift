import XCTest
@testable import CodeEdit

final class TelnetParserTests: XCTestCase {
    private let IAC = TelnetParser.IAC
    private let DO = TelnetParser.DO
    private let DONT = TelnetParser.DONT
    private let WILL = TelnetParser.WILL
    private let WONT = TelnetParser.WONT
    private let SB = TelnetParser.SB
    private let SE = TelnetParser.SE

    func test_plainTextPassthrough() {
        let parser = TelnetParser()
        let (data, responses) = parser.process(bytes: Array("hello".utf8)[...])
        XCTAssertEqual(data, Array("hello".utf8))
        XCTAssertTrue(responses.isEmpty)
    }

    func test_escapedIAC_yieldsLiteralByte() {
        let parser = TelnetParser()
        // IAC IAC -> a single literal 0xFF in the data stream
        let (data, responses) = parser.process(bytes: [IAC, IAC][...])
        XCTAssertEqual(data, [0xFF])
        XCTAssertTrue(responses.isEmpty)
    }

    func test_doNAWS_repliesWill_andEnablesNAWS() {
        let parser = TelnetParser()
        let (data, responses) = parser.process(bytes: [IAC, DO, TelnetParser.OPT_NAWS][...])
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(responses, [IAC, WILL, TelnetParser.OPT_NAWS])
        XCTAssertTrue(parser.nawsEnabled)
    }

    func test_doUnsupportedOption_repliesWont() {
        let parser = TelnetParser()
        // Option 99 is not one we agree to perform
        let (_, responses) = parser.process(bytes: [IAC, DO, 99][...])
        XCTAssertEqual(responses, [IAC, WONT, 99])
    }

    func test_willEcho_repliesDo() {
        let parser = TelnetParser()
        let (_, responses) = parser.process(bytes: [IAC, WILL, TelnetParser.OPT_ECHO][...])
        XCTAssertEqual(responses, [IAC, DO, TelnetParser.OPT_ECHO])
    }

    func test_willUnwantedOption_repliesDont() {
        let parser = TelnetParser()
        let (_, responses) = parser.process(bytes: [IAC, WILL, 99][...])
        XCTAssertEqual(responses, [IAC, DONT, 99])
    }

    func test_duplicateDoNAWS_isNotAnsweredTwice() {
        let parser = TelnetParser()
        _ = parser.process(bytes: [IAC, DO, TelnetParser.OPT_NAWS][...])
        let (_, responses) = parser.process(bytes: [IAC, DO, TelnetParser.OPT_NAWS][...])
        XCTAssertTrue(responses.isEmpty, "Agreed option must not be re-negotiated")
    }

    func test_dontNAWS_afterAgreement_disablesNAWS() {
        let parser = TelnetParser()
        _ = parser.process(bytes: [IAC, DO, TelnetParser.OPT_NAWS][...])
        XCTAssertTrue(parser.nawsEnabled)
        let (_, responses) = parser.process(bytes: [IAC, DONT, TelnetParser.OPT_NAWS][...])
        XCTAssertFalse(parser.nawsEnabled)
        XCTAssertEqual(responses, [IAC, WONT, TelnetParser.OPT_NAWS])
    }

    func test_negotiationInterleavedWithData() {
        let parser = TelnetParser()
        var input = Array("AB".utf8)
        input += [IAC, WILL, TelnetParser.OPT_SGA]
        input += Array("CD".utf8)
        let (data, responses) = parser.process(bytes: input[...])
        XCTAssertEqual(data, Array("ABCD".utf8))
        XCTAssertEqual(responses, [IAC, DO, TelnetParser.OPT_SGA])
    }

    func test_terminalTypeSubnegotiation_repliesWithType() {
        let parser = TelnetParser()
        // IAC SB TERMINAL-TYPE SEND IAC SE  ->  IAC SB TERMINAL-TYPE IS "XTERM" IAC SE
        let input: [UInt8] = [IAC, SB, TelnetParser.OPT_TERMINAL_TYPE, TelnetParser.SUBNEG_SEND, IAC, SE]
        let (data, responses) = parser.process(bytes: input[...])
        XCTAssertTrue(data.isEmpty)
        var expected: [UInt8] = [IAC, SB, TelnetParser.OPT_TERMINAL_TYPE, TelnetParser.SUBNEG_IS]
        expected += Array("XTERM".utf8)
        expected += [IAC, SE]
        XCTAssertEqual(responses, expected)
    }

    func test_iacSequenceSplitAcrossCalls() {
        let parser = TelnetParser()
        // First read ends mid-sequence: just "IAC"
        let (data1, responses1) = parser.process(bytes: [IAC][...])
        XCTAssertTrue(data1.isEmpty)
        XCTAssertTrue(responses1.isEmpty)
        // Second read completes "DO NAWS"
        let (data2, responses2) = parser.process(bytes: [DO, TelnetParser.OPT_NAWS][...])
        XCTAssertTrue(data2.isEmpty)
        XCTAssertEqual(responses2, [IAC, WILL, TelnetParser.OPT_NAWS])
    }

    func test_nawsSubnegotiation_encodesWidthAndHeight() {
        // 80 cols x 24 rows -> IAC SB NAWS 0 80 0 24 IAC SE
        let msg = TelnetParser.nawsSubnegotiation(cols: 80, rows: 24)
        XCTAssertEqual(msg, [IAC, SB, TelnetParser.OPT_NAWS, 0, 80, 0, 24, IAC, SE])
    }

    func test_nawsSubnegotiation_escapesByte255() {
        // 255 cols must be escaped as 0xFF 0xFF inside the subnegotiation
        let msg = TelnetParser.nawsSubnegotiation(cols: 255, rows: 1)
        XCTAssertEqual(msg, [IAC, SB, TelnetParser.OPT_NAWS, 0, 255, 255, 0, 1, IAC, SE])
    }
}
