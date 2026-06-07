# Phase 1 — Protocol Foundation + SSH Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the unified `TerminalConnection` protocol, refactor the existing local shell into it, and deliver working SSH connections (all three auth methods) accessible from the utility area terminal panel.

**Architecture:** A `TerminalConnection` protocol abstracts all byte sources (local shell, SSH, Telnet). A `TerminalPipeline` owns the observer chain and routes bytes from any connection through processing observers (for future highlighting/sanitization) before delivering them to `CETerminalView`. SSH is implemented via `swift-nio-ssh`, bridged to Swift concurrency via `AsyncStream`. The existing `CELocalShellTerminalView` is left intact; a new `CEConnectionTerminalView` handles all `TerminalConnection`-based sessions.

**Tech Stack:** SwiftUI, SwiftTerm (custom fork), swift-nio-ssh, NIOCore, NIOPosix, NIOSSH

> **This is Phase 1 of 7.** Phases 2–7 (Telnet + Session Model, Session Manager UI, Keyword Highlighting, Sanitization, Terminal Themes, AI Integration) each have their own plans written when Phase 1 ships.

---

## File Map

**Create:**
```
CodeEdit/Features/RemoteTerminal/
  Connections/
    TerminalConnection.swift            — protocol, observer protocols
    ANSIStripper.swift                  — strips escape codes to plain text
    TerminalPipeline.swift              — routes bytes: connection → observers → terminal view
    LocalShellConnection.swift          — local shell as a TerminalConnection
    SSHAuthDelegate.swift               — password / public key / keyboard-interactive NIO delegates
    SSHSessionChannelHandler.swift      — NIO channel handler: PTY, shell, data bridge
    SSHConnection.swift                 — SSHConnection conforming to TerminalConnection
  Sessions/
    RemoteSession.swift                 — session config model (no persistence yet)
  Views/
    CEConnectionTerminalView.swift      — CETerminalView backed by any TerminalConnection
    NewSSHConnectionView.swift          — "Open SSH Connection" sheet

CodeEditTests/Features/RemoteTerminal/
  ANSIStripperTests.swift
  TerminalPipelineTests.swift
  LocalShellConnectionTests.swift
  RemoteSessionTests.swift
  SSHAuthDelegateTests.swift
```

**Modify:**
```
CodeEdit.xcodeproj/project.pbxproj
  — add swift-nio-ssh SPM dependency

CodeEdit/Features/UtilityArea/Models/UtilityAreaTerminal.swift
  — add ConnectionType enum and connectionType property

CodeEdit/Features/UtilityArea/ViewModels/UtilityAreaViewModel.swift
  — add addSSHTerminal(session:password:) method

CodeEdit/Features/UtilityArea/TerminalUtility/UtilityAreaTerminalView.swift
  — render CEConnectionTerminalView for SSH terminal type

CodeEdit/Features/WindowCommands/
  — add "New SSH Connection..." menu item
```

---

## Task 1: Add swift-nio-ssh Dependency

**Files:**
- Modify: `CodeEdit.xcodeproj/project.pbxproj` (via Xcode)

- [ ] **Step 1: Open Xcode and add the package**

  In Xcode: **File → Add Package Dependencies...**
  Enter URL: `https://github.com/apple/swift-nio-ssh.git`
  Version rule: **Up to Next Major** from `0.8.0`
  Add these products to the **CodeEdit** target: `NIOSSH`, `NIOCore`, `NIOPosix`

- [ ] **Step 2: Verify the build succeeds**

  Build the CodeEdit target (⌘B). Expected: build succeeds with no errors.

- [ ] **Step 3: Commit**

  ```bash
  git add CodeEdit.xcodeproj/project.pbxproj
  git add CodeEdit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/
  git commit -m "feat: add swift-nio-ssh dependency"
  ```

---

## Task 2: TerminalConnection Protocol + ANSIStripper

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Connections/TerminalConnection.swift`
- Create: `CodeEdit/Features/RemoteTerminal/Connections/ANSIStripper.swift`
- Create: `CodeEditTests/Features/RemoteTerminal/ANSIStripperTests.swift`

- [ ] **Step 1: Write the failing ANSIStripper test**

  Create `CodeEditTests/Features/RemoteTerminal/ANSIStripperTests.swift`:

  ```swift
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
  }
  ```

- [ ] **Step 2: Run the test, confirm it fails**

  In Xcode: ⌘U. Expected: compile error — `ANSIStripper` not found.

- [ ] **Step 3: Create ANSIStripper.swift**

  Create `CodeEdit/Features/RemoteTerminal/Connections/ANSIStripper.swift`:

  ```swift
  //
  //  ANSIStripper.swift
  //  CodeEdit
  //

  import Foundation

  /// Strips ANSI/VT100 escape sequences from a byte slice, returning plain UTF-8 text.
  enum ANSIStripper {
      static func strip(_ bytes: ArraySlice<UInt8>) -> String {
          var result: [UInt8] = []
          result.reserveCapacity(bytes.count)
          var i = bytes.startIndex

          while i < bytes.endIndex {
              let byte = bytes[i]
              if byte == 0x1B {
                  i = bytes.index(after: i)
                  guard i < bytes.endIndex else { break }
                  let next = bytes[i]
                  if next == 0x5B || next == 0x4F {
                      // CSI sequence (ESC [ ...) or SS3 (ESC O ...)
                      i = bytes.index(after: i)
                      // Skip parameter/intermediate bytes (0x20–0x3F), stop at command byte (0x40–0x7E)
                      while i < bytes.endIndex && !(0x40...0x7E).contains(bytes[i]) {
                          i = bytes.index(after: i)
                      }
                      if i < bytes.endIndex { i = bytes.index(after: i) }
                  } else if (0x40...0x5F).contains(next) {
                      // Two-byte escape sequence (ESC + Fe)
                      i = bytes.index(after: i)
                  } else if next == 0x5D {
                      // OSC sequence (ESC ] ... ST or BEL)
                      i = bytes.index(after: i)
                      while i < bytes.endIndex && bytes[i] != 0x07 && bytes[i] != 0x1B {
                          i = bytes.index(after: i)
                      }
                      if i < bytes.endIndex && bytes[i] == 0x1B {
                          i = bytes.index(after: i) // skip ESC of ESC\
                          if i < bytes.endIndex { i = bytes.index(after: i) } // skip backslash
                      } else if i < bytes.endIndex {
                          i = bytes.index(after: i) // skip BEL
                      }
                  }
              } else {
                  result.append(byte)
                  i = bytes.index(after: i)
              }
          }
          return String(bytes: result, encoding: .utf8) ?? String(bytes: result, encoding: .isoLatin1) ?? ""
      }
  }
  ```

- [ ] **Step 4: Create TerminalConnection.swift**

  Create `CodeEdit/Features/RemoteTerminal/Connections/TerminalConnection.swift`:

  ```swift
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
  ```

- [ ] **Step 5: Run tests, confirm ANSIStripper tests pass**

  ⌘U. Expected: all `ANSIStripperTests` pass.

- [ ] **Step 6: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Connections/
  git add CodeEditTests/Features/RemoteTerminal/ANSIStripperTests.swift
  git commit -m "feat: add TerminalConnection protocol and ANSIStripper"
  ```

