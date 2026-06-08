# Phase 2 — Telnet + Session Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a working Telnet connection (NVT option negotiation, wired into the utility-area terminal panel exactly like SSH) and a tested session-persistence foundation (GRDB session/folder store + Keychain credential store) that Phase 3's Session Manager UI will build on.

**Architecture:** Telnet reuses the Phase 1 `TerminalConnection` protocol and `CEConnectionTerminalView` display layer. The Telnet NVT/IAC state machine is isolated in a pure, fully-unit-tested `TelnetParser`; `TelnetConnection` wraps `Network.framework`'s `NWConnection` and delegates all byte interpretation to the parser. Persistence follows the existing `EditorStateRestoration` GRDB pattern (one SQLite file, blob-per-row, `DatabaseQueue`, `DatabaseMigrator`); credentials go to the existing `CodeEditKeychain`.

**Tech Stack:** SwiftUI, SwiftTerm (custom fork), Network.framework (`NWConnection`), GRDB, `CodeEditKeychain`

> **This is Phase 2 of 7.** Phase 1 (Protocol Foundation + SSH) has shipped. Phases 3–7 (Session Manager UI, Keyword Highlighting, Sanitization, Terminal Themes, AI Integration) have their own plans written when this ships.

> **Two independent parts.** Part A (Telnet, Tasks 1–4) and Part B (Session persistence, Tasks 5–7) do not depend on each other and can be executed in either order. Each produces working, tested software on its own.

---

## File Map

**Create:**
```
CodeEdit/Features/RemoteTerminal/
  Connections/
    TelnetParser.swift                  — pure NVT/IAC state machine (negotiation + subnegotiation)
    TelnetConnection.swift              — TerminalConnection over NWConnection
  Sessions/
    SessionFolder.swift                 — folder model for the session tree
    SessionStore.swift                  — GRDB persistence for sessions + folders
    SessionCredentialStore.swift        — Keychain wrapper for session passwords
  Views/
    NewTelnetConnectionView.swift       — "Open Telnet Connection" sheet

CodeEditTests/Features/RemoteTerminal/
  TelnetParserTests.swift
  TelnetConnectionTests.swift
  SessionFolderTests.swift
  SessionStoreTests.swift
  SessionCredentialStoreTests.swift
```

**Modify:**
```
CodeEdit/Features/RemoteTerminal/Sessions/RemoteSession.swift
  — add `folderID: UUID?` property + init parameter

CodeEdit/Features/UtilityArea/Models/UtilityAreaTerminal.swift
  — add `.telnet(session:)` case to TerminalConnectionType

CodeEdit/Features/UtilityArea/ViewModels/UtilityAreaViewModel.swift
  — add addTelnetTerminal(session:) method

CodeEdit/Features/UtilityArea/TerminalUtility/UtilityAreaTerminalView.swift
  — generalize SSH cache/wrapper to any TerminalConnection; render Telnet tabs

CodeEdit/Features/WindowCommands/FileCommands.swift
  — add "New Telnet Connection..." menu item

CodeEdit/AppDelegate.swift
  — add openNewTelnetConnection(_:) selector

CodeEdit/Features/Documents/Controllers/CodeEditWindowControllerExtensions.swift
  — add openTelnetConnectionSheet()
```

---

# Part A — Telnet

## Task 1: TelnetParser (pure NVT/IAC state machine)

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Connections/TelnetParser.swift`
- Test: `CodeEditTests/Features/RemoteTerminal/TelnetParserTests.swift`

The parser is the heart of Telnet. It consumes raw inbound bytes and returns `(data, responses)`: `data` is the cleaned terminal byte stream (IAC sequences removed, escaped `0xFF` un-escaped); `responses` are the negotiation bytes that must be written back to the server. It is a class because it holds negotiation state across calls (TCP can split an IAC sequence across two reads).

- [ ] **Step 1: Write the failing tests**

  Create `CodeEditTests/Features/RemoteTerminal/TelnetParserTests.swift`:

  ```swift
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
  ```

- [ ] **Step 2: Run the tests, confirm they fail**

  ⌘U. Expected: compile error — `TelnetParser` not found.

- [ ] **Step 3: Create TelnetParser.swift**

  Create `CodeEdit/Features/RemoteTerminal/Connections/TelnetParser.swift`:

  ```swift
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
  ```

- [ ] **Step 4: Run the tests, confirm all pass**

  ⌘U. Expected: all `TelnetParserTests` pass.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Connections/TelnetParser.swift
  git add CodeEditTests/Features/RemoteTerminal/TelnetParserTests.swift
  git commit -m "feat: add TelnetParser NVT/IAC state machine"
  ```

---

