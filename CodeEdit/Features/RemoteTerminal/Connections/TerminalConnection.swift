//
//  TerminalConnection.swift
//  CodeEdit
//

import Foundation

/// Transforms a byte stream segment. Used for byte-mutating observers
/// such as the ANSI keyword highlight preprocessor (Phase 4).
protocol TerminalProcessingObserver: AnyObject {
    func process(bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8>
}

/// Receives read-only notifications about terminal data.
/// Always receives plain text with ANSI escape codes stripped.
protocol TerminalNotifyingObserver: AnyObject {
    func connectionDidReceive(text: String)
    func connectionDidTerminate(exitCode: Int32?)
}

/// Default no-op implementations so conformers only override what they need.
extension TerminalNotifyingObserver {
    func connectionDidReceive(text: String) {}
    func connectionDidTerminate(exitCode: Int32?) {}
}

/// Represents a source of terminal data and a sink for user input.
/// Conforming types: LocalShellConnection, SSHConnection, TelnetConnection (Phase 2).
protocol TerminalConnection: AnyObject {
    var id: UUID { get }
    var isConnected: Bool { get }

    /// Invoked on an arbitrary thread when bytes arrive from the remote end.
    var onDataReceived: ((ArraySlice<UInt8>) -> Void)? { get set }

    /// Invoked when the connection closes (naturally or due to error).
    var onTerminated: ((Int32?) -> Void)? { get set }

    func connect() async throws
    func disconnect()

    /// Send raw bytes to the remote end (user keystrokes, pasted text, etc.).
    func send(data: ArraySlice<UInt8>)

    /// Notify the remote end of terminal dimension changes.
    func resize(cols: Int, rows: Int)
}