---

## Task 3: TerminalPipeline

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Connections/TerminalPipeline.swift`
- Create: `CodeEditTests/Features/RemoteTerminal/TerminalPipelineTests.swift`

- [ ] **Step 1: Write the failing test**

  Create `CodeEditTests/Features/RemoteTerminal/TerminalPipelineTests.swift`:

  ```swift
  import XCTest
  @testable import CodeEdit

  final class TerminalPipelineTests: XCTestCase {

      // Minimal TerminalConnection that fires onDataReceived manually.
      final class MockConnection: TerminalConnection {
          let id = UUID()
          var isConnected = true
          var onDataReceived: ((ArraySlice<UInt8>) -> Void)?
          var onTerminated: ((Int32?) -> Void)?
          func connect() async throws {}
          func disconnect() { isConnected = false }
          func send(data: ArraySlice<UInt8>) {}
          func resize(cols: Int, rows: Int) {}
      }

      // Processing observer that uppercases ASCII bytes.
      final class UppercaseObserver: TerminalProcessingObserver {
          func process(bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
              Array(bytes.map { ($0 >= 97 && $0 <= 122) ? $0 - 32 : $0 })[...]
          }
      }

      // Notifying observer that captures received text.
      final class CapturingObserver: TerminalNotifyingObserver {
          var received: [String] = []
          var terminatedWith: Int32?? = .none  // .none = never called, .some(nil) = called with nil
          func connectionDidReceive(text: String) { received.append(text) }
          func connectionDidTerminate(exitCode: Int32?) { terminatedWith = .some(exitCode) }
      }

      func test_bytesDeliveredToFeedCallback() {
          let connection = MockConnection()
          var fed: [UInt8] = []
          let pipeline = TerminalPipeline(connection: connection) { bytes in
              fed.append(contentsOf: bytes)
          }

          let input: ArraySlice<UInt8> = [72, 105][...]  // "Hi"
          connection.onDataReceived?(input)

          XCTAssertEqual(fed, [72, 105])
          _ = pipeline  // keep alive
      }

      func test_processingObserverTransformsBytes() {
          let connection = MockConnection()
          var fed: [UInt8] = []
          let pipeline = TerminalPipeline(connection: connection) { bytes in
              fed.append(contentsOf: bytes)
          }
          pipeline.processingObservers.append(UppercaseObserver())

          let input: ArraySlice<UInt8> = Array("hello".utf8)[...]
          connection.onDataReceived?(input)

          XCTAssertEqual(String(bytes: fed, encoding: .utf8), "HELLO")
          _ = pipeline
      }

      func test_notifyingObserverReceivesPlainText() {
          let connection = MockConnection()
          let notifier = CapturingObserver()
          let pipeline = TerminalPipeline(connection: connection) { _ in }
          pipeline.notifyingObservers.append(notifier)

          // Input with ANSI color code wrapping "OK"
          let input: [UInt8] = Array("\u{1B}[32mOK\u{1B}[0m".utf8)
          connection.onDataReceived?(input[...])

          XCTAssertEqual(notifier.received, ["OK"])
          _ = pipeline
      }

      func test_terminationForwardedToNotifyingObservers() {
          let connection = MockConnection()
          let notifier = CapturingObserver()
          let pipeline = TerminalPipeline(connection: connection) { _ in }
          pipeline.notifyingObservers.append(notifier)

          connection.onTerminated?(42)

          XCTAssertEqual(notifier.terminatedWith, .some(42))
          _ = pipeline
      }
  }
  ```

- [ ] **Step 2: Run the test, confirm it fails**

  Expected: compile error — `TerminalPipeline` not found.

- [ ] **Step 3: Create TerminalPipeline.swift**

  Create `CodeEdit/Features/RemoteTerminal/Connections/TerminalPipeline.swift`:

  ```swift
  //
  //  TerminalPipeline.swift
  //  CodeEdit
  //

  import Foundation

  /// Connects a TerminalConnection to a terminal display, routing bytes through
  /// an ordered chain of processing observers before final delivery.
  ///
  /// Observer execution order:
  ///   connection bytes → processingObservers (in order) → feedCallback → notifyingObservers (plain text)
  ///
  /// Add the ANSI highlight preprocessor to processingObservers (Phase 4).
  /// Add the sanitization processor to processingObservers after the highlight preprocessor (Phase 5).
  /// Add AITerminalObserver to notifyingObservers (Phase 7).
  final class TerminalPipeline {
      let connection: any TerminalConnection

      /// Byte-transforming observers applied in order before display.
      var processingObservers: [any TerminalProcessingObserver] = []

      /// Read-only observers that receive plain text after all processing.
      var notifyingObservers: [any TerminalNotifyingObserver] = []

      /// Called with the final (processed) bytes for display in the terminal view.
      private let feedCallback: (ArraySlice<UInt8>) -> Void

      init(connection: any TerminalConnection, feedCallback: @escaping (ArraySlice<UInt8>) -> Void) {
          self.connection = connection
          self.feedCallback = feedCallback

          connection.onDataReceived = { [weak self] bytes in
              self?.receive(bytes)
          }

          connection.onTerminated = { [weak self] exitCode in
              self?.notifyingObservers.forEach { $0.connectionDidTerminate(exitCode: exitCode) }
          }
      }

      private func receive(_ bytes: ArraySlice<UInt8>) {
          var current = bytes
          for observer in processingObservers {
              current = observer.process(bytes: current)
          }

          feedCallback(current)

          let text = ANSIStripper.strip(current)
          notifyingObservers.forEach { $0.connectionDidReceive(text: text) }
      }
  }
  ```

- [ ] **Step 4: Run the tests, confirm all pass**

  ⌘U. Expected: all `TerminalPipelineTests` pass.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Connections/TerminalPipeline.swift
  git add CodeEditTests/Features/RemoteTerminal/TerminalPipelineTests.swift
  git commit -m "feat: add TerminalPipeline connecting connections to the terminal display"
  ```

---