## Task 2: TelnetConnection (NWConnection)

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Connections/TelnetConnection.swift`
- Test: `CodeEditTests/Features/RemoteTerminal/TelnetConnectionTests.swift`

`TelnetConnection` conforms to the Phase 1 `TerminalConnection` protocol. All socket I/O and connection-state mutation happen on a single private serial `DispatchQueue`, so the `TelnetParser` (which is not thread-safe) is only ever touched from that queue.

- [ ] **Step 1: Write the failing test**

  Create `CodeEditTests/Features/RemoteTerminal/TelnetConnectionTests.swift`:

  ```swift
  import XCTest
  @testable import CodeEdit

  final class TelnetConnectionTests: XCTestCase {

      private func makeSession() -> RemoteSession {
          RemoteSession(
              name: "telnet-test",
              protocol: .telnet,
              hostname: "127.0.0.1",
              username: "user"
          )
      }

      func test_initialState_notConnected() {
          let conn = TelnetConnection(session: makeSession())
          XCTAssertFalse(conn.isConnected)
      }

      func test_eachInstanceHasUniqueID() {
          let a = TelnetConnection(session: makeSession())
          let b = TelnetConnection(session: makeSession())
          XCTAssertNotEqual(a.id, b.id)
      }

      func test_disconnectWhileNotConnected_doesNotCrash() {
          let conn = TelnetConnection(session: makeSession())
          conn.disconnect()
          XCTAssertFalse(conn.isConnected)
      }

      func test_conformsToTerminalConnection() {
          let conn = TelnetConnection(session: makeSession())
          XCTAssertTrue((conn as AnyObject) is any TerminalConnection)
      }

      // Manual integration test. Requires a reachable telnet server.
      // Disabled by default so CI has no network dependency.
      func test_connectToLocalhost_manualOnly() async throws {
          throw XCTSkip("Enable manually: requires a telnet server on 127.0.0.1:23")

          let conn = TelnetConnection(session: makeSession())
          var received = false
          conn.onDataReceived = { _ in received = true }
          try await conn.connect()
          XCTAssertTrue(conn.isConnected)
          try await Task.sleep(nanoseconds: 500_000_000)
          XCTAssertTrue(received)
          conn.disconnect()
          XCTAssertFalse(conn.isConnected)
      }
  }
  ```

- [ ] **Step 2: Run, confirm compile error**

  ⌘U. Expected: `TelnetConnection` not found.

- [ ] **Step 3: Create TelnetConnection.swift**

  Create `CodeEdit/Features/RemoteTerminal/Connections/TelnetConnection.swift`:

  ```swift
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
                          self.isConnected = false
                          if !resumed { resumed = true; continuation.resume(throwing: error) }
                          self.onTerminated?(nil)
                      case .cancelled:
                          self.isConnected = false
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
          sendRaw(escaped)
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
                  self.isConnected = false
                  self.onTerminated?(nil)
                  return
              }

              self.receiveLoop()
          }
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
  ```

- [ ] **Step 4: Run tests, confirm all pass**

  ⌘U. Expected: all `TelnetConnectionTests` pass (the manual test reports as skipped).

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Connections/TelnetConnection.swift
  git add CodeEditTests/Features/RemoteTerminal/TelnetConnectionTests.swift
  git commit -m "feat: implement TelnetConnection over NWConnection"
  ```

---

## Task 3: Wire Telnet into the Utility Area

**Files:**
- Modify: `CodeEdit/Features/UtilityArea/Models/UtilityAreaTerminal.swift`
- Modify: `CodeEdit/Features/UtilityArea/ViewModels/UtilityAreaViewModel.swift`
- Modify: `CodeEdit/Features/UtilityArea/TerminalUtility/UtilityAreaTerminalView.swift`

This generalizes the Phase 1 SSH-only cache and `NSViewRepresentable` wrapper to handle any `TerminalConnection`, so SSH and Telnet share one render path.

- [ ] **Step 1: Add the `.telnet` case to TerminalConnectionType**

  In `CodeEdit/Features/UtilityArea/Models/UtilityAreaTerminal.swift`, replace the `TerminalConnectionType` enum (currently lines 11–14) with:

  ```swift
  /// Describes how a terminal tab obtains its shell session.
  enum TerminalConnectionType {
      case localShell
      case ssh(session: RemoteSession, password: String?)
      case telnet(session: RemoteSession)
  }
  ```

- [ ] **Step 2: Add addTelnetTerminal to UtilityAreaViewModel**

  In `CodeEdit/Features/UtilityArea/ViewModels/UtilityAreaViewModel.swift`, add this method immediately after `addSSHTerminal(session:password:)` (which ends at line 119):

  ```swift
  /// Adds a Telnet session tab to the utility area.
  /// - Parameter session: The ``RemoteSession`` configuration describing the remote host.
  func addTelnetTerminal(session: RemoteSession) {
      let terminal = UtilityAreaTerminal(
          id: UUID(),
          url: URL(fileURLWithPath: NSHomeDirectory()),
          title: session.name,
          shell: nil,
          connectionType: .telnet(session: session)
      )
      terminals.append(terminal)
      selectedTerminals = [terminal.id]
  }
  ```

