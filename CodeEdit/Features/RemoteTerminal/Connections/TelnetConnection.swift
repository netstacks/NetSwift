//
//  TelnetConnection.swift
//  CodeEdit
//

import Foundation
import Network

/// A `TerminalConnection` that speaks Telnet over TCP via `NWConnection`.
///
/// All socket I/O and state mutation run on a single private serial queue so the
/// non-thread-safe `TelnetParser` is only ever accessed from one thread.
/// Authentication is interactive (the server prompts for login/password in-band),
/// so no credentials are needed at connect time.
final class TelnetConnection: TerminalConnection {
    let id: UUID = UUID()
    private(set) var isConnected: Bool = false
    var onDataReceived: ((ArraySlice<UInt8>) -> Void)?
    var onTerminated: ((Int32?) -> Void)?

    private let session: RemoteSession
    private let parser = TelnetParser()
    private let queue = DispatchQueue(label: "app.codeedit.telnet.connection")
    private var connection: NWConnection?
    private var cols: Int = 80
    private var rows: Int = 24
    private var hasTerminated = false

    init(session: RemoteSession) {
        self.session = session
    }

    // MARK: - TerminalConnection

    func connect() async throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: session.port)) else {
            throw TelnetConnectionError.invalidPort
        }
        let host = NWEndpoint.Host(session.hostname)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let connection = NWConnection(host: host, port: port, using: .tcp)
                self.connection = connection
                var resumed = false

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        self.isConnected = true
                        if !resumed { resumed = true; continuation.resume() }
                        self.receiveLoop()
                    case .failed(let error):
                        if !resumed {
                            // Failure during the initial connect: surface via connect()'s throw only.
                            resumed = true
                            self.isConnected = false
                            continuation.resume(throwing: error)
                        } else {
                            // Failure after the connection was established.
                            self.terminate(exitCode: nil)
                        }
                    case .cancelled:
                        self.isConnected = false
                        if !resumed { resumed = true; continuation.resume(throwing: CancellationError()) }
                    default:
                        break
                    }
                }

                connection.start(queue: self.queue)
            }
        }
    }

    func disconnect() {
        queue.async {
            self.connection?.cancel()
            self.connection = nil
            self.isConnected = false
            self.hasTerminated = true
        }
    }

    func send(data: ArraySlice<UInt8>) {
        // Escape any literal 0xFF (IAC) in user input per RFC 854.
        var escaped: [UInt8] = []
        escaped.reserveCapacity(data.count)
        for byte in data {
            if byte == TelnetParser.IAC { escaped.append(TelnetParser.IAC) }
            escaped.append(byte)
        }
        queue.async { self.sendRaw(escaped) }
    }

    func resize(cols: Int, rows: Int) {
        queue.async {
            self.cols = cols
            self.rows = rows
            guard self.isConnected, self.parser.nawsEnabled else { return }
            self.sendRaw(TelnetParser.nawsSubnegotiation(cols: cols, rows: rows))
        }
    }

    // MARK: - Private

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                let (clean, responses) = self.parser.process(bytes: ArraySlice(data))
                if !responses.isEmpty { self.sendRaw(responses) }
                if !clean.isEmpty { self.onDataReceived?(clean[...]) }
            }

            if isComplete || error != nil {
                self.terminate(exitCode: nil)
                return
            }

            self.receiveLoop()
        }
    }

    private func terminate(exitCode: Int32?) {
        guard !hasTerminated else { return }
        hasTerminated = true
        isConnected = false
        onTerminated?(exitCode)
    }

    private func sendRaw(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        connection?.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }
}

// MARK: - Errors

enum TelnetConnectionError: Error, LocalizedError {
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidPort: return "The Telnet port is invalid."
        }
    }
}