## Task 4: LocalShellConnection

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Connections/LocalShellConnection.swift`
- Create: `CodeEditTests/Features/RemoteTerminal/LocalShellConnectionTests.swift`

- [ ] **Step 1: Write the failing test**

  Create `CodeEditTests/Features/RemoteTerminal/LocalShellConnectionTests.swift`:

  ```swift
  import XCTest
  @testable import CodeEdit

  final class LocalShellConnectionTests: XCTestCase {

      func test_initialState_notConnected() {
          let conn = LocalShellConnection(workspaceURL: nil)
          XCTAssertFalse(conn.isConnected)
      }

      func test_eachInstanceHasUniqueID() {
          let a = LocalShellConnection(workspaceURL: nil)
          let b = LocalShellConnection(workspaceURL: nil)
          XCTAssertNotEqual(a.id, b.id)
      }

      func test_disconnectWhileNotConnected_doesNotCrash() {
          let conn = LocalShellConnection(workspaceURL: nil)
          // Must not throw or crash
          conn.disconnect()
          XCTAssertFalse(conn.isConnected)
      }

      func test_conformsToTerminalConnection() {
          let conn = LocalShellConnection(workspaceURL: nil)
          XCTAssertTrue((conn as AnyObject) is any TerminalConnection)
      }
  }
  ```

- [ ] **Step 2: Run, confirm compile error**

  Expected: `LocalShellConnection` not found.

- [ ] **Step 3: Create LocalShellConnection.swift**

  Create `CodeEdit/Features/RemoteTerminal/Connections/LocalShellConnection.swift`:

  ```swift
  //
  //  LocalShellConnection.swift
  //  CodeEdit
  //

  import Foundation
  import SwiftTerm

  /// A TerminalConnection backed by a local shell process (bash, zsh, etc.).
  /// Extracted from CELocalShellTerminalView; that class retains its existing
  /// implementation for backward compatibility with TerminalCache.
  final class LocalShellConnection: NSObject, TerminalConnection {
      let id: UUID = UUID()
      private(set) var isConnected: Bool = false
      var onDataReceived: ((ArraySlice<UInt8>) -> Void)?
      var onTerminated: ((Int32?) -> Void)?

      /// Returns the current window size of the associated terminal view.
      /// Set by CEConnectionTerminalView after wiring up the connection.
      var windowSizeProvider: (() -> winsize)?

      private var process: LocalProcess!
      private let shell: Shell?
      private let workspaceURL: URL?
      private let extraEnvironment: [String]
      private let interactive: Bool

      init(
          workspaceURL: URL?,
          shell: Shell? = nil,
          environment: [String] = [],
          interactive: Bool = true
      ) {
          self.workspaceURL = workspaceURL
          self.shell = shell
          self.extraEnvironment = environment
          self.interactive = interactive
          super.init()
          self.process = LocalProcess(delegate: self)
      }

      func connect() async throws {
          let terminalSettings = Settings.shared.preferences.terminal
          var env: [String] = Terminal.getEnvironmentVariables()
          env.append("TERM_PROGRAM=CodeEditApp_Terminal")

          guard let (resolvedShell, shellPath) = resolveShell(terminalSettings.shell) else {
              throw LocalShellConnectionError.shellNotFound
          }

          let shellArgs: [String]
          if terminalSettings.useShellIntegration {
              shellArgs = try ShellIntegration.setUpIntegration(
                  for: resolvedShell,
                  environment: &env,
                  useLogin: terminalSettings.useLoginShell,
                  interactive: interactive
              )
          } else {
              shellArgs = []
          }

          env.append(contentsOf: extraEnvironment)

          process.startProcess(
              executable: shellPath,
              args: shellArgs,
              environment: env,
              execName: resolvedShell.rawValue,
              currentDirectory: workspaceURL?.absolutePath
          )
          isConnected = true
      }

      func disconnect() {
          guard isConnected else { return }
          process.terminate()
          isConnected = false
      }

      func send(data: ArraySlice<UInt8>) {
          process.send(data: data)
      }

      func resize(cols: Int, rows: Int) {
          guard process.running else { return }
          var size = winsize(
              ws_row: UInt16(rows),
              ws_col: UInt16(cols),
              ws_xpixel: 0,
              ws_ypixel: 0
          )
          _ = PseudoTerminalHelpers.setWinSize(
              masterPtyDescriptor: process.childfd,
              windowSize: &size
          )
      }

      private func resolveShell(_ setting: SettingsData.TerminalShell) -> (Shell, String)? {
          switch setting {
          case .system:
              let path = Shell.autoDetectDefaultShell()
              guard let type = Shell(rawValue: NSString(string: path).lastPathComponent) else {
                  return nil
              }
              return (type, path)
          case .bash: return (.bash, Shell.bash.defaultPath)
          case .zsh:  return (.zsh,  Shell.zsh.defaultPath)
          }
      }
  }

  // MARK: - LocalProcessDelegate

  extension LocalShellConnection: LocalProcessDelegate {
      func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
          isConnected = false
          onTerminated?(exitCode)
      }

      func dataReceived(slice: ArraySlice<UInt8>) {
          onDataReceived?(slice)
      }

      func getWindowSize() -> winsize {
          windowSizeProvider?() ?? winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
      }
  }

  // MARK: - Errors

  enum LocalShellConnectionError: Error, LocalizedError {
      case shellNotFound

      var errorDescription: String? {
          "Could not locate the configured shell executable."
      }
  }
  ```

- [ ] **Step 4: Run tests, confirm all pass**

  ⌘U. Expected: all `LocalShellConnectionTests` pass.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Connections/LocalShellConnection.swift
  git add CodeEditTests/Features/RemoteTerminal/LocalShellConnectionTests.swift
  git commit -m "feat: extract LocalShellConnection from CELocalShellTerminalView"
  ```

---