- [ ] **Step 3: Generalize the cache in UtilityAreaTerminalView**

  In `CodeEdit/Features/UtilityArea/TerminalUtility/UtilityAreaTerminalView.swift`, replace the entire `SSHTerminalCache` class (lines 11–44, the `// MARK: - SSH terminal cache` block) with:

  ```swift
  // MARK: - Remote terminal cache

  /// Caches ``CEConnectionTerminalView`` instances keyed by terminal UUID so that
  /// switching away from a remote (SSH/Telnet) tab and back does not disconnect the session.
  private final class RemoteTerminalCache: ObservableObject {
      private var views: [UUID: CEConnectionTerminalView] = [:]

      deinit {
          views.values.forEach { $0.connection.disconnect() }
      }

      /// Returns an existing cached view, or builds the right connection for the
      /// terminal's ``TerminalConnectionType`` and caches a new one.
      /// Returns `nil` for `.localShell`, which uses ``TerminalEmulatorView`` instead.
      /// Connection is started in ``RemoteTerminalNSView/makeNSView(context:)`` to avoid
      /// side effects during SwiftUI body evaluation.
      func view(for terminal: UtilityAreaTerminal) -> CEConnectionTerminalView? {
          if let existing = views[terminal.id] {
              return existing
          }

          let connection: (any TerminalConnection)?
          switch terminal.connectionType {
          case .localShell:
              connection = nil
          case let .ssh(session, password):
              connection = SSHConnection(session: session, password: password)
          case let .telnet(session):
              connection = TelnetConnection(session: session)
          }

          guard let connection else { return nil }
          let terminalView = CEConnectionTerminalView(connection: connection)
          views[terminal.id] = terminalView
          return terminalView
      }

      /// Disconnects and removes the cached view for a terminal.
      func removeView(for id: UUID) {
          views[id]?.connection.disconnect()
          views[id] = nil
      }
  }
  ```

- [ ] **Step 4: Rename the NSViewRepresentable wrapper**

  In the same file, replace the `SSHTerminalNSView` struct and its `// MARK:` header (lines 46–71) with:

  ```swift
  // MARK: - NSViewRepresentable wrapper for CEConnectionTerminalView

  /// Wraps a ``CEConnectionTerminalView`` (an ``NSView`` subclass) for use in SwiftUI.
  /// Fires the connect task in ``makeNSView(context:)`` — the correct lifecycle hook
  /// for one-time setup — rather than during SwiftUI body evaluation. Works for any
  /// ``TerminalConnection`` (SSH or Telnet).
  private struct RemoteTerminalNSView: NSViewRepresentable {
      let terminalView: CEConnectionTerminalView

      func makeNSView(context: Context) -> CEConnectionTerminalView {
          let conn = terminalView.connection
          Task {
              guard !conn.isConnected else { return }
              do {
                  try await conn.connect()
              } catch {
                  let message = "\r\nConnection failed: \(error.localizedDescription)\r\n"
                  await MainActor.run {
                      terminalView.feed(byteArray: ArraySlice(Array(message.utf8)))
                  }
              }
          }
          return terminalView
      }

      func updateNSView(_ nsView: CEConnectionTerminalView, context: Context) {}
  }
  ```

- [ ] **Step 5: Update the state property**

  In the same file, replace the line (currently line 100):

  ```swift
      @StateObject private var sshCache = SSHTerminalCache()
  ```

  with:

  ```swift
      @StateObject private var remoteCache = RemoteTerminalCache()
  ```

- [ ] **Step 6: Update the render branch**

  In the same file, replace the `switch selectedTerminal.connectionType { ... }` block inside `body` (currently lines 172–200) with:

  ```swift
                              switch selectedTerminal.connectionType {
                              case .localShell:
                                  TerminalEmulatorView(
                                      url: selectedTerminal.url,
                                      terminalID: selectedTerminal.id,
                                      shellType: selectedTerminal.shell,
                                      onTitleChange: { [weak selectedTerminal] newTitle in
                                          guard let id = selectedTerminal?.id else { return }
                                          // This can be called whenever, even in a view update so it needs to be dispatched.
                                          DispatchQueue.main.async { [weak utilityAreaViewModel] in
                                              utilityAreaViewModel?.updateTerminal(id, title: newTitle)
                                          }
                                      }
                                  )
                                  .frame(height: max(0, constrainedHeight - 1))
                                  .id(selectedTerminal.id)
                                  .accessibilityIdentifier("terminal")
                              case .ssh, .telnet:
                                  if let remoteView = remoteCache.view(for: selectedTerminal) {
                                      RemoteTerminalNSView(terminalView: remoteView)
                                          .frame(height: max(0, constrainedHeight - 1))
                                          .id(selectedTerminal.id)
                                          .accessibilityIdentifier("terminal")
                                  }
                              }
  ```

- [ ] **Step 7: Update the cleanup in onChange**

  In the same file, replace the `.onChange(of: utilityAreaViewModel.terminals)` body (currently lines 255–261) with:

  ```swift
          .onChange(of: utilityAreaViewModel.terminals) { oldTerminals, newTerminals in
              // Remove cached remote views for terminals that no longer exist.
              let activeIDs = Set(newTerminals.map(\.id))
              for oldTerminal in oldTerminals where !activeIDs.contains(oldTerminal.id) {
                  remoteCache.removeView(for: oldTerminal.id)
              }
          }
  ```

- [ ] **Step 8: Build succeeds**

  ⌘B. Expected: no errors. (The reset-button `.disabled` check still uses `if case .localShell`, which correctly disables reset for Telnet tabs too.)

- [ ] **Step 9: Commit**

  ```bash
  git add CodeEdit/Features/UtilityArea/Models/UtilityAreaTerminal.swift
  git add CodeEdit/Features/UtilityArea/ViewModels/UtilityAreaViewModel.swift
  git add CodeEdit/Features/UtilityArea/TerminalUtility/UtilityAreaTerminalView.swift
  git commit -m "feat: render Telnet tabs via generalized remote terminal cache"
  ```

---

