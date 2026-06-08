//
//  TelnetParser.swift
//  CodeEdit
//

import Foundation

/// Pure, stateful Telnet NVT (Network Virtual Terminal) byte processor.
///
/// Consumes raw inbound bytes from the server and produces:
///   - `data`: the cleaned terminal stream (IAC command sequences removed,
///             escaped `0xFF` un-escaped), ready to feed to the terminal view.
///   - `responses`: option-negotiation bytes that must be written back to the server.
///
/// Holds negotiation state across calls because TCP may split an IAC sequence
/// across two reads. No I/O happens here — `TelnetConnection` owns the socket.
final class TelnetParser {
    // MARK: - Command bytes (RFC 854)

    static let IAC: UInt8 = 255   // Interpret As Command
    static let DONT: UInt8 = 254
    static let DO: UInt8 = 253
    static let WONT: UInt8 = 252
    static let WILL: UInt8 = 251
    static let SB: UInt8 = 250    // Subnegotiation Begin
    static let SE: UInt8 = 240    // Subnegotiation End

    // MARK: - Option codes

    static let OPT_ECHO: UInt8 = 1
    static let OPT_SGA: UInt8 = 3            // Suppress Go Ahead
    static let OPT_TERMINAL_TYPE: UInt8 = 24
    static let OPT_NAWS: UInt8 = 31          // Negotiate About Window Size

    static let SUBNEG_IS: UInt8 = 0
    static let SUBNEG_SEND: UInt8 = 1

    /// Terminal type reported to the server during TERMINAL-TYPE subnegotiation.
    let terminalType = "XTERM"

    /// True once we have agreed to perform NAWS (server sent `DO NAWS`).
    /// `TelnetConnection` checks this before sending window-size updates.
    private(set) var nawsEnabled = false

    // MARK: - State

    private enum State {
        case normal
        case iac
        case negotiate(UInt8)   // saw IAC + DO/DONT/WILL/WONT, awaiting option byte
        case subneg
        case subnegIAC          // inside subnegotiation, saw IAC, awaiting SE or escaped IAC
    }

    private var state: State = .normal
    private var subnegBuffer: [UInt8] = []

    /// Options we have agreed to perform (replied WILL).
    private var localWill = Set<UInt8>()
    /// Options we have asked the server to perform (replied DO).
    private var remoteDo = Set<UInt8>()

    // MARK: - Processing

    func process(bytes: ArraySlice<UInt8>) -> (data: [UInt8], responses: [UInt8]) {
        var data: [UInt8] = []
        var responses: [UInt8] = []

        for byte in bytes {
            switch state {
            case .normal:
                if byte == Self.IAC {
                    state = .iac
                } else {
                    data.append(byte)
                }

            case .iac:
                switch byte {
                case Self.IAC:
                    data.append(Self.IAC)   // escaped literal 0xFF
                    state = .normal
                case Self.DO, Self.DONT, Self.WILL, Self.WONT:
                    state = .negotiate(byte)
                case Self.SB:
                    subnegBuffer = []
                    state = .subneg
                default:
                    // Two-byte commands we don't act on (NOP, GA, etc.) — drop.
                    state = .normal
                }

            case .negotiate(let command):
                responses.append(contentsOf: handleNegotiation(command: command, option: byte))
                state = .normal

            case .subneg:
                if byte == Self.IAC {
                    state = .subnegIAC
                } else {
                    subnegBuffer.append(byte)
                }

            case .subnegIAC:
                if byte == Self.SE {
                    responses.append(contentsOf: handleSubnegotiation(subnegBuffer))
                    state = .normal
                } else if byte == Self.IAC {
                    subnegBuffer.append(Self.IAC)   // escaped IAC inside subnegotiation
                    state = .subneg
                } else {
                    // Malformed; be lenient and keep collecting.
                    subnegBuffer.append(byte)
                    state = .subneg
                }
            }
        }

        return (data, responses)
    }

    // MARK: - Negotiation

    private func handleNegotiation(command: UInt8, option: UInt8) -> [UInt8] {
        switch command {
        case Self.DO:
            // Server requests that WE enable `option`.
            let supported: Set<UInt8> = [Self.OPT_TERMINAL_TYPE, Self.OPT_NAWS, Self.OPT_SGA]
            guard supported.contains(option) else {
                return [Self.IAC, Self.WONT, option]
            }
            if option == Self.OPT_NAWS { nawsEnabled = true }
            guard !localWill.contains(option) else { return [] }   // already agreed
            localWill.insert(option)
            return [Self.IAC, Self.WILL, option]

        case Self.DONT:
            if option == Self.OPT_NAWS { nawsEnabled = false }
            guard localWill.remove(option) != nil else { return [] }
            return [Self.IAC, Self.WONT, option]

        case Self.WILL:
            // Server offers to enable `option`.
            let wanted: Set<UInt8> = [Self.OPT_ECHO, Self.OPT_SGA]
            guard wanted.contains(option) else {
                return [Self.IAC, Self.DONT, option]
            }
            guard !remoteDo.contains(option) else { return [] }
            remoteDo.insert(option)
            return [Self.IAC, Self.DO, option]

        case Self.WONT:
            guard remoteDo.remove(option) != nil else { return [] }
            return [Self.IAC, Self.DONT, option]

        default:
            return []
        }
    }

    private func handleSubnegotiation(_ buffer: [UInt8]) -> [UInt8] {
        guard let first = buffer.first else { return [] }
        // TERMINAL-TYPE SEND -> reply with IS "<terminalType>"
        if first == Self.OPT_TERMINAL_TYPE, buffer.count >= 2, buffer[1] == Self.SUBNEG_SEND {
            var response: [UInt8] = [Self.IAC, Self.SB, Self.OPT_TERMINAL_TYPE, Self.SUBNEG_IS]
            response.append(contentsOf: Array(terminalType.utf8))
            response.append(contentsOf: [Self.IAC, Self.SE])
            return response
        }
        return []
    }

    // MARK: - NAWS

    /// Builds an `IAC SB NAWS <width> <height> IAC SE` subnegotiation,
    /// escaping any `0xFF` byte in the dimensions per RFC 1073.
    static func nawsSubnegotiation(cols: Int, rows: Int) -> [UInt8] {
        func dimensionBytes(_ value: Int) -> [UInt8] {
            let clamped = max(0, min(value, 0xFFFF))
            let hi = UInt8((clamped >> 8) & 0xFF)
            let lo = UInt8(clamped & 0xFF)
            var out: [UInt8] = []
            for byte in [hi, lo] {
                if byte == IAC { out.append(IAC) }   // escape
                out.append(byte)
            }
            return out
        }
        var message: [UInt8] = [IAC, SB, OPT_NAWS]
        message.append(contentsOf: dimensionBytes(cols))
        message.append(contentsOf: dimensionBytes(rows))
        message.append(contentsOf: [IAC, SE])
        return message
    }
}