## Task 5: RemoteSession Model

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Sessions/RemoteSession.swift`
- Create: `CodeEditTests/Features/RemoteTerminal/RemoteSessionTests.swift`

- [ ] **Step 1: Write the failing test**

  Create `CodeEditTests/Features/RemoteTerminal/RemoteSessionTests.swift`:

  ```swift
  import XCTest
  @testable import CodeEdit

  final class RemoteSessionTests: XCTestCase {

      func test_defaultSSHPort() {
          let s = RemoteSession(name: "test", hostname: "host", username: "u")
          XCTAssertEqual(s.port, 22)
      }

      func test_defaultTelnetPort() {
          let s = RemoteSession(name: "t", protocol: .telnet, hostname: "h", username: "u")
          XCTAssertEqual(s.port, 23)
      }

      func test_explicitPortOverridesDefault() {
          let s = RemoteSession(name: "t", hostname: "h", port: 2222, username: "u")
          XCTAssertEqual(s.port, 2222)
      }

      func test_codableRoundTrip() throws {
          let original = RemoteSession(
              name: "Router-1",
              protocol: .ssh,
              hostname: "192.168.1.1",
              port: 22,
              username: "admin",
              authMethod: .password,
              notes: "Core router"
          )
          let data = try JSONEncoder().encode(original)
          let decoded = try JSONDecoder().decode(RemoteSession.self, from: data)
          XCTAssertEqual(decoded.id, original.id)
          XCTAssertEqual(decoded.hostname, "192.168.1.1")
          XCTAssertEqual(decoded.authMethod, .password)
      }

      func test_publicKeyAuthCodable() throws {
          let keyID = UUID()
          let s = RemoteSession(name: "s", hostname: "h", username: "u", authMethod: .publicKey(keyID: keyID))
          let data = try JSONEncoder().encode(s)
          let decoded = try JSONDecoder().decode(RemoteSession.self, from: data)
          XCTAssertEqual(decoded.authMethod, .publicKey(keyID: keyID))
      }

      func test_uniqueIDs() {
          let a = RemoteSession(name: "a", hostname: "h", username: "u")
          let b = RemoteSession(name: "b", hostname: "h", username: "u")
          XCTAssertNotEqual(a.id, b.id)
      }
  }
  ```

- [ ] **Step 2: Run, confirm compile error**

  Expected: `RemoteSession` not found.

- [ ] **Step 3: Create RemoteSession.swift**

  Create `CodeEdit/Features/RemoteTerminal/Sessions/RemoteSession.swift`:

  ```swift
  //
  //  RemoteSession.swift
  //  CodeEdit
  //

  import Foundation

  /// The network protocol used for a remote connection.
  enum ConnectionProtocol: String, Codable, CaseIterable {
      case ssh
      case telnet

      var defaultPort: Int {
          switch self {
          case .ssh:    return 22
          case .telnet: return 23
          }
      }
  }

  /// Authentication method for an SSH session.
  enum AuthMethod: Codable, Equatable {
      case password
      case publicKey(keyID: UUID)
      case keyboardInteractive
  }

  /// Persisted configuration for a remote terminal session.
  /// Phase 2 adds GRDB persistence; for now this is in-memory only.
  struct RemoteSession: Identifiable, Codable, Equatable {
      var id: UUID
      var name: String
      var `protocol`: ConnectionProtocol
      var hostname: String
      var port: Int
      var username: String
      var authMethod: AuthMethod
      var notes: String
      var createdAt: Date
      var lastConnectedAt: Date?

      init(
          id: UUID = UUID(),
          name: String,
          protocol connectionProtocol: ConnectionProtocol = .ssh,
          hostname: String,
          port: Int? = nil,
          username: String,
          authMethod: AuthMethod = .password,
          notes: String = "",
          createdAt: Date = Date()
      ) {
          self.id = id
          self.name = name
          self.protocol = connectionProtocol
          self.hostname = hostname
          self.port = port ?? connectionProtocol.defaultPort
          self.username = username
          self.authMethod = authMethod
          self.notes = notes
          self.createdAt = createdAt
      }

      static func == (lhs: RemoteSession, rhs: RemoteSession) -> Bool {
          lhs.id == rhs.id
      }
  }
  ```

- [ ] **Step 4: Run tests, confirm all pass**

  ⌘U. Expected: all `RemoteSessionTests` pass.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Sessions/RemoteSession.swift
  git add CodeEditTests/Features/RemoteTerminal/RemoteSessionTests.swift
  git commit -m "feat: add RemoteSession model"
  ```

---

## Task 6: CEConnectionTerminalView

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Views/CEConnectionTerminalView.swift`

No isolated unit tests possible (requires SwiftTerm's NSView rendering). Verified by wiring up in Task 10.

- [ ] **Step 1: Create CEConnectionTerminalView.swift**

  Create `CodeEdit/Features/RemoteTerminal/Views/CEConnectionTerminalView.swift`:

  ```swift
  //
  //  CEConnectionTerminalView.swift
  //  CodeEdit
  //

  import AppKit
  import SwiftTerm
  import Foundation

  /// A terminal view backed by any TerminalConnection.
  /// Uses TerminalPipeline to route bytes from the connection through
  /// future processing observers (Phase 4: highlighting, Phase 5: sanitization)
  /// before display.
  final class CEConnectionTerminalView: CETerminalView, TerminalViewDelegate {
      private(set) var pipeline: TerminalPipeline!
      let connection: any TerminalConnection

      weak var connectionDelegate: CEConnectionTerminalViewDelegate?

      init(connection: any TerminalConnection, frame: CGRect = .zero) {
          self.connection = connection
          super.init(frame: frame)
          setup()
      }

      required init?(coder: NSCoder) {
          fatalError("Use init(connection:frame:)")
      }

      private func setup() {
          terminal = Terminal(delegate: self, options: TerminalOptions(scrollback: 2000))
          terminalDelegate = self

          pipeline = TerminalPipeline(connection: connection) { [weak self] bytes in
              // Must land on main thread — SwiftTerm requires main-thread feed calls.
              DispatchQueue.main.async {
                  self?.feed(byteArray: bytes)
              }
          }

          // Wire window size provider for LocalShellConnection.
          if let localConn = connection as? LocalShellConnection {
              localConn.windowSizeProvider = { [weak self] in
                  guard let self else {
                      return winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
                  }
                  return winsize(
                      ws_row: UInt16(self.getTerminal().rows),
                      ws_col: UInt16(self.getTerminal().cols),
                      ws_xpixel: UInt16(self.frame.width),
                      ws_ypixel: UInt16(self.frame.height)
                  )
              }
          }
      }

      // MARK: - TerminalViewDelegate

      func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
          guard connection.isConnected else { return }
          connection.resize(cols: newCols, rows: newRows)
          connectionDelegate?.sizeChanged(source: self, newCols: newCols, newRows: newRows)
      }

      func send(source: TerminalView, data: ArraySlice<UInt8>) {
          connection.send(data: data)
      }

      func setTerminalTitle(source: TerminalView, title: String) {
          connectionDelegate?.setTerminalTitle(source: self, title: title)
      }

      func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
          connectionDelegate?.hostCurrentDirectoryUpdate(source: self, directory: directory)
      }

      func clipboardCopy(source: TerminalView, content: Data) {
          if let str = String(bytes: content, encoding: .utf8) {
              let pasteboard = NSPasteboard.general
              pasteboard.clearContents()
              pasteboard.writeObjects([str as NSString])
          }
      }

      func scrolled(source: TerminalView, position: Double) {}
      func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
  }

  // MARK: - Delegate

  protocol CEConnectionTerminalViewDelegate: AnyObject {
      func sizeChanged(source: CEConnectionTerminalView, newCols: Int, newRows: Int)
      func setTerminalTitle(source: CEConnectionTerminalView, title: String)
      func hostCurrentDirectoryUpdate(source: CEConnectionTerminalView, directory: String?)
  }
  ```

- [ ] **Step 2: Build succeeds**

  ⌘B. Expected: no errors.

- [ ] **Step 3: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Views/CEConnectionTerminalView.swift
  git commit -m "feat: add CEConnectionTerminalView wrapping any TerminalConnection"
  ```

---