## Task 4: New Telnet Connection Sheet + Menu Command

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Views/NewTelnetConnectionView.swift`
- Modify: `CodeEdit/Features/WindowCommands/FileCommands.swift`
- Modify: `CodeEdit/AppDelegate.swift`
- Modify: `CodeEdit/Features/Documents/Controllers/CodeEditWindowControllerExtensions.swift`

- [ ] **Step 1: Create NewTelnetConnectionView.swift**

  Create `CodeEdit/Features/RemoteTerminal/Views/NewTelnetConnectionView.swift`:

  ```swift
  //
  //  NewTelnetConnectionView.swift
  //  CodeEdit
  //

  import SwiftUI

  /// A sheet for establishing a new Telnet connection.
  /// Telnet auth is interactive (the server prompts in-band), so there is no password field.
  /// Phase 3 (Session Manager) replaces this with the full session picker.
  struct NewTelnetConnectionView: View {
      /// Called by Cancel and Connect to close the AppKit sheet.
      /// `@Environment(\.dismiss)` is a no-op when presented via NSHostingController + presentAsSheet.
      var onDismiss: () -> Void
      @EnvironmentObject private var utilityAreaViewModel: UtilityAreaViewModel

      @State private var hostname = ""
      @State private var port = "23"
      @State private var username = ""
      @State private var sessionName = ""

      var body: some View {
          VStack(alignment: .leading, spacing: 16) {
              Text("New Telnet Connection")
                  .font(.headline)

              Group {
                  LabeledContent("Session Name") {
                      TextField("My Switch", text: $sessionName)
                          .textFieldStyle(.roundedBorder)
                  }
                  LabeledContent("Hostname") {
                      TextField("192.168.1.1", text: $hostname)
                          .textFieldStyle(.roundedBorder)
                  }
                  LabeledContent("Port") {
                      TextField("23", text: $port)
                          .textFieldStyle(.roundedBorder)
                          .frame(width: 60)
                  }
                  LabeledContent("Username") {
                      TextField("optional", text: $username)
                          .textFieldStyle(.roundedBorder)
                  }
              }

              HStack {
                  Spacer()
                  Button("Cancel") { onDismiss() }
                      .keyboardShortcut(.cancelAction)
                  Button("Connect") { connect() }
                      .keyboardShortcut(.defaultAction)
                      .disabled(hostname.isEmpty)
              }
          }
          .padding(20)
          .frame(width: 380)
      }

      private func connect() {
          let name = sessionName.isEmpty ? hostname : sessionName
          let portInt = Int(port) ?? 23
          let session = RemoteSession(
              name: name,
              protocol: .telnet,
              hostname: hostname,
              port: portInt,
              username: username
          )
          utilityAreaViewModel.addTelnetTerminal(session: session)
          onDismiss()
      }
  }
  ```

- [ ] **Step 2: Add openTelnetConnectionSheet() to the window controller**

  In `CodeEdit/Features/Documents/Controllers/CodeEditWindowControllerExtensions.swift`, add this method immediately after `openSSHConnectionSheet()` (which ends at line 100):

  ```swift
      func openTelnetConnectionSheet() {
          guard let utilityAreaViewModel = workspace?.utilityAreaModel,
                let presenter = contentViewController else { return }
          var sheet: NSHostingController<AnyView>?
          sheet = NSHostingController(
              rootView: AnyView(
                  NewTelnetConnectionView(onDismiss: { [weak presenter] in
                      guard let sheet else { return }
                      presenter?.dismiss(sheet)
                  })
                  .environmentObject(utilityAreaViewModel)
              )
          )
          sheet?.preferredContentSize = NSSize(width: 380, height: 240)
          if let sheet {
              presenter.presentAsSheet(sheet)
          }
      }
  ```

- [ ] **Step 3: Add the AppDelegate selector**

  In `CodeEdit/AppDelegate.swift`, add this method immediately after `openNewSSHConnection(_:)` (which ends at line 193):

  ```swift
      @objc
      func openNewTelnetConnection(_ sender: Any?) {
          guard let workspace = NSDocumentController.shared.currentDocument as? WorkspaceDocument,
                let windowController = workspace.windowControllers.first as? CodeEditWindowController
          else { return }
          windowController.openTelnetConnectionSheet()
      }
  ```

- [ ] **Step 4: Add the menu item**

  In `CodeEdit/Features/WindowCommands/FileCommands.swift`, replace the "New SSH Connection..." button block (currently lines 44–47) with both buttons:

  ```swift
                  Button("New SSH Connection...") {
                      NSApp.sendAction(#selector(AppDelegate.openNewSSHConnection(_:)), to: nil, from: nil)
                  }
                  .keyboardShortcut("K", modifiers: [.command, .shift])

                  Button("New Telnet Connection...") {
                      NSApp.sendAction(#selector(AppDelegate.openNewTelnetConnection(_:)), to: nil, from: nil)
                  }
  ```

  (No keyboard shortcut is assigned to Telnet to avoid clashing with existing CodeEdit bindings; one can be added later.)

- [ ] **Step 5: Build and run**

  ⌘R. Expected: app launches. **File** menu shows "New SSH Connection… ⇧⌘K" and "New Telnet Connection…". Selecting Telnet shows the sheet.

- [ ] **Step 6: Manual end-to-end test**

  1. Start a local telnet server (e.g. `brew install telnetd` is unavailable on modern macOS; instead test against a reachable device or run a throwaway server: `socat TCP-LISTEN:2300,reuseaddr,fork EXEC:/bin/cat` then connect to port 2300 — it echoes typed input).
  2. Trigger "New Telnet Connection…", enter the hostname and port, click Connect.
  3. Expected: a new tab appears in the utility area; typed characters echo back (with `socat` cat) or the device login prompt is visible.

- [ ] **Step 7: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Views/NewTelnetConnectionView.swift
  git add CodeEdit/Features/WindowCommands/FileCommands.swift
  git add CodeEdit/AppDelegate.swift
  git add CodeEdit/Features/Documents/Controllers/CodeEditWindowControllerExtensions.swift
  git commit -m "feat: add New Telnet Connection sheet and menu command"
  ```

---

# Part B — Session Persistence

## Task 5: SessionFolder Model + folderID on RemoteSession

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Sessions/SessionFolder.swift`
- Modify: `CodeEdit/Features/RemoteTerminal/Sessions/RemoteSession.swift`
- Test: `CodeEditTests/Features/RemoteTerminal/SessionFolderTests.swift`

- [ ] **Step 1: Write the failing test**

  Create `CodeEditTests/Features/RemoteTerminal/SessionFolderTests.swift`:

  ```swift
  import XCTest
  @testable import CodeEdit

  final class SessionFolderTests: XCTestCase {

      func test_defaults() {
          let folder = SessionFolder(name: "Routers")
          XCTAssertEqual(folder.name, "Routers")
          XCTAssertNil(folder.parentID)
          XCTAssertTrue(folder.childIDs.isEmpty)
      }

      func test_uniqueIDs() {
          let a = SessionFolder(name: "a")
          let b = SessionFolder(name: "b")
          XCTAssertNotEqual(a.id, b.id)
      }

      func test_codableRoundTrip() throws {
          let parent = UUID()
          let child = UUID()
          let original = SessionFolder(name: "Lab", parentID: parent, childIDs: [child])
          let data = try JSONEncoder().encode(original)
          let decoded = try JSONDecoder().decode(SessionFolder.self, from: data)
          XCTAssertEqual(decoded.id, original.id)
          XCTAssertEqual(decoded.name, "Lab")
          XCTAssertEqual(decoded.parentID, parent)
          XCTAssertEqual(decoded.childIDs, [child])
      }

      func test_remoteSession_defaultFolderIDisNil() {
          let session = RemoteSession(name: "s", hostname: "h", username: "u")
          XCTAssertNil(session.folderID)
      }

      func test_remoteSession_folderIDRoundTrips() throws {
          let folderID = UUID()
          let session = RemoteSession(name: "s", hostname: "h", username: "u", folderID: folderID)
          let data = try JSONEncoder().encode(session)
          let decoded = try JSONDecoder().decode(RemoteSession.self, from: data)
          XCTAssertEqual(decoded.folderID, folderID)
      }
  }
  ```

- [ ] **Step 2: Run, confirm compile error**

  ⌘U. Expected: `SessionFolder` not found, and `RemoteSession` has no `folderID` parameter.

- [ ] **Step 3: Create SessionFolder.swift**

  Create `CodeEdit/Features/RemoteTerminal/Sessions/SessionFolder.swift`:

  ```swift
  //
  //  SessionFolder.swift
  //  CodeEdit
  //

  import Foundation

  /// A folder in the remote-session tree. Holds an ordered list of child IDs,
  /// which may reference either nested ``SessionFolder``s or ``RemoteSession``s.
  struct SessionFolder: Identifiable, Codable, Equatable {
      var id: UUID
      var name: String
      var parentID: UUID?
      var childIDs: [UUID]

      init(
          id: UUID = UUID(),
          name: String,
          parentID: UUID? = nil,
          childIDs: [UUID] = []
      ) {
          self.id = id
          self.name = name
          self.parentID = parentID
          self.childIDs = childIDs
      }
  }
  ```

- [ ] **Step 4: Add folderID to RemoteSession**

  In `CodeEdit/Features/RemoteTerminal/Sessions/RemoteSession.swift`:

  Add the stored property after `var lastConnectedAt: Date?` (line 40):

  ```swift
      var folderID: UUID?
  ```

  Add the init parameter — change the initializer signature so the parameter list reads (insert `folderID` before `notes`):

  ```swift
      init(
          id: UUID = UUID(),
          name: String,
          protocol connectionProtocol: ConnectionProtocol = .ssh,
          hostname: String,
          port: Int? = nil,
          username: String,
          authMethod: AuthMethod = .password,
          folderID: UUID? = nil,
          notes: String = "",
          createdAt: Date = Date()
      ) {
  ```

  And inside the init body, add this line after `self.authMethod = authMethod` (line 59):

  ```swift
          self.folderID = folderID
  ```

- [ ] **Step 5: Run tests, confirm all pass**

  ⌘U. Expected: all `SessionFolderTests` pass, and the existing `RemoteSessionTests` still pass (the new parameter is defaulted).

- [ ] **Step 6: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Sessions/SessionFolder.swift
  git add CodeEdit/Features/RemoteTerminal/Sessions/RemoteSession.swift
  git add CodeEditTests/Features/RemoteTerminal/SessionFolderTests.swift
  git commit -m "feat: add SessionFolder model and folderID on RemoteSession"
  ```

---

## Task 6: SessionStore (GRDB persistence)

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Sessions/SessionStore.swift`
- Test: `CodeEditTests/Features/RemoteTerminal/SessionStoreTests.swift`

Follows the existing `EditorStateRestoration` pattern exactly: one SQLite file, `DatabaseQueue`, a `DatabaseMigrator`, and a blob-per-row schema. Each session/folder is stored as a JSON-encoded blob keyed by its UUID string. The initializer accepts an explicit database URL so tests can use a temporary file.

> **Why blob-per-row, not relational columns:** it reuses the proven in-repo pattern, sidesteps GRDB column mapping for the nested `AuthMethod` enum, and is trivially fast for the hundreds-of-sessions scale this targets. If Phase 3 search profiling ever demands SQL `WHERE`, add denormalized indexed columns in a "Version 1" migration then — never delete "Version 0".

- [ ] **Step 1: Write the failing test**

  Create `CodeEditTests/Features/RemoteTerminal/SessionStoreTests.swift`:

  ```swift
  import XCTest
  @testable import CodeEdit

  final class SessionStoreTests: XCTestCase {

      private var tempURL: URL!
      private var store: SessionStore!

      override func setUpWithError() throws {
          tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("session-store-test-\(UUID().uuidString).db")
          store = try SessionStore(tempURL)
      }

      override func tearDownWithError() throws {
          store = nil
          try? FileManager.default.removeItem(at: tempURL)
      }

      func test_emptyStore_returnsNoSessions() {
          XCTAssertTrue(store.allSessions().isEmpty)
      }

      func test_saveThenFetchSession() {
          let session = RemoteSession(name: "Router-1", hostname: "10.0.0.1", username: "admin")
          store.saveSession(session)
          let all = store.allSessions()
          XCTAssertEqual(all.count, 1)
          XCTAssertEqual(all.first?.id, session.id)
          XCTAssertEqual(all.first?.hostname, "10.0.0.1")
      }

      func test_saveIsUpsert() {
          var session = RemoteSession(name: "Old", hostname: "h", username: "u")
          store.saveSession(session)
          session.name = "New"
          store.saveSession(session)
          let all = store.allSessions()
          XCTAssertEqual(all.count, 1)
          XCTAssertEqual(all.first?.name, "New")
      }

      func test_deleteSession() {
          let session = RemoteSession(name: "s", hostname: "h", username: "u")
          store.saveSession(session)
          store.deleteSession(id: session.id)
          XCTAssertTrue(store.allSessions().isEmpty)
      }

      func test_authMethodAndFolderIDRoundTrip() {
          let keyID = UUID()
          let folderID = UUID()
          let session = RemoteSession(
              name: "s",
              hostname: "h",
              username: "u",
              authMethod: .publicKey(keyID: keyID),
              folderID: folderID
          )
          store.saveSession(session)
          let fetched = store.allSessions().first
          XCTAssertEqual(fetched?.authMethod, .publicKey(keyID: keyID))
          XCTAssertEqual(fetched?.folderID, folderID)
      }

      func test_saveThenFetchFolder() {
          let folder = SessionFolder(name: "Lab")
          store.saveFolder(folder)
          let all = store.allFolders()
          XCTAssertEqual(all.count, 1)
          XCTAssertEqual(all.first?.name, "Lab")
      }

      func test_deleteFolder() {
          let folder = SessionFolder(name: "Lab")
          store.saveFolder(folder)
          store.deleteFolder(id: folder.id)
          XCTAssertTrue(store.allFolders().isEmpty)
      }
  }
  ```

- [ ] **Step 2: Run, confirm compile error**

  ⌘U. Expected: `SessionStore` not found.

- [ ] **Step 3: Create SessionStore.swift**

  Create `CodeEdit/Features/RemoteTerminal/Sessions/SessionStore.swift`:

  ```swift
  //
  //  SessionStore.swift
  //  CodeEdit
  //

  import Foundation
  import GRDB
  import OSLog

  /// Persists ``RemoteSession`` and ``SessionFolder`` records to a SQLite database
  /// at `~/Library/Application Support/CodeEdit/sessions.db`.
  ///
  /// Mirrors the `EditorStateRestoration` pattern: a globally shared, synchronous
  /// `DatabaseQueue` with a `DatabaseMigrator`. Each record is stored as a JSON blob
  /// keyed by its UUID string.
  ///
  /// # If changes are required
  ///
  /// Add a new migration version in `attemptMigration`. **Never** delete a migration
  /// that has shipped in a released build.
  final class SessionStore {
      /// Optional so callers can degrade gracefully if the database fails to open.
      static let shared: SessionStore? = try? SessionStore()

      private static let logger = Logger(
          subsystem: Bundle.main.bundleIdentifier ?? "",
          category: "SessionStore"
      )

      struct SessionRecord: Codable, TableRecord, FetchableRecord, PersistableRecord {
          static let databaseTableName = "remoteSession"
          let id: String
          let data: Data
      }

      struct FolderRecord: Codable, TableRecord, FetchableRecord, PersistableRecord {
          static let databaseTableName = "sessionFolder"
          let id: String
          let data: Data
      }

      private var databaseQueue: DatabaseQueue?
      private var databaseURL: URL

      /// - Parameter databaseURL: File URL for the database. If `nil`, uses
      ///   `sessions.db` in the application support directory.
      init(_ databaseURL: URL? = nil) throws {
          self.databaseURL = databaseURL ?? FileManager.default
              .homeDirectoryForCurrentUser
              .appending(path: "Library/Application Support/CodeEdit", directoryHint: .isDirectory)
              .appending(path: "sessions.db", directoryHint: .notDirectory)
          try attemptMigration(retry: true)
      }

      func attemptMigration(retry: Bool) throws {
          do {
              let databaseQueue = try DatabaseQueue(path: databaseURL.absolutePath, configuration: .init())

              var migrator = DatabaseMigrator()
              migrator.registerMigration("Version 0") { db in
                  try db.create(table: "remoteSession") { table in
                      table.column("id", .text).primaryKey().notNull()
                      table.column("data", .blob).notNull()
                  }
                  try db.create(table: "sessionFolder") { table in
                      table.column("id", .text).primaryKey().notNull()
                      table.column("data", .blob).notNull()
                  }
              }

              try migrator.migrate(databaseQueue)
              self.databaseQueue = databaseQueue
          } catch {
              if retry {
                  // Deleting on failure can recover from corruption or a version error.
                  try? FileManager.default.removeItem(at: databaseURL)
                  try attemptMigration(retry: false)
                  return
              }
              Self.logger.error("Failed to start session database: \(error)")
              throw error
          }
      }

      // MARK: - Sessions

      func allSessions() -> [RemoteSession] {
          do {
              let records = try databaseQueue?.read { try SessionRecord.fetchAll($0) } ?? []
              return records.compactMap { try? JSONDecoder().decode(RemoteSession.self, from: $0.data) }
          } catch {
              Self.logger.error("Failed to fetch sessions: \(error)")
              return []
          }
      }

      func saveSession(_ session: RemoteSession) {
          do {
              let data = try JSONEncoder().encode(session)
              let record = SessionRecord(id: session.id.uuidString, data: data)
              try databaseQueue?.write { try record.upsert($0) }
          } catch {
              Self.logger.error("Failed to save session: \(error)")
          }
      }

      func deleteSession(id: UUID) {
          do {
              _ = try databaseQueue?.write { try SessionRecord.deleteOne($0, key: id.uuidString) }
          } catch {
              Self.logger.error("Failed to delete session: \(error)")
          }
      }

      // MARK: - Folders

      func allFolders() -> [SessionFolder] {
          do {
              let records = try databaseQueue?.read { try FolderRecord.fetchAll($0) } ?? []
              return records.compactMap { try? JSONDecoder().decode(SessionFolder.self, from: $0.data) }
          } catch {
              Self.logger.error("Failed to fetch folders: \(error)")
              return []
          }
      }

      func saveFolder(_ folder: SessionFolder) {
          do {
              let data = try JSONEncoder().encode(folder)
              let record = FolderRecord(id: folder.id.uuidString, data: data)
              try databaseQueue?.write { try record.upsert($0) }
          } catch {
              Self.logger.error("Failed to save folder: \(error)")
          }
      }

      func deleteFolder(id: UUID) {
          do {
              _ = try databaseQueue?.write { try FolderRecord.deleteOne($0, key: id.uuidString) }
          } catch {
              Self.logger.error("Failed to delete folder: \(error)")
          }
      }
  }
  ```

- [ ] **Step 4: Run tests, confirm all pass**

  ⌘U. Expected: all `SessionStoreTests` pass.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Sessions/SessionStore.swift
  git add CodeEditTests/Features/RemoteTerminal/SessionStoreTests.swift
  git commit -m "feat: add SessionStore GRDB persistence for sessions and folders"
  ```

---

## Task 7: SessionCredentialStore (Keychain)

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Sessions/SessionCredentialStore.swift`
- Test: `CodeEditTests/Features/RemoteTerminal/SessionCredentialStoreTests.swift`

Wraps the existing `CodeEditKeychain` so passwords never live in the SQLite database. Credentials are keyed by the session's UUID string under a dedicated key prefix.

- [ ] **Step 1: Write the failing test**

  Create `CodeEditTests/Features/RemoteTerminal/SessionCredentialStoreTests.swift`:

  ```swift
  import XCTest
  @testable import CodeEdit

  final class SessionCredentialStoreTests: XCTestCase {

      // Use a unique prefix per test run so we never collide with real credentials,
      // and clean up in tearDown.
      private var store: SessionCredentialStore!
      private var sessionID: UUID!

      override func setUp() {
          super.setUp()
          let keychain = CodeEditKeychain(keyPrefix: "test-session-credential-\(UUID().uuidString)-")
          store = SessionCredentialStore(keychain: keychain)
          sessionID = UUID()
      }

      override func tearDown() {
          store.deletePassword(forSessionID: sessionID)
          super.tearDown()
      }

      func test_missingPassword_returnsNil() {
          XCTAssertNil(store.password(forSessionID: sessionID))
      }

      func test_setThenGetPassword() {
          store.setPassword("hunter2", forSessionID: sessionID)
          XCTAssertEqual(store.password(forSessionID: sessionID), "hunter2")
      }

      func test_overwritePassword() {
          store.setPassword("first", forSessionID: sessionID)
          store.setPassword("second", forSessionID: sessionID)
          XCTAssertEqual(store.password(forSessionID: sessionID), "second")
      }

      func test_deletePassword() {
          store.setPassword("secret", forSessionID: sessionID)
          store.deletePassword(forSessionID: sessionID)
          XCTAssertNil(store.password(forSessionID: sessionID))
      }
  }
  ```

- [ ] **Step 2: Run, confirm compile error**

  ⌘U. Expected: `SessionCredentialStore` not found.

- [ ] **Step 3: Create SessionCredentialStore.swift**

  Create `CodeEdit/Features/RemoteTerminal/Sessions/SessionCredentialStore.swift`:

  ```swift
  //
  //  SessionCredentialStore.swift
  //  CodeEdit
  //

  import Foundation

  /// Stores remote-session passwords in the macOS Keychain via ``CodeEditKeychain``.
  /// Credentials are keyed by the session's UUID under a dedicated key prefix so they
  /// never touch the session database on disk.
  struct SessionCredentialStore {
      private let keychain: CodeEditKeychain

      init(keychain: CodeEditKeychain = CodeEditKeychain(keyPrefix: "session-credential-")) {
          self.keychain = keychain
      }

      /// Stores (or overwrites) the password for a session.
      func setPassword(_ password: String, forSessionID id: UUID) {
          keychain.set(password, forKey: id.uuidString)
      }

      /// Returns the stored password for a session, or `nil` if none is saved.
      func password(forSessionID id: UUID) -> String? {
          keychain.get(id.uuidString)
      }

      /// Removes any stored password for a session.
      func deletePassword(forSessionID id: UUID) {
          keychain.delete(id.uuidString)
      }
  }
  ```

- [ ] **Step 4: Run tests, confirm all pass**

  ⌘U. Expected: all `SessionCredentialStoreTests` pass.

  > If the Keychain tests fail with a `-34018` (errSecMissingEntitlement) or `-25291` result code in your environment, it means the test host lacks Keychain access. Run the tests through the app's test host scheme (the same one Phase 1's tests use) rather than a bare bundle.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Sessions/SessionCredentialStore.swift
  git add CodeEditTests/Features/RemoteTerminal/SessionCredentialStoreTests.swift
  git commit -m "feat: add SessionCredentialStore for Keychain-backed session passwords"
  ```

---

## Self-Review Checklist

**Spec coverage (from `2026-06-07-remote-terminal-design.md`):**
- ✅ Telnet via Network.framework `NWConnection` + NVT option negotiation (Tasks 1–2)
- ✅ `TelnetConnection` conforms to the unified `TerminalConnection` protocol (Task 2)
- ✅ Telnet sessions appear in the utility area as tabs, sharing the display layer with SSH (Task 3)
- ✅ Default Telnet port = 23 (RemoteSession default + sheet default) (Tasks 4, 5)
- ✅ `RemoteSession` gains `folderID` (Task 5)
- ✅ `SessionFolder` model with ordered `childIDs` (Task 5)
- ✅ GRDB persistence at `~/Library/Application Support/CodeEdit/sessions.db` (Task 6)
- ✅ Passwords in Keychain via existing `CodeEditKeychain` utility (Task 7)

**Deferred to later phases (by design):**
- Session Manager navigator tab + detachable panel UI (Phase 3)
- Wiring saved sessions/credentials into the connect flow + SecureCRT import (Phase 3)
- Host-key / known-hosts verification (Phase 3)
- Relational/indexed search columns, if profiling demands (Phase 3+)
- Keyword highlighting (Phase 4), Sanitization (Phase 5), Themes (Phase 6), AI (Phase 7)

**Placeholder scan:** No TBD/TODO placeholders; every code step contains complete, runnable code.

**Type consistency confirmed:**
- `TelnetParser.process(bytes:) -> (data: [UInt8], responses: [UInt8])` — used identically in tests (Task 1) and `TelnetConnection.receiveLoop` (Task 2).
- `TelnetParser.nawsSubnegotiation(cols:rows:)` and `.nawsEnabled` — referenced consistently in Tasks 1 and 2.
- `TelnetConnection(session:)` — single initializer used in Task 2 tests, Task 3 cache.
- `TerminalConnectionType.telnet(session:)` — defined (Task 3 step 1), produced (`addTelnetTerminal`, Task 3 step 2; `NewTelnetConnectionView`, Task 4), consumed (`RemoteTerminalCache.view(for:)`, Task 3 step 3; render branch, Task 3 step 6).
- `RemoteTerminalCache` / `RemoteTerminalNSView` — renamed consistently across the cache, state property, render branch, and onChange cleanup (Task 3 steps 3–7).
- `RemoteSession(... folderID: ...)` — new parameter defined (Task 5) and used in `SessionStoreTests` (Task 6).
- `SessionStore(_ databaseURL:)` — `nil`-defaulted init used by `shared` and by tests with a temp URL.
- `SessionCredentialStore(keychain:)` — `CodeEditKeychain`-defaulted init; tests inject a unique-prefix keychain.
- `CodeEditKeychain.set(_:forKey:)` / `.get(_:)` / `.delete(_:)` — match the real API in `CodeEdit/Utils/KeyChain/CodeEditKeychain.swift`.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-08-phase2-telnet-session-model.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, with checkpoints for review.

Which approach?