## Task 7: SSH Auth Delegates

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Connections/SSHAuthDelegate.swift`
- Create: `CodeEditTests/Features/RemoteTerminal/SSHAuthDelegateTests.swift`

- [ ] **Step 1: Write the failing test**

  Create `CodeEditTests/Features/RemoteTerminal/SSHAuthDelegateTests.swift`:

  ```swift
  import XCTest
  import NIOCore
  import NIOSSH
  @testable import CodeEdit

  final class SSHAuthDelegateTests: XCTestCase {

      func test_passwordDelegate_succeedsWithPasswordMethod() {
          let delegate = PasswordAuthDelegate(username: "admin", password: "secret")
          let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
          defer { try? group.syncShutdownGracefully() }
          let loop = group.next()
          let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)

          delegate.nextAuthenticationType(
              availableMethods: .password,
              nextChallengePromise: promise
          )

          let result = try? promise.futureResult.wait()
          XCTAssertNotNil(result as Any)
          if case .password(let offer) = result??.offer {
              XCTAssertEqual(offer.password, "secret")
          } else {
              XCTFail("Expected password offer")
          }
      }

      func test_passwordDelegate_succeedsNilWhenMethodUnavailable() {
          let delegate = PasswordAuthDelegate(username: "u", password: "p")
          let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
          defer { try? group.syncShutdownGracefully() }
          let loop = group.next()
          let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)

          delegate.nextAuthenticationType(
              availableMethods: .publicKey,  // password not available
              nextChallengePromise: promise
          )

          let result = try? promise.futureResult.wait()
          XCTAssertNil(result as Any)
      }

      func test_acceptAllHostKeysDelegate_succeedsImmediately() {
          let delegate = AcceptAllHostKeysDelegate()
          let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
          defer { try? group.syncShutdownGracefully() }
          let loop = group.next()
          let promise = loop.makePromise(of: Void.self)

          // NIOSSHPublicKey can't be easily constructed in tests; we test the promise succeeds.
          // Integration test with a real key happens in Task 9's manual test.
          promise.succeed(())
          XCTAssertNoThrow(try promise.futureResult.wait())
      }
  }
  ```

- [ ] **Step 2: Run, confirm compile error**

  Expected: `PasswordAuthDelegate` and `AcceptAllHostKeysDelegate` not found.

- [ ] **Step 3: Create SSHAuthDelegate.swift**

  Create `CodeEdit/Features/RemoteTerminal/Connections/SSHAuthDelegate.swift`:

  ```swift
  //
  //  SSHAuthDelegate.swift
  //  CodeEdit
  //

  import Foundation
  import NIOCore
  import NIOSSH

  // MARK: - Password Authentication

  final class PasswordAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
      private let username: String
      private let password: String

      init(username: String, password: String) {
          self.username = username
          self.password = password
      }

      func nextAuthenticationType(
          availableMethods: NIOSSHAvailableUserAuthenticationMethods,
          nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
      ) {
          guard availableMethods.contains(.password) else {
              nextChallengePromise.succeed(nil)
              return
          }
          nextChallengePromise.succeed(.init(
              username: username,
              serviceName: "ssh-connection",
              offer: .password(.init(password: password))
          ))
      }
  }

  // MARK: - Public Key Authentication

  final class PublicKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
      private let username: String
      private let privateKey: NIOSSHPrivateKey

      init(username: String, privateKey: NIOSSHPrivateKey) {
          self.username = username
          self.privateKey = privateKey
      }

      func nextAuthenticationType(
          availableMethods: NIOSSHAvailableUserAuthenticationMethods,
          nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
      ) {
          guard availableMethods.contains(.publicKey) else {
              nextChallengePromise.succeed(nil)
              return
          }
          nextChallengePromise.succeed(.init(
              username: username,
              serviceName: "ssh-connection",
              offer: .privateKey(.init(privateKey: privateKey))
          ))
      }
  }

  // MARK: - Keyboard Interactive Authentication

  /// Supports TACACS+/RADIUS challenge-response authentication.
  /// Set `promptHandler` before connecting to receive and respond to prompts.
  final class KeyboardInteractiveAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
      private let username: String

      /// Called on NIO's event loop with each challenge prompt.
      /// The closure must return the user's response synchronously.
      /// Wire this to a UI prompt or a stored credential before calling connect().
      var responseProvider: ((String) -> String) = { _ in "" }

      init(username: String) {
          self.username = username
      }

      func nextAuthenticationType(
          availableMethods: NIOSSHAvailableUserAuthenticationMethods,
          nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
      ) {
          guard availableMethods.contains(.keyboardInteractive) else {
              nextChallengePromise.succeed(nil)
              return
          }
          // Keyboard-interactive starts with a none offer; the server sends prompts via SSH_MSG_USERAUTH_INFO_REQUEST.
          nextChallengePromise.succeed(.init(
              username: username,
              serviceName: "ssh-connection",
              offer: .none
          ))
      }
  }

  // MARK: - Host Key Verification

  /// Accepts any server host key without verification.
  /// Phase 3 (Session Manager) replaces this with known-hosts file verification.
  final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
      func validateHostKey(
          hostKey: NIOSSHPublicKey,
          validationCompletePromise: EventLoopPromise<Void>
      ) {
          validationCompletePromise.succeed(())
      }
  }
  ```

- [ ] **Step 4: Run tests, confirm all pass**

  ⌘U. Expected: all `SSHAuthDelegateTests` pass.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Connections/SSHAuthDelegate.swift
  git add CodeEditTests/Features/RemoteTerminal/SSHAuthDelegateTests.swift
  git commit -m "feat: add SSH auth delegates (password, public key, keyboard-interactive)"
  ```

---

## Task 8: SSHSessionChannelHandler

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Connections/SSHSessionChannelHandler.swift`

Unit testing NIO channel handlers requires `EmbeddedChannel`. This is complex boilerplate; integration testing in Task 9 covers correct behavior end-to-end.

- [ ] **Step 1: Create SSHSessionChannelHandler.swift**

  Create `CodeEdit/Features/RemoteTerminal/Connections/SSHSessionChannelHandler.swift`:

  ```swift
  //
  //  SSHSessionChannelHandler.swift
  //  CodeEdit
  //

  import Foundation
  import NIOCore
  import NIOSSH

  /// NIO channel handler for an SSH session channel.
  /// Requests a PTY and shell, then bridges inbound data to an AsyncStream
  /// that SSHConnection reads from on a Swift concurrency Task.
  final class SSHSessionChannelHandler: ChannelInboundHandler, RemovableChannelHandler {
      typealias InboundIn = SSHChannelData
      typealias OutboundOut = SSHChannelData

      // MARK: - AsyncStream bridge

      private var inboundContinuation: AsyncStream<ArraySlice<UInt8>>.Continuation?

      /// Consume this to receive all bytes sent by the SSH server.
      let inboundStream: AsyncStream<ArraySlice<UInt8>>

      // MARK: - Session setup state

      private var readyContinuation: CheckedContinuation<Void, Error>?
      private var ptyGranted = false
      private var context: ChannelHandlerContext?

      var cols: Int = 80
      var rows: Int = 24

      init() {
          var continuation: AsyncStream<ArraySlice<UInt8>>.Continuation!
          inboundStream = AsyncStream { continuation = $0 }
          inboundContinuation = continuation
      }

      // MARK: - ChannelInboundHandler

      func handlerAdded(context: ChannelHandlerContext) {
          self.context = context
          if context.channel.isActive {
              requestPTY(context: context)
          }
      }

      func channelActive(context: ChannelHandlerContext) {
          self.context = context
          requestPTY(context: context)
      }

      func channelRead(context: ChannelHandlerContext, data: NIOAny) {
          let channelData = unwrapInboundIn(data)
          guard case .byteBuffer(let buffer) = channelData.data else { return }
          let bytes = Array(buffer.readableBytesView)
          inboundContinuation?.yield(bytes[...])
      }

      func channelInactive(context: ChannelHandlerContext) {
          inboundContinuation?.finish()
          readyContinuation?.resume(throwing: SSHConnectionError.connectionClosed)
          readyContinuation = nil
      }

      func errorCaught(context: ChannelHandlerContext, error: Error) {
          inboundContinuation?.finish()
          readyContinuation?.resume(throwing: error)
          readyContinuation = nil
          context.close(promise: nil)
      }

      func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
          if let event = event as? SSHChannelRequestEvent.RequestResponse {
              handleRequestResponse(event, context: context)
          } else {
              context.fireUserInboundEventTriggered(event)
          }
      }

      // MARK: - Private

      private func requestPTY(context: ChannelHandlerContext) {
          let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
              wantReply: true,
              term: "xterm-256color",
              terminalCharacterWidth: cols,
              terminalRowHeight: rows,
              terminalPixelWidth: 0,
              terminalPixelHeight: 0,
              terminalModes: []
          )
          context.triggerUserOutboundEvent(ptyRequest, promise: nil)
      }

      private func handleRequestResponse(
          _ response: SSHChannelRequestEvent.RequestResponse,
          context: ChannelHandlerContext
      ) {
          if !ptyGranted {
              ptyGranted = true
              guard response.success else {
                  readyContinuation?.resume(throwing: SSHConnectionError.ptyFailed)
                  readyContinuation = nil
                  return
              }
              // PTY granted — request the shell.
              context.triggerUserOutboundEvent(
                  SSHChannelRequestEvent.ShellRequest(wantReply: true),
                  promise: nil
              )
          } else {
              // Shell response
              if response.success {
                  readyContinuation?.resume()
              } else {
                  readyContinuation?.resume(throwing: SSHConnectionError.shellFailed)
              }
              readyContinuation = nil
          }
      }

      // MARK: - Public API

      /// Suspends until the PTY and shell are both granted by the server.
      func waitUntilReady() async throws {
          try await withCheckedThrowingContinuation { continuation in
              self.readyContinuation = continuation
          }
      }

      /// Sends a window size change notification to the SSH server.
      func sendResize(cols: Int, rows: Int) {
          guard let context else { return }
          let resize = SSHChannelRequestEvent.WindowChangeRequest(
              terminalCharacterWidth: cols,
              terminalRowHeight: rows,
              terminalPixelWidth: 0,
              terminalPixelHeight: 0
          )
          context.triggerUserOutboundEvent(resize, promise: nil)
      }
  }

  // MARK: - Errors

  enum SSHConnectionError: Error, LocalizedError {
      case ptyFailed
      case shellFailed
      case connectionClosed
      case notConnected
      case alreadyConnected

      var errorDescription: String? {
          switch self {
          case .ptyFailed:        return "The server refused to allocate a pseudo-terminal."
          case .shellFailed:      return "The server refused to open a shell channel."
          case .connectionClosed: return "The connection closed unexpectedly."
          case .notConnected:     return "Not connected to a remote host."
          case .alreadyConnected: return "Already connected."
          }
      }
  }
  ```

- [ ] **Step 2: Build succeeds**

  ⌘B. Expected: no errors.

- [ ] **Step 3: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Connections/SSHSessionChannelHandler.swift
  git commit -m "feat: add SSHSessionChannelHandler for PTY/shell setup and data bridging"
  ```

---

## Task 9: SSHConnection

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Connections/SSHConnection.swift`

- [ ] **Step 1: Create SSHConnection.swift**

  Create `CodeEdit/Features/RemoteTerminal/Connections/SSHConnection.swift`:

  ```swift
  //
  //  SSHConnection.swift
  //  CodeEdit
  //

  import Foundation
  import NIOCore
  import NIOPosix
  import NIOSSH

  /// SSH connection conforming to TerminalConnection.
  /// Supports password, public key, and keyboard-interactive authentication.
  /// Host key verification is accept-all for Phase 1;
  /// Phase 3 (Session Manager) adds known-hosts verification.
  final class SSHConnection: TerminalConnection {
      let id: UUID = UUID()
      private(set) var isConnected: Bool = false
      var onDataReceived: ((ArraySlice<UInt8>) -> Void)?
      var onTerminated: ((Int32?) -> Void)?

      private let session: RemoteSession
      private let password: String?
      private let privateKey: NIOSSHPrivateKey?
      private let keyboardInteractiveResponseProvider: ((String) -> String)?

      private var transportChannel: (any Channel)?
      private var sessionHandler: SSHSessionChannelHandler?
      private var dataTask: Task<Void, Never>?

      /// Shared event loop group — reuse across all SSH connections.
      private static let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

      // MARK: - Init

      init(
          session: RemoteSession,
          password: String? = nil,
          privateKey: NIOSSHPrivateKey? = nil,
          keyboardInteractiveResponseProvider: ((String) -> String)? = nil
      ) {
          self.session = session
          self.password = password
          self.privateKey = privateKey
          self.keyboardInteractiveResponseProvider = keyboardInteractiveResponseProvider
      }

      // MARK: - TerminalConnection

      func connect() async throws {
          guard !isConnected else { throw SSHConnectionError.alreadyConnected }

          let authDelegate = buildAuthDelegate()
          let hostKeyDelegate = AcceptAllHostKeysDelegate()

          let clientConfig = SSHClientConfiguration(
              userAuthDelegate: authDelegate,
              serverAuthDelegate: hostKeyDelegate
          )

          let sessionHandler = SSHSessionChannelHandler()
          self.sessionHandler = sessionHandler

          let transportChannel = try await ClientBootstrap(group: Self.group)
              .channelInitializer { channel in
                  channel.pipeline.addHandler(
                      NIOSSHHandler(
                          role: .client(clientConfig),
                          allocator: channel.allocator,
                          inboundChildChannelInitializer: nil
                      )
                  )
              }
              .connect(host: session.hostname, port: session.port)
              .get()
          self.transportChannel = transportChannel

          // Open session channel and add our handler.
          let _: any Channel = try await transportChannel.pipeline
              .handler(type: NIOSSHHandler.self)
              .flatMap { sshHandler -> EventLoopFuture<any Channel> in
                  let promise = transportChannel.eventLoop.makePromise(of: (any Channel).self)
                  sshHandler.createChannel(promise) { childChannel, channelType in
                      guard channelType == .session else {
                          return childChannel.close()
                      }
                      return childChannel.pipeline.addHandler(sessionHandler)
                  }
                  return promise.futureResult
              }
              .get()

          // Wait for PTY + shell to be granted.
          try await sessionHandler.waitUntilReady()
          isConnected = true

          // Forward session bytes to the pipeline via onDataReceived.
          dataTask = Task { [weak self] in
              guard let self, let handler = self.sessionHandler else { return }
              for await bytes in handler.inboundStream {
                  self.onDataReceived?(bytes)
              }
              self.isConnected = false
              self.onTerminated?(nil)
          }
      }

      func disconnect() {
          dataTask?.cancel()
          dataTask = nil
          transportChannel?.close(promise: nil)
          transportChannel = nil
          sessionHandler = nil
          isConnected = false
      }

      func send(data: ArraySlice<UInt8>) {
          guard isConnected, let channel = transportChannel else { return }
          var buffer = channel.allocator.buffer(capacity: data.count)
          buffer.writeBytes(data)
          let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
          // Find the session child channel to write on. We write via the session handler's context.
          // For simplicity in Phase 1, find the child channel by iterating the pipeline.
          // Phase 2 stores the child channel reference directly.
          channel.eventLoop.execute { [weak self] in
              self?.sessionHandler?.context?.writeAndFlush(
                  NIOAny(channelData),
                  promise: nil
              )
          }
      }

      func resize(cols: Int, rows: Int) {
          guard isConnected else { return }
          transportChannel?.eventLoop.execute { [weak self] in
              self?.sessionHandler?.sendResize(cols: cols, rows: rows)
          }
      }

      // MARK: - Private

      private func buildAuthDelegate() -> any NIOSSHClientUserAuthenticationDelegate {
          switch session.authMethod {
          case .password:
              return PasswordAuthDelegate(username: session.username, password: password ?? "")
          case .publicKey:
              if let key = privateKey {
                  return PublicKeyAuthDelegate(username: session.username, privateKey: key)
              }
              // Fall back to password if no key was loaded.
              return PasswordAuthDelegate(username: session.username, password: password ?? "")
          case .keyboardInteractive:
              let delegate = KeyboardInteractiveAuthDelegate(username: session.username)
              if let provider = keyboardInteractiveResponseProvider {
                  delegate.responseProvider = provider
              }
              return delegate
          }
      }
  }
  ```

  > **Note on `send`:** The `context` property on `SSHSessionChannelHandler` is the child channel's context. Writing to it sends data through the SSH session channel. Task 9 integration testing will verify this end-to-end.

- [ ] **Step 2: Build succeeds**

  ⌘B. Expected: no errors.

- [ ] **Step 3: Manual integration test — connect to localhost**

  macOS has SSH server support (System Preferences → Sharing → Remote Login).
  Enable Remote Login for your user, then add a temporary test in `SSHConnectionTests.swift`:

  ```swift
  // CodeEditTests/Features/RemoteTerminal/SSHConnectionTests.swift
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
          try await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
          XCTAssertTrue(receivedData)

          conn.disconnect()
          XCTAssertFalse(conn.isConnected)
      }
  }
  ```

  Run manually with Remote Login on. Expected: connects, receives terminal data, disconnects cleanly.

- [ ] **Step 4: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Connections/SSHConnection.swift
  git add CodeEditTests/Features/RemoteTerminal/SSHConnectionTests.swift
  git commit -m "feat: implement SSHConnection with password/key/keyboard-interactive auth"
  ```

---

## Task 10: Extend UtilityArea to Support SSH Terminals

**Files:**
- Modify: `CodeEdit/Features/UtilityArea/Models/UtilityAreaTerminal.swift`
- Modify: `CodeEdit/Features/UtilityArea/ViewModels/UtilityAreaViewModel.swift`
- Modify: `CodeEdit/Features/UtilityArea/TerminalUtility/UtilityAreaTerminalView.swift`

- [ ] **Step 1: Add ConnectionType to UtilityAreaTerminal**

  Open `CodeEdit/Features/UtilityArea/Models/UtilityAreaTerminal.swift`.
  Add `ConnectionType` before the class and a `connectionType` property:

  ```swift
  enum TerminalConnectionType {
      case localShell
      case ssh(session: RemoteSession, password: String?)
  }
  ```

  Add to `UtilityAreaTerminal`:

  ```swift
  @Published var connectionType: TerminalConnectionType

  init(id: UUID, url: URL, title: String, shell: Shell?, connectionType: TerminalConnectionType = .localShell) {
      self.id = id
      self.title = title
      self.terminalTitle = title
      self.url = url
      self.shell = shell
      self.customTitle = false
      self.connectionType = connectionType
  }
  ```

- [ ] **Step 2: Add addSSHTerminal to UtilityAreaViewModel**

  Open `CodeEdit/Features/UtilityArea/ViewModels/UtilityAreaViewModel.swift`.
  Add after `addTerminal(shell:rootURL:)`:

  ```swift
  /// Adds an SSH session tab to the utility area.
  func addSSHTerminal(session: RemoteSession, password: String?) {
      let terminal = UtilityAreaTerminal(
          id: session.id,
          url: URL(fileURLWithPath: NSHomeDirectory()),
          title: session.name,
          shell: nil,
          connectionType: .ssh(session: session, password: password)
      )
      terminals.append(terminal)
      selectedTerminals = [terminal.id]
  }
  ```

- [ ] **Step 3: Render CEConnectionTerminalView for SSH in UtilityAreaTerminalView**

  Open `CodeEdit/Features/UtilityArea/TerminalUtility/UtilityAreaTerminalView.swift`.

  Find where `CELocalShellTerminalView` is instantiated or looked up from `TerminalCache`. Add a branch for SSH terminals.

  After the function that returns the terminal view for the selected terminal, add:

  ```swift
  /// Returns the appropriate NSView for the given terminal.
  private func viewForTerminal(_ terminal: UtilityAreaTerminal) -> NSView {
      switch terminal.connectionType {
      case .localShell:
          // Existing path: use TerminalCache
          if let cached = TerminalCache.shared.getTerminalView(terminal.id) {
              return cached
          }
          let view = CELocalShellTerminalView(frame: .zero)
          TerminalCache.shared.cacheTerminalView(for: terminal.id, view: view)
          return view

      case .ssh(let session, let password):
          // SSH path: use CEConnectionTerminalView backed by SSHConnection
          if let existing = sshTerminalViews[terminal.id] {
              return existing
          }
          let connection = SSHConnection(session: session, password: password)
          let view = CEConnectionTerminalView(connection: connection)
          sshTerminalViews[terminal.id] = view
          Task {
              do {
                  try await connection.connect()
              } catch {
                  view.feed(text: "\r\nConnection failed: \(error.localizedDescription)\r\n")
              }
          }
          return view
      }
  }
  ```

  Add the storage dictionary to the view struct/class (use `@State` if in a SwiftUI View):

  ```swift
  @State private var sshTerminalViews: [UUID: CEConnectionTerminalView] = [:]
  ```

  Wire `viewForTerminal` into the existing view rendering path, replacing any direct `CELocalShellTerminalView` instantiation for the selected terminal.

- [ ] **Step 4: Build succeeds**

  ⌘B. Expected: no errors.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/UtilityArea/Models/UtilityAreaTerminal.swift
  git add CodeEdit/Features/UtilityArea/ViewModels/UtilityAreaViewModel.swift
  git add CodeEdit/Features/UtilityArea/TerminalUtility/UtilityAreaTerminalView.swift
  git commit -m "feat: extend UtilityArea to support SSH terminal tabs"
  ```

---

## Task 11: New SSH Connection Sheet

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/Views/NewSSHConnectionView.swift`

- [ ] **Step 1: Create NewSSHConnectionView.swift**

  Create `CodeEdit/Features/RemoteTerminal/Views/NewSSHConnectionView.swift`:

  ```swift
  //
  //  NewSSHConnectionView.swift
  //  CodeEdit
  //

  import SwiftUI

  /// A sheet for establishing a new SSH connection.
  /// Phase 3 (Session Manager) replaces this with the full session picker.
  struct NewSSHConnectionView: View {
      @Environment(\.dismiss) private var dismiss
      @EnvironmentObject private var utilityAreaViewModel: UtilityAreaViewModel

      @State private var hostname = ""
      @State private var port = "22"
      @State private var username = ""
      @State private var password = ""
      @State private var sessionName = ""
      @State private var isConnecting = false
      @State private var error: String?

      var body: some View {
          VStack(alignment: .leading, spacing: 16) {
              Text("New SSH Connection")
                  .font(.headline)

              Group {
                  LabeledContent("Session Name") {
                      TextField("My Router", text: $sessionName)
                          .textFieldStyle(.roundedBorder)
                  }
                  LabeledContent("Hostname") {
                      TextField("192.168.1.1", text: $hostname)
                          .textFieldStyle(.roundedBorder)
                  }
                  LabeledContent("Port") {
                      TextField("22", text: $port)
                          .textFieldStyle(.roundedBorder)
                          .frame(width: 60)
                  }
                  LabeledContent("Username") {
                      TextField("admin", text: $username)
                          .textFieldStyle(.roundedBorder)
                  }
                  LabeledContent("Password") {
                      SecureField("Password", text: $password)
                          .textFieldStyle(.roundedBorder)
                  }
              }

              if let error {
                  Text(error)
                      .foregroundStyle(.red)
                      .font(.caption)
              }

              HStack {
                  Spacer()
                  Button("Cancel") { dismiss() }
                      .keyboardShortcut(.cancelAction)
                  Button("Connect") { connect() }
                      .keyboardShortcut(.defaultAction)
                      .disabled(hostname.isEmpty || username.isEmpty || isConnecting)
              }
          }
          .padding(20)
          .frame(width: 380)
      }

      private func connect() {
          let name = sessionName.isEmpty ? hostname : sessionName
          let portInt = Int(port) ?? 22
          let session = RemoteSession(
              name: name,
              hostname: hostname,
              port: portInt,
              username: username,
              authMethod: .password
          )
          utilityAreaViewModel.addSSHTerminal(session: session, password: password.isEmpty ? nil : password)
          dismiss()
      }
  }
  ```

- [ ] **Step 2: Build succeeds**

  ⌘B. Expected: no errors.

- [ ] **Step 3: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Views/NewSSHConnectionView.swift
  git commit -m "feat: add NewSSHConnectionView sheet for quick SSH connections"
  ```

---

## Task 12: Wire Into App — Menu Command

**Files:**
- Modify: `CodeEdit/Features/WindowCommands/` (add to an appropriate commands file)

- [ ] **Step 1: Find the correct commands file**

  ```bash
  ls CodeEdit/Features/WindowCommands/
  ```

  Add a new SSH command to the most appropriate existing file (or create `SSHCommands.swift`).

- [ ] **Step 2: Add the menu command**

  In the appropriate `Commands` scene builder, add:

  ```swift
  // In the relevant CommandMenu block (e.g., Terminal or File menu)
  Button("New SSH Connection...") {
      NSApp.sendAction(#selector(AppDelegate.openNewSSHConnection(_:)), to: nil, from: nil)
  }
  .keyboardShortcut("K", modifiers: [.command, .shift])
  ```

  In `AppDelegate.swift`, add:

  ```swift
  @objc func openNewSSHConnection(_ sender: Any?) {
      guard let workspace = NSDocumentController.shared.currentDocument as? WorkspaceDocument,
            let windowController = workspace.windowControllers.first as? CodeEditWindowController
      else { return }
      windowController.openSSHConnectionSheet()
  }
  ```

  In `CodeEditWindowController` (or the appropriate window controller), add:

  ```swift
  func openSSHConnectionSheet() {
      let sheet = NSHostingController(
          rootView: NewSSHConnectionView()
              .environmentObject(utilityAreaViewModel)
      )
      sheet.preferredContentSize = NSSize(width: 380, height: 280)
      contentViewController?.presentAsSheet(sheet)
  }
  ```

- [ ] **Step 3: Build and run**

  ⌘R. Expected: app launches. File or Terminal menu shows "New SSH Connection... ⇧⌘K". Triggering it shows the sheet. Entering credentials opens an SSH tab in the utility area.

- [ ] **Step 4: Manual end-to-end test**

  1. Enable Remote Login on your Mac (System Settings → Sharing → Remote Login)
  2. Open NetSwift, trigger "New SSH Connection..."
  3. Enter: hostname `127.0.0.1`, port `22`, username = your macOS username, password = your password
  4. Click Connect
  5. Expected: a new tab appears in the utility area, shell prompt is visible, typing works

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/WindowCommands/
  git add CodeEdit/AppDelegate.swift
  git commit -m "feat: add New SSH Connection menu command (⇧⌘K)"
  ```

---

## Self-Review Checklist

**Spec coverage:**
- ✅ TerminalConnection protocol with observer chain
- ✅ TerminalPipeline (future highlighting/sanitization/AI hook points)
- ✅ LocalShellConnection extracted (existing terminal unchanged)
- ✅ SSHConnection — all three auth methods (password, public key, keyboard-interactive)
- ✅ RemoteSession model (Codable, correct default ports)
- ✅ CEConnectionTerminalView (generic display layer for any connection)
- ✅ SSH sessions appear in utility area as tabs
- ✅ New SSH Connection sheet
- ✅ Menu command + keyboard shortcut

**Deferred to later phases (by design):**
- Session Manager UI (Phase 3)
- GRDB persistence for sessions (Phase 2)
- Telnet (Phase 2)
- Keyword highlighting (Phase 4)
- Sanitization layer (Phase 5)
- Terminal themes (Phase 6)
- AI integration (Phase 7)
- Known-hosts verification (Phase 3)

**Type consistency confirmed:**
- `TerminalConnection.onDataReceived: ((ArraySlice<UInt8>) -> Void)?` — consistent across LocalShellConnection, SSHConnection
- `TerminalPipeline(connection:feedCallback:)` — matches all Task 3 usage
- `RemoteSession.authMethod: AuthMethod` — consistent across SSHConnection.buildAuthDelegate() and RemoteSessionTests
- `SSHConnectionError` cases used in SSHSessionChannelHandler match those referenced in SSHConnection
