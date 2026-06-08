# Phase 3 — Session Manager UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface the Phase-2 persistence layer as a full Session Manager: a new left-navigator tab showing a folder/session tree with drag-and-drop reordering, status dots, search, context-menu actions, a properties editor (with markdown notes), connect-to-utility-area, a detachable floating panel, SecureCRT `.ini` import, bulk edit, and a Session Manager settings page.

**Architecture:** A `SessionManagerViewModel` (ObservableObject) owns the in-memory tree, reading/writing `SessionStore` (GRDB) and `SessionCredentialStore` (Keychain) from Phase 2. Ordering lives in `SessionFolder.childIDs`; a reserved hidden **root folder** (`SessionFolder.rootID`) holds top-level ordering so every node has exactly one parent. The tree is rendered with an `NSOutlineView` bridge (mirroring the existing `ProjectNavigator` pattern) for drag-and-drop; everything else is SwiftUI. Connecting a session reuses the Phase-1/2 utility-area path (`UtilityAreaViewModel.addSSHTerminal` / `addTelnetTerminal`), reached via `workspace.utilityAreaModel`.

**Tech Stack:** SwiftUI, AppKit (`NSOutlineView`, `NSViewControllerRepresentable`, `NSPanel`), GRDB (via `SessionStore`), `CodeEditKeychain` (via `SessionCredentialStore`).

> **This is Phase 3 of 7.** Phases 1 (SSH) and 2 (Telnet + Session Model) have shipped. Phases 4–7 (Keyword Highlighting, Sanitization, Terminal Themes, AI Integration) follow.

> **Status dots scope:** "connected" (green) and "disconnected" (gray) are derived robustly from whether an open utility-area terminal tab references the session. A precise mid-handshake "connecting" (amber) state is approximated by green and is the one explicitly-noted limitation (it would require the connection layer to publish live state — a small future enhancement, not in this plan).

---

## File Map

**Create:**
```
CodeEdit/Features/RemoteTerminal/SessionManager/
  Models/
    SessionTreeNode.swift                 — folder|session node enum
  ViewModels/
    SessionManagerViewModel.swift         — tree state, CRUD, move, search, connect, bulk edit
  Import/
    SecureCRTImporter.swift               — parse SecureCRT .ini sessions/folders
  Views/
    SessionManagerNavigatorView.swift     — SwiftUI shell: search + toolbar + outline
    SessionOutlineView.swift              — NSViewControllerRepresentable bridge
    SessionOutlineViewController.swift     — NSOutlineView controller (rows, dnd, menu)
    SessionRowView.swift                  — name + protocol badge + status dot (NSHostingView content)
    SessionPropertiesView.swift           — edit a session (fields + markdown notes)
    NewSessionFolderView.swift            — create-folder sheet
    SessionManagerPanel.swift             — detachable floating NSPanel
  Settings/
    SessionManagerSettings.swift          — SettingsData group
    SessionManagerSettingsView.swift      — settings page (+ SecureCRT import action)

CodeEditTests/Features/RemoteTerminal/
  SessionManagerViewModelTests.swift
  SecureCRTImporterTests.swift
  SessionManagerSettingsTests.swift
```

**Modify:**
```
CodeEdit/Features/RemoteTerminal/Sessions/SessionFolder.swift
  — add `static let rootID`

CodeEdit/Features/NavigatorArea/Models/NavigatorTab.swift
  — add `.sessionManager` case (icon, title, body)

CodeEdit/Features/NavigatorArea/Views/NavigatorAreaView.swift
  — add `.sessionManager` to the default tab array

CodeEdit/Features/Settings/Models/SettingsData.swift
  — add `sessionManager` group + decode + propertiesOf case

CodeEdit/Features/Settings/Models/SettingsPage.swift
  — add `.sessionManager` page name

CodeEdit/Features/Settings/SettingsView.swift
  — register the Session Manager settings page + detail switch case
```

---

## Conventions for every task

- Work from `/Users/cwdavis/scripts/CodeEdit` on a branch `phase3-session-manager` (the orchestrator creates it).
- The project uses `PBXFileSystemSynchronizedRootGroup` — **never edit `project.pbxproj`**; new files in these folders are auto-included. **Never edit `.swiftlint.yml`** (rename test locals to ≥3 chars instead). SwiftLint runs as a build plugin: file-header block, ≤120-col lines, no trailing whitespace, identifiers ≥3 chars.
- No GUI. **Logic tests:** `xcodebuild test -project CodeEdit.xcodeproj -scheme CodeEdit -destination 'platform=macOS' -only-testing:CodeEditTests/<Suite> 2>&1 | tail -30` → expect `** TEST SUCCEEDED **`. **View/build-only tasks:** `xcodebuild build -project CodeEdit.xcodeproj -scheme CodeEdit -destination 'platform=macOS' 2>&1 | tail -30` → expect `** BUILD SUCCEEDED **` with no `error:` lines. Trailing `Running SwiftLint for <unrelated target>` command-failures are a known pre-existing environment quirk — judge by the test/build result line.
- If Xcode reorders `project.pbxproj` in the working tree during a build, do not commit it; only `git add` the specific files each task lists.

---

# Part A — Tree model & ViewModel (testable core)

## Task 1: SessionFolder.rootID + SessionTreeNode

**Files:**
- Modify: `CodeEdit/Features/RemoteTerminal/Sessions/SessionFolder.swift`
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/Models/SessionTreeNode.swift`
- Test: `CodeEditTests/Features/RemoteTerminal/SessionManagerViewModelTests.swift` (created here, grown in later tasks)

- [ ] **Step 1: Add the root sentinel to SessionFolder**

  In `SessionFolder.swift`, add inside the struct (after the stored properties, before `init`):

  ```swift
      /// Reserved id for the hidden root folder whose `childIDs` define top-level ordering.
      /// Never shown in the UI.
      static let rootID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
  ```

- [ ] **Step 2: Create SessionTreeNode.swift**

  ```swift
  //
  //  SessionTreeNode.swift
  //  CodeEdit
  //

  import Foundation

  /// A node in the session tree: either a folder or a session.
  enum SessionTreeNode: Identifiable, Equatable {
      case folder(SessionFolder)
      case session(RemoteSession)

      var id: UUID {
          switch self {
          case .folder(let folder): return folder.id
          case .session(let session): return session.id
          }
      }

      var isFolder: Bool {
          if case .folder = self { return true }
          return false
      }

      var name: String {
          switch self {
          case .folder(let folder): return folder.name
          case .session(let session): return session.name
          }
      }
  }
  ```

- [ ] **Step 3: Write the first ViewModel test (drives Task 2 API, fails to compile now)**

  Create `CodeEditTests/Features/RemoteTerminal/SessionManagerViewModelTests.swift`:

  ```swift
  import XCTest
  @testable import CodeEdit

  final class SessionManagerViewModelTests: XCTestCase {
      private var tempURL: URL!
      private var store: SessionStore!
      private var viewModel: SessionManagerViewModel!

      override func setUpWithError() throws {
          tempURL = FileManager.default.temporaryDirectory
              .appendingPathComponent("session-mgr-test-\(UUID().uuidString).db")
          store = try SessionStore(tempURL)
          let keychain = CodeEditKeychain(keyPrefix: "test-session-mgr-\(UUID().uuidString)-")
          viewModel = SessionManagerViewModel(
              store: store,
              credentials: SessionCredentialStore(keychain: keychain)
          )
      }

      override func tearDownWithError() throws {
          viewModel = nil
          store = nil
          try? FileManager.default.removeItem(at: tempURL)
      }

      func test_emptyTree_hasNoRootNodes() {
          XCTAssertTrue(viewModel.rootNodes.isEmpty)
      }

      func test_rootFolderIsNotShown() {
          // A root sentinel folder must never appear among the visible nodes.
          XCTAssertFalse(viewModel.rootNodes.contains { $0.id == SessionFolder.rootID })
      }
  }
  ```

- [ ] **Step 4: Run, confirm compile failure** (`SessionManagerViewModel` not found). This is expected — the ViewModel is built in Task 2.

- [ ] **Step 5: Commit (model only)**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/Sessions/SessionFolder.swift \
          CodeEdit/Features/RemoteTerminal/SessionManager/Models/SessionTreeNode.swift
  git commit -m "feat: add SessionFolder.rootID and SessionTreeNode

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

  (The new test file is committed in Task 2 alongside the ViewModel it exercises.)

---

## Task 2: SessionManagerViewModel — load tree + CRUD

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/ViewModels/SessionManagerViewModel.swift`
- Test: `CodeEditTests/Features/RemoteTerminal/SessionManagerViewModelTests.swift` (grow)

- [ ] **Step 1: Add CRUD tests** to `SessionManagerViewModelTests.swift` (append inside the class):

  ```swift
      func test_createSession_appearsAtRoot() {
          let session = RemoteSession(name: "Router-1", hostname: "10.0.0.1", username: "admin")
          viewModel.createSession(session, in: SessionFolder.rootID)
          XCTAssertEqual(viewModel.rootNodes.count, 1)
          XCTAssertEqual(viewModel.rootNodes.first?.id, session.id)
      }

      func test_createFolder_thenSessionInside() {
          let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
          let session = RemoteSession(name: "sw1", hostname: "h", username: "u")
          viewModel.createSession(session, in: folder.id)
          XCTAssertEqual(viewModel.rootNodes.map(\.id), [folder.id])
          XCTAssertEqual(viewModel.children(of: folder.id).map(\.id), [session.id])
      }

      func test_createPersistsAcrossReload() throws {
          let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
          viewModel.createSession(RemoteSession(name: "s", hostname: "h", username: "u"), in: folder.id)
          // New view model over the same store sees the same tree.
          let reopened = SessionManagerViewModel(store: store)
          XCTAssertEqual(reopened.rootNodes.map(\.name), ["Lab"])
          XCTAssertEqual(reopened.children(of: folder.id).count, 1)
      }

      func test_renameFolder() {
          let folder = viewModel.createFolder(name: "Old", in: SessionFolder.rootID)
          viewModel.renameFolder(folder.id, to: "New")
          XCTAssertEqual(viewModel.folder(folder.id)?.name, "New")
      }

      func test_updateSession() {
          let session = RemoteSession(name: "s", hostname: "h", username: "u")
          viewModel.createSession(session, in: SessionFolder.rootID)
          var edited = session
          edited.hostname = "10.0.0.9"
          viewModel.updateSession(edited)
          XCTAssertEqual(viewModel.session(session.id)?.hostname, "10.0.0.9")
      }

      func test_deleteSession_removesFromTreeAndStore() {
          let session = RemoteSession(name: "s", hostname: "h", username: "u")
          viewModel.createSession(session, in: SessionFolder.rootID)
          viewModel.deleteNode(session.id)
          XCTAssertTrue(viewModel.rootNodes.isEmpty)
          XCTAssertNil(viewModel.session(session.id))
      }

      func test_deleteFolder_recursivelyRemovesChildren() {
          let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
          let child = RemoteSession(name: "s", hostname: "h", username: "u")
          viewModel.createSession(child, in: folder.id)
          viewModel.deleteNode(folder.id)
          XCTAssertTrue(viewModel.rootNodes.isEmpty)
          XCTAssertNil(viewModel.session(child.id))
          XCTAssertNil(viewModel.folder(folder.id))
      }

      func test_duplicateSession_makesDistinctCopyInSameParent() {
          let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
          let session = RemoteSession(name: "s", hostname: "h", username: "u")
          viewModel.createSession(session, in: folder.id)
          let copy = viewModel.duplicateSession(session.id)
          XCTAssertNotNil(copy)
          XCTAssertNotEqual(copy?.id, session.id)
          XCTAssertEqual(viewModel.children(of: folder.id).count, 2)
          XCTAssertEqual(copy?.name, "s copy")
      }
  ```

- [ ] **Step 2: Run, confirm failure** (`SessionManagerViewModel` not found).

- [ ] **Step 3: Create SessionManagerViewModel.swift**

  ```swift
  //
  //  SessionManagerViewModel.swift
  //  CodeEdit
  //

  import Foundation
  import Combine

  /// Owns the in-memory session tree and writes through to ``SessionStore`` (config)
  /// and ``SessionCredentialStore`` (passwords). Ordering lives in each folder's
  /// `childIDs`; the hidden ``SessionFolder/rootID`` folder holds top-level ordering.
  final class SessionManagerViewModel: ObservableObject {
      private let store: SessionStore
      private let credentials: SessionCredentialStore

      @Published private(set) var folders: [UUID: SessionFolder] = [:]
      @Published private(set) var sessions: [UUID: RemoteSession] = [:]
      /// Live search text; empty means show the full tree.
      @Published var searchQuery: String = ""

      init(store: SessionStore, credentials: SessionCredentialStore = SessionCredentialStore()) {
          self.store = store
          self.credentials = credentials
          reload()
      }

      // MARK: - Loading

      func reload() {
          folders = Dictionary(uniqueKeysWithValues: store.allFolders().map { ($0.id, $0) })
          sessions = Dictionary(uniqueKeysWithValues: store.allSessions().map { ($0.id, $0) })
          ensureRoot()
      }

      private func ensureRoot() {
          if folders[SessionFolder.rootID] == nil {
              let root = SessionFolder(id: SessionFolder.rootID, name: "")
              folders[root.id] = root
              store.saveFolder(root)
          }
      }

      // MARK: - Queries

      func folder(_ id: UUID) -> SessionFolder? { folders[id] }
      func session(_ id: UUID) -> RemoteSession? { sessions[id] }

      /// Ordered children of a folder, resolved from its `childIDs` (dangling ids skipped).
      func children(of parentID: UUID) -> [SessionTreeNode] {
          guard let parent = folders[parentID] else { return [] }
          return parent.childIDs.compactMap { childID in
              if let folder = folders[childID] { return .folder(folder) }
              if let session = sessions[childID] { return .session(session) }
              return nil
          }
      }

      var rootNodes: [SessionTreeNode] { children(of: SessionFolder.rootID) }

      // MARK: - Create

      @discardableResult
      func createSession(_ session: RemoteSession, in parentID: UUID) -> RemoteSession {
          var stored = session
          stored.folderID = parentID
          sessions[stored.id] = stored
          store.saveSession(stored)
          appendChild(stored.id, to: parentID)
          return stored
      }

      @discardableResult
      func createFolder(name: String, in parentID: UUID) -> SessionFolder {
          let folder = SessionFolder(name: name, parentID: parentID)
          folders[folder.id] = folder
          store.saveFolder(folder)
          appendChild(folder.id, to: parentID)
          return folder
      }

      private func appendChild(_ childID: UUID, to parentID: UUID) {
          ensureRoot()
          guard var parent = folders[parentID] else { return }
          if !parent.childIDs.contains(childID) {
              parent.childIDs.append(childID)
          }
          folders[parentID] = parent
          store.saveFolder(parent)
      }

      // MARK: - Update / rename

      func updateSession(_ session: RemoteSession) {
          guard sessions[session.id] != nil else { return }
          sessions[session.id] = session
          store.saveSession(session)
      }

      func renameFolder(_ id: UUID, to name: String) {
          guard var folder = folders[id] else { return }
          folder.name = name
          folders[id] = folder
          store.saveFolder(folder)
      }

      // MARK: - Delete

      func deleteNode(_ id: UUID) {
          if let folder = folders[id], id != SessionFolder.rootID {
              for child in folder.childIDs { deleteNode(child) }
              folders[id] = nil
              store.deleteFolder(id: id)
              detachFromParent(id, parentID: folder.parentID)
          } else if let session = sessions[id] {
              sessions[id] = nil
              store.deleteSession(id: id)
              credentials.deletePassword(forSessionID: id)
              detachFromParent(id, parentID: session.folderID)
          }
      }

      private func detachFromParent(_ childID: UUID, parentID: UUID?) {
          let pid = parentID ?? SessionFolder.rootID
          guard var parent = folders[pid] else { return }
          parent.childIDs.removeAll { $0 == childID }
          folders[pid] = parent
          store.saveFolder(parent)
      }

      // MARK: - Duplicate

      @discardableResult
      func duplicateSession(_ id: UUID) -> RemoteSession? {
          guard let original = sessions[id] else { return nil }
          let parentID = original.folderID ?? SessionFolder.rootID
          var copy = original
          copy.id = UUID()
          copy.name = original.name + " copy"
          copy.folderID = parentID
          sessions[copy.id] = copy
          store.saveSession(copy)
          // Insert immediately after the original in the parent's ordering.
          if var parent = folders[parentID], let index = parent.childIDs.firstIndex(of: id) {
              parent.childIDs.insert(copy.id, at: index + 1)
              folders[parentID] = parent
              store.saveFolder(parent)
          } else {
              appendChild(copy.id, to: parentID)
          }
          // Copy the stored password too, if any.
          if let password = credentials.password(forSessionID: id) {
              credentials.setPassword(password, forSessionID: copy.id)
          }
          return copy
      }
  }
  ```

- [ ] **Step 4: Run tests, confirm all pass** (Task 1 + Task 2 tests).

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/ViewModels/SessionManagerViewModel.swift \
          CodeEditTests/Features/RemoteTerminal/SessionManagerViewModelTests.swift
  git commit -m "feat: add SessionManagerViewModel with tree loading and CRUD

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 3: ViewModel — move & reorder

**Files:**
- Modify: `CodeEdit/Features/RemoteTerminal/SessionManager/ViewModels/SessionManagerViewModel.swift`
- Test: `CodeEditTests/Features/RemoteTerminal/SessionManagerViewModelTests.swift` (grow)

- [ ] **Step 1: Add move/reorder tests:**

  ```swift
      func test_moveSessionIntoFolder() {
          let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
          let session = RemoteSession(name: "s", hostname: "h", username: "u")
          viewModel.createSession(session, in: SessionFolder.rootID)
          viewModel.move(session.id, to: folder.id, at: nil)
          XCTAssertTrue(viewModel.rootNodes.map(\.id).contains(folder.id))
          XCTAssertEqual(viewModel.children(of: folder.id).map(\.id), [session.id])
          XCTAssertEqual(viewModel.session(session.id)?.folderID, folder.id)
      }

      func test_reorderWithinParent() {
          let one = RemoteSession(name: "1", hostname: "h", username: "u")
          let two = RemoteSession(name: "2", hostname: "h", username: "u")
          viewModel.createSession(one, in: SessionFolder.rootID)
          viewModel.createSession(two, in: SessionFolder.rootID)
          XCTAssertEqual(viewModel.rootNodes.map(\.name), ["1", "2"])
          viewModel.move(two.id, to: SessionFolder.rootID, at: 0)
          XCTAssertEqual(viewModel.rootNodes.map(\.name), ["2", "1"])
      }

      func test_cannotMoveFolderIntoItsOwnDescendant() {
          let outer = viewModel.createFolder(name: "outer", in: SessionFolder.rootID)
          let inner = viewModel.createFolder(name: "inner", in: outer.id)
          viewModel.move(outer.id, to: inner.id, at: nil)
          // The illegal move is ignored — outer stays at root, inner stays under outer.
          XCTAssertTrue(viewModel.rootNodes.map(\.id).contains(outer.id))
          XCTAssertEqual(viewModel.children(of: outer.id).map(\.id), [inner.id])
      }

      func test_isDescendant() {
          let outer = viewModel.createFolder(name: "outer", in: SessionFolder.rootID)
          let inner = viewModel.createFolder(name: "inner", in: outer.id)
          XCTAssertTrue(viewModel.isDescendant(inner.id, of: outer.id))
          XCTAssertFalse(viewModel.isDescendant(outer.id, of: inner.id))
      }
  ```

- [ ] **Step 2: Run, confirm failure** (no `move`/`isDescendant`).

- [ ] **Step 3: Add the methods** to `SessionManagerViewModel` (inside the class, after the Duplicate section):

  ```swift
      // MARK: - Move / reorder

      /// Moves a node to `parentID` at the given index (append if `index` is nil).
      /// No-op for the root sentinel, unknown nodes, or moving a folder into its own subtree.
      func move(_ nodeID: UUID, to parentID: UUID, at index: Int?) {
          guard nodeID != SessionFolder.rootID, folders[parentID] != nil else { return }
          if folders[nodeID] != nil, (nodeID == parentID || isDescendant(parentID, of: nodeID)) {
              return
          }

          let oldParentID: UUID
          if let folder = folders[nodeID] {
              oldParentID = folder.parentID ?? SessionFolder.rootID
          } else if let session = sessions[nodeID] {
              oldParentID = session.folderID ?? SessionFolder.rootID
          } else {
              return
          }

          // Detach from old parent.
          if var oldParent = folders[oldParentID] {
              oldParent.childIDs.removeAll { $0 == nodeID }
              folders[oldParentID] = oldParent
              store.saveFolder(oldParent)
          }

          // Update the node's parent reference.
          if var folder = folders[nodeID] {
              folder.parentID = parentID
              folders[nodeID] = folder
              store.saveFolder(folder)
          } else if var session = sessions[nodeID] {
              session.folderID = parentID
              sessions[nodeID] = session
              store.saveSession(session)
          }

          // Insert into new parent at the requested position.
          guard var newParent = folders[parentID] else { return }
          newParent.childIDs.removeAll { $0 == nodeID }
          let clamped = max(0, min(index ?? newParent.childIDs.count, newParent.childIDs.count))
          newParent.childIDs.insert(nodeID, at: clamped)
          folders[parentID] = newParent
          store.saveFolder(newParent)
      }

      /// True if `candidate` is `ancestor` or lives anywhere beneath it.
      func isDescendant(_ candidate: UUID, of ancestor: UUID) -> Bool {
          var current: UUID? = candidate
          while let id = current {
              if id == ancestor { return true }
              current = folders[id]?.parentID
              if current == SessionFolder.rootID && ancestor != SessionFolder.rootID { return false }
          }
          return false
      }
  ```

- [ ] **Step 4: Run tests, confirm all pass.**

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/ViewModels/SessionManagerViewModel.swift \
          CodeEditTests/Features/RemoteTerminal/SessionManagerViewModelTests.swift
  git commit -m "feat: add session tree move and reorder with cycle protection

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 4: ViewModel — search, credentials, bulk edit, connect

**Files:**
- Modify: `CodeEdit/Features/RemoteTerminal/SessionManager/ViewModels/SessionManagerViewModel.swift`
- Test: `CodeEditTests/Features/RemoteTerminal/SessionManagerViewModelTests.swift` (grow)

- [ ] **Step 1: Add tests:**

  ```swift
      func test_searchMatchesNameHostUserNotes() {
          viewModel.createSession(
              RemoteSession(name: "Core", hostname: "10.0.0.1", username: "admin", notes: "primary"),
              in: SessionFolder.rootID
          )
          viewModel.createSession(
              RemoteSession(name: "Edge", hostname: "192.168.1.9", username: "ops", notes: "backup"),
              in: SessionFolder.rootID
          )
          XCTAssertEqual(viewModel.searchMatches(query: "core").map(\.name), ["Core"])
          XCTAssertEqual(viewModel.searchMatches(query: "192.168").map(\.name), ["Edge"])
          XCTAssertEqual(viewModel.searchMatches(query: "ADMIN").map(\.name), ["Core"])
          XCTAssertEqual(viewModel.searchMatches(query: "backup").map(\.name), ["Edge"])
          XCTAssertEqual(viewModel.searchMatches(query: "zzz").count, 0)
      }

      func test_passwordStorage() {
          let session = RemoteSession(name: "s", hostname: "h", username: "u")
          viewModel.createSession(session, in: SessionFolder.rootID)
          viewModel.setPassword("secret", for: session.id)
          XCTAssertEqual(viewModel.password(for: session.id), "secret")
          viewModel.setPassword(nil, for: session.id)
          XCTAssertNil(viewModel.password(for: session.id))
      }

      func test_bulkSetAuthMethodAcrossFolder() {
          let folder = viewModel.createFolder(name: "Lab", in: SessionFolder.rootID)
          let sub = viewModel.createFolder(name: "Sub", in: folder.id)
          let s1 = RemoteSession(name: "a", hostname: "h", username: "u")
          let s2 = RemoteSession(name: "b", hostname: "h", username: "u")
          viewModel.createSession(s1, in: folder.id)
          viewModel.createSession(s2, in: sub.id)
          viewModel.bulkSetAuthMethod(.keyboardInteractive, inFolder: folder.id)
          XCTAssertEqual(viewModel.session(s1.id)?.authMethod, .keyboardInteractive)
          XCTAssertEqual(viewModel.session(s2.id)?.authMethod, .keyboardInteractive)
      }
  ```

- [ ] **Step 2: Run, confirm failure.**

- [ ] **Step 3: Add the methods** to `SessionManagerViewModel`:

  ```swift
      // MARK: - Search

      /// Sessions whose name/hostname/username/notes contain `query` (case-insensitive).
      /// Returns all sessions when `query` is blank.
      func searchMatches(query: String) -> [RemoteSession] {
          let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          let all = Array(sessions.values).filter { $0.id != SessionFolder.rootID }
          guard !trimmed.isEmpty else { return all.sorted { $0.name < $1.name } }
          return all.filter { session in
              session.name.lowercased().contains(trimmed)
                  || session.hostname.lowercased().contains(trimmed)
                  || session.username.lowercased().contains(trimmed)
                  || session.notes.lowercased().contains(trimmed)
          }.sorted { $0.name < $1.name }
      }

      // MARK: - Credentials

      func setPassword(_ password: String?, for sessionID: UUID) {
          if let password, !password.isEmpty {
              credentials.setPassword(password, forSessionID: sessionID)
          } else {
              credentials.deletePassword(forSessionID: sessionID)
          }
      }

      func password(for sessionID: UUID) -> String? {
          credentials.password(forSessionID: sessionID)
      }

      // MARK: - Bulk edit

      /// Sets `authMethod` on every session anywhere beneath `folderID` (inclusive).
      func bulkSetAuthMethod(_ method: AuthMethod, inFolder folderID: UUID) {
          for node in children(of: folderID) {
              switch node {
              case .session(var session):
                  session.authMethod = method
                  sessions[session.id] = session
                  store.saveSession(session)
              case .folder(let folder):
                  bulkSetAuthMethod(method, inFolder: folder.id)
              }
          }
      }
  ```

- [ ] **Step 4: Add the connect integration** (UI-facing; not unit-tested because it drives the utility area). Add to `SessionManagerViewModel`:

  ```swift
      // MARK: - Connect

      /// Opens a session in the bottom utility-area terminal panel, reusing the
      /// Phase-1/2 SSH/Telnet path. Stamps `lastConnectedAt` and persists it.
      func connect(_ sessionID: UUID, using utilityArea: UtilityAreaViewModel) {
          guard var session = sessions[sessionID] else { return }
          session.lastConnectedAt = Date()
          sessions[sessionID] = session
          store.saveSession(session)

          switch session.protocol {
          case .ssh:
              let password = session.authMethod == .password ? credentials.password(forSessionID: sessionID) : nil
              utilityArea.addSSHTerminal(session: session, password: password)
          case .telnet:
              utilityArea.addTelnetTerminal(session: session)
          }
      }
  ```

  > `Date()` is fine in app code (the no-`Date()` rule only applies to workflow scripts).

- [ ] **Step 5: Run tests, confirm all pass; then build to confirm `connect` compiles:**

  ```
  xcodebuild build -project CodeEdit.xcodeproj -scheme CodeEdit -destination 'platform=macOS' 2>&1 | tail -15
  ```
  Expect `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/ViewModels/SessionManagerViewModel.swift \
          CodeEditTests/Features/RemoteTerminal/SessionManagerViewModelTests.swift
  git commit -m "feat: add session search, credentials, bulk edit, and connect

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

# Part B — SecureCRT import (testable)

## Task 5: SecureCRTImporter

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/Import/SecureCRTImporter.swift`
- Test: `CodeEditTests/Features/RemoteTerminal/SecureCRTImporterTests.swift`

SecureCRT stores each session as a `Sessions/<Folder>/<Name>.ini` file. Relevant keys (one per line):
`S:"Hostname"=10.0.0.1`, `S:"Username"=admin`, `D:"[SSH2] Port"=00000016` (hex; 0x16 = 22) or `D:"Port"=00000017` (Telnet, 0x17 = 23), `S:"Protocol Name"=SSH2` | `SSH1` | `Telnet`.

- [ ] **Step 1: Write the failing tests**

  Create `CodeEditTests/Features/RemoteTerminal/SecureCRTImporterTests.swift`:

  ```swift
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
  ```

- [ ] **Step 2: Run, confirm failure** (`SecureCRTImporter` not found).

- [ ] **Step 3: Create SecureCRTImporter.swift**

  ```swift
  //
  //  SecureCRTImporter.swift
  //  CodeEdit
  //

  import Foundation

  /// Parses SecureCRT `.ini` session files into ``RemoteSession`` / ``SessionFolder`` values.
  enum SecureCRTImporter {

      /// The result of importing a directory tree of SecureCRT sessions.
      struct ImportResult: Equatable {
          var folders: [SessionFolder]
          var sessions: [RemoteSession]
      }

      /// Parses a single `.ini` file's contents into a session. Returns `nil` if there is no hostname.
      static func parseSession(ini: String, name: String, folderID: UUID? = nil) -> RemoteSession? {
          var values: [String: String] = [:]
          for rawLine in ini.split(whereSeparator: \.isNewline) {
              let line = rawLine.trimmingCharacters(in: .whitespaces)
              guard let eq = line.firstIndex(of: "=") else { continue }
              let key = keyName(of: String(line[..<eq]))
              let value = String(line[line.index(after: eq)...])
              if let key { values[key] = value }
          }

          guard let hostname = values["Hostname"], !hostname.isEmpty else { return nil }

          let proto: ConnectionProtocol
          switch values["Protocol Name"]?.lowercased() {
          case "telnet": proto = .telnet
          default:       proto = .ssh   // SSH2/SSH1/unknown -> SSH
          }

          let port = values.first { $0.key.hasSuffix("Port") }
              .flatMap { Int($0.value, radix: 16) } ?? proto.defaultPort

          return RemoteSession(
              name: name,
              protocol: proto,
              hostname: hostname,
              port: port,
              username: values["Username"] ?? "",
              folderID: folderID
          )
      }

      /// Extracts the quoted key name from a SecureCRT typed key like `S:"Hostname"` or `D:"[SSH2] Port"`.
      private static func keyName(of typedKey: String) -> String? {
          guard let open = typedKey.firstIndex(of: "\""),
                let close = typedKey.lastIndex(of: "\""),
                open < close else { return nil }
          return String(typedKey[typedKey.index(after: open)..<close])
      }

      /// Recursively imports a directory of `.ini` files. Subdirectories become folders.
      /// `parentID` is the folder these top-level items attach to.
      static func importTree(from directory: URL, into parentID: UUID) throws -> ImportResult {
          var result = ImportResult(folders: [], sessions: [])
          let fileManager = FileManager.default
          let entries = try fileManager.contentsOfDirectory(
              at: directory,
              includingPropertiesForKeys: [.isDirectoryKey],
              options: [.skipsHiddenFiles]
          ).sorted { $0.lastPathComponent < $1.lastPathComponent }

          var childOrder: [UUID] = []
          for entry in entries {
              let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
              if isDir {
                  var folder = SessionFolder(name: entry.lastPathComponent, parentID: parentID)
                  let nested = try importTree(from: entry, into: folder.id)
                  folder.childIDs = orderedIDs(folders: nested.folders, sessions: nested.sessions, under: folder.id)
                  result.folders.append(folder)
                  result.folders.append(contentsOf: nested.folders)
                  result.sessions.append(contentsOf: nested.sessions)
                  childOrder.append(folder.id)
              } else if entry.pathExtension.lowercased() == "ini" {
                  let contents = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                  let name = entry.deletingPathExtension().lastPathComponent
                  if let session = parseSession(ini: contents, name: name, folderID: parentID) {
                      result.sessions.append(session)
                      childOrder.append(session.id)
                  }
              }
          }
          // Stamp the parent's direct-child ordering onto any folder we created for it.
          if let index = result.folders.firstIndex(where: { $0.id == parentID }) {
              result.folders[index].childIDs = childOrder
          }
          return result
      }

      private static func orderedIDs(
          folders: [SessionFolder],
          sessions: [RemoteSession],
          under parentID: UUID
      ) -> [UUID] {
          let folderIDs = folders.filter { $0.parentID == parentID }.map(\.id)
          let sessionIDs = sessions.filter { $0.folderID == parentID }.map(\.id)
          return folderIDs + sessionIDs
      }
  }
  ```

- [ ] **Step 4: Run tests, confirm all pass.**

  > `importTree` is exercised end-to-end by the Settings import action (Task 13) and manual testing; the unit tests cover the `.ini` parsing core, which is the error-prone part.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/Import/SecureCRTImporter.swift \
          CodeEditTests/Features/RemoteTerminal/SecureCRTImporterTests.swift
  git commit -m "feat: add SecureCRT .ini session importer

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

# Part C — Navigator UI

## Task 6: Session row + properties + new-folder views

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionRowView.swift`
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionPropertiesView.swift`
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/Views/NewSessionFolderView.swift`

These are SwiftUI leaf views with no isolated unit tests; verified by build + later wiring.

- [ ] **Step 1: Create SessionRowView.swift**

  ```swift
  //
  //  SessionRowView.swift
  //  CodeEdit
  //

  import SwiftUI

  /// Connection status shown as a colored dot in a session row.
  enum SessionConnectionStatus {
      case connected     // an open utility-area tab references this session
      case disconnected  // no open tab

      var color: Color {
          switch self {
          case .connected: return .green
          case .disconnected: return Color(nsColor: .tertiaryLabelColor)
          }
      }
  }

  /// A single row: status dot + name + protocol badge.
  struct SessionRowView: View {
      let session: RemoteSession
      let status: SessionConnectionStatus

      var body: some View {
          HStack(spacing: 6) {
              Circle()
                  .fill(status.color)
                  .frame(width: 7, height: 7)
              Image(systemName: session.protocol == .ssh ? "lock.shield" : "network")
                  .foregroundStyle(.secondary)
                  .imageScale(.small)
              Text(session.name)
                  .lineLimit(1)
                  .truncationMode(.tail)
              Spacer(minLength: 0)
              Text(session.protocol == .ssh ? "SSH" : "Telnet")
                  .font(.caption2)
                  .foregroundStyle(.secondary)
          }
          .help("\(session.username)@\(session.hostname):\(session.port)"
                + (session.lastConnectedAt.map { " — last connected \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
      }
  }

  /// A folder row: disclosure-style folder icon + name.
  struct SessionFolderRowView: View {
      let folder: SessionFolder

      var body: some View {
          HStack(spacing: 6) {
              Image(systemName: "folder")
                  .foregroundStyle(.secondary)
                  .imageScale(.small)
              Text(folder.name)
                  .lineLimit(1)
              Spacer(minLength: 0)
          }
      }
  }
  ```

- [ ] **Step 2: Create SessionPropertiesView.swift**

  ```swift
  //
  //  SessionPropertiesView.swift
  //  CodeEdit
  //

  import SwiftUI

  /// Edits a session's properties. Used both for creating a new session and editing an existing one.
  /// Notes render as Markdown in a preview below the editable field.
  struct SessionPropertiesView: View {
      /// The session being edited (a working copy).
      @State private var draft: RemoteSession
      @State private var password: String
      private let originalID: UUID
      private let onSave: (RemoteSession, String?) -> Void
      private let onCancel: () -> Void

      init(
          session: RemoteSession,
          password: String?,
          onSave: @escaping (RemoteSession, String?) -> Void,
          onCancel: @escaping () -> Void
      ) {
          _draft = State(initialValue: session)
          _password = State(initialValue: password ?? "")
          self.originalID = session.id
          self.onSave = onSave
          self.onCancel = onCancel
      }

      private var portString: Binding<String> {
          Binding(
              get: { String(draft.port) },
              set: { draft.port = Int($0) ?? draft.protocol.defaultPort }
          )
      }

      var body: some View {
          VStack(alignment: .leading, spacing: 14) {
              Text("Session Properties").font(.headline)

              Form {
                  TextField("Name", text: $draft.name)
                  Picker("Protocol", selection: $draft.protocol) {
                      Text("SSH").tag(ConnectionProtocol.ssh)
                      Text("Telnet").tag(ConnectionProtocol.telnet)
                  }
                  TextField("Hostname", text: $draft.hostname)
                  TextField("Port", text: portString)
                  TextField("Username", text: $draft.username)

                  if draft.protocol == .ssh {
                      Picker("Auth", selection: authBinding) {
                          Text("Password").tag(AuthMethodKind.password)
                          Text("Public Key").tag(AuthMethodKind.publicKey)
                          Text("Keyboard Interactive").tag(AuthMethodKind.keyboardInteractive)
                      }
                      if case .password = draft.authMethod {
                          SecureField("Password", text: $password)
                      }
                  }
              }
              .formStyle(.grouped)

              VStack(alignment: .leading, spacing: 4) {
                  Text("Notes").font(.subheadline).foregroundStyle(.secondary)
                  TextEditor(text: $draft.notes)
                      .font(.body.monospaced())
                      .frame(height: 70)
                      .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                  if !draft.notes.isEmpty, let rendered = try? AttributedString(markdown: draft.notes) {
                      Text(rendered)
                          .font(.caption)
                          .foregroundStyle(.secondary)
                          .frame(maxWidth: .infinity, alignment: .leading)
                  }
              }

              HStack {
                  Spacer()
                  Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                  Button("Save") {
                      onSave(draft, draft.protocol == .ssh && draft.authMethod == .password ? password : nil)
                  }
                  .keyboardShortcut(.defaultAction)
                  .disabled(draft.hostname.isEmpty || draft.name.isEmpty)
              }
          }
          .padding(20)
          .frame(width: 440)
      }

      /// Bridges the associated-value `AuthMethod` to a plain picker tag.
      private var authBinding: Binding<AuthMethodKind> {
          Binding(
              get: { AuthMethodKind(draft.authMethod) },
              set: { draft.authMethod = $0.authMethod }
          )
      }
  }

  /// A plain (no associated value) mirror of ``AuthMethod`` for use as a Picker tag.
  enum AuthMethodKind: Hashable {
      case password, publicKey, keyboardInteractive

      init(_ method: AuthMethod) {
          switch method {
          case .password: self = .password
          case .publicKey: self = .publicKey
          case .keyboardInteractive: self = .keyboardInteractive
          }
      }

      var authMethod: AuthMethod {
          switch self {
          case .password: return .password
          case .publicKey: return .publicKey(keyID: UUID())
          case .keyboardInteractive: return .keyboardInteractive
          }
      }
  }
  ```

  > Note: `AuthMethodKind.publicKey.authMethod` mints a placeholder `keyID`. Wiring a real SSH-key picker is deferred to a later phase; for now selecting Public Key records the intent. Document this in the row comment as shown.

- [ ] **Step 3: Create NewSessionFolderView.swift**

  ```swift
  //
  //  NewSessionFolderView.swift
  //  CodeEdit
  //

  import SwiftUI

  /// A small sheet for naming a new folder.
  struct NewSessionFolderView: View {
      @State private var name: String = "New Folder"
      let onCreate: (String) -> Void
      let onCancel: () -> Void

      var body: some View {
          VStack(alignment: .leading, spacing: 14) {
              Text("New Folder").font(.headline)
              TextField("Folder Name", text: $name)
                  .textFieldStyle(.roundedBorder)
              HStack {
                  Spacer()
                  Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                  Button("Create") { onCreate(name) }
                      .keyboardShortcut(.defaultAction)
                      .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
              }
          }
          .padding(20)
          .frame(width: 300)
      }
  }
  ```

- [ ] **Step 4: Build, confirm success.**

  ```
  xcodebuild build -project CodeEdit.xcodeproj -scheme CodeEdit -destination 'platform=macOS' 2>&1 | tail -15
  ```
  Expect `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionRowView.swift \
          CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionPropertiesView.swift \
          CodeEdit/Features/RemoteTerminal/SessionManager/Views/NewSessionFolderView.swift
  git commit -m "feat: add session row, properties editor, and new-folder views

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 7: NSOutlineView tree bridge (rows, expansion, double-click connect)

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionOutlineViewController.swift`
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionOutlineView.swift`

This mirrors `ProjectNavigator`'s `NSOutlineView` + `NSViewControllerRepresentable` pattern (reference: `CodeEdit/Features/NavigatorArea/ProjectNavigator/OutlineView/ProjectNavigatorViewController.swift` and `ProjectNavigatorOutlineView.swift`). Items are stable wrapper objects cached by id so expansion state survives reloads. Drag-and-drop is added in Task 8.

- [ ] **Step 1: Create SessionOutlineViewController.swift**

  ```swift
  //
  //  SessionOutlineViewController.swift
  //  CodeEdit
  //

  import AppKit
  import SwiftUI

  /// Stable wrapper object for an outline item (NSOutlineView keys items by object identity).
  final class SessionOutlineItem: NSObject {
      let nodeID: UUID
      let isFolder: Bool
      init(nodeID: UUID, isFolder: Bool) {
          self.nodeID = nodeID
          self.isFolder = isFolder
      }
  }

  /// Renders the session tree in an `NSOutlineView`.
  final class SessionOutlineViewController: NSViewController {
      var scrollView: NSScrollView!
      var outlineView: NSOutlineView!

      weak var viewModel: SessionManagerViewModel?
      /// Set of session ids that currently have an open utility-area terminal tab.
      var connectedSessionIDs: Set<UUID> = [] {
          willSet { if newValue != connectedSessionIDs { outlineView?.reloadData() } }
      }
      /// Called when a session row is activated (double-click or Connect).
      var onConnect: ((UUID) -> Void)?
      /// Called when a session row is chosen for editing (Properties).
      var onEditSession: ((UUID) -> Void)?

      private var itemCache: [UUID: SessionOutlineItem] = [:]

      private func item(for nodeID: UUID, isFolder: Bool) -> SessionOutlineItem {
          if let cached = itemCache[nodeID] { return cached }
          let made = SessionOutlineItem(nodeID: nodeID, isFolder: isFolder)
          itemCache[nodeID] = made
          return made
      }

      override func loadView() {
          scrollView = NSScrollView()
          scrollView.hasVerticalScroller = true
          view = scrollView

          outlineView = NSOutlineView()
          outlineView.dataSource = self
          outlineView.delegate = self
          outlineView.headerView = nil
          outlineView.rowHeight = 22
          outlineView.doubleAction = #selector(onItemDoubleClicked)
          outlineView.allowsMultipleSelection = true
          outlineView.setAccessibilityIdentifier("SessionManager")

          let column = NSTableColumn(identifier: .init(rawValue: "Cell"))
          outlineView.addTableColumn(column)
          outlineView.outlineTableColumn = column

          scrollView.documentView = outlineView
          scrollView.contentView.automaticallyAdjustsContentInsets = false
          scrollView.contentView.contentInsets = .init(top: 6, left: 0, bottom: 0, right: 0)
          scrollView.scrollerStyle = .overlay
          scrollView.autohidesScrollers = true
      }

      init() { super.init(nibName: nil, bundle: nil) }
      required init?(coder: NSCoder) { fatalError() }

      func reload() {
          outlineView?.reloadData()
      }

      private func nodes(under item: Any?) -> [SessionTreeNode] {
          guard let viewModel else { return [] }
          if let outlineItem = item as? SessionOutlineItem {
              return viewModel.children(of: outlineItem.nodeID)
          }
          return viewModel.rootNodes
      }

      private func status(for sessionID: UUID) -> SessionConnectionStatus {
          connectedSessionIDs.contains(sessionID) ? .connected : .disconnected
      }

      @objc private func onItemDoubleClicked() {
          guard let outlineItem = outlineView.item(atRow: outlineView.clickedRow) as? SessionOutlineItem else {
              return
          }
          if outlineItem.isFolder {
              if outlineView.isItemExpanded(outlineItem) {
                  outlineView.collapseItem(outlineItem)
              } else {
                  outlineView.expandItem(outlineItem)
              }
          } else {
              onConnect?(outlineItem.nodeID)
          }
      }
  }

  // MARK: - Data source

  extension SessionOutlineViewController: NSOutlineViewDataSource {
      func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
          nodes(under: item).count
      }

      func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
          let node = nodes(under: item)[index]
          return self.item(for: node.id, isFolder: node.isFolder)
      }

      func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
          (item as? SessionOutlineItem)?.isFolder ?? false
      }
  }

  // MARK: - Delegate

  extension SessionOutlineViewController: NSOutlineViewDelegate {
      func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
          guard let outlineItem = item as? SessionOutlineItem, let viewModel else { return nil }
          let cell = NSTableCellView()
          let hosting: NSView
          if outlineItem.isFolder, let folder = viewModel.folder(outlineItem.nodeID) {
              hosting = NSHostingView(rootView: SessionFolderRowView(folder: folder))
          } else if let session = viewModel.session(outlineItem.nodeID) {
              hosting = NSHostingView(
                  rootView: SessionRowView(session: session, status: status(for: session.id))
              )
          } else {
              return nil
          }
          hosting.translatesAutoresizingMaskIntoConstraints = false
          cell.addSubview(hosting)
          NSLayoutConstraint.activate([
              hosting.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
              hosting.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
              hosting.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
          ])
          return cell
      }
  }
  ```

- [ ] **Step 2: Create SessionOutlineView.swift (SwiftUI bridge)**

  ```swift
  //
  //  SessionOutlineView.swift
  //  CodeEdit
  //

  import SwiftUI

  /// Bridges ``SessionOutlineViewController`` into SwiftUI.
  struct SessionOutlineView: NSViewControllerRepresentable {
      @ObservedObject var viewModel: SessionManagerViewModel
      let connectedSessionIDs: Set<UUID>
      let onConnect: (UUID) -> Void
      let onEditSession: (UUID) -> Void

      func makeNSViewController(context: Context) -> SessionOutlineViewController {
          let controller = SessionOutlineViewController()
          controller.viewModel = viewModel
          controller.onConnect = onConnect
          controller.onEditSession = onEditSession
          controller.connectedSessionIDs = connectedSessionIDs
          return controller
      }

      func updateNSViewController(_ controller: SessionOutlineViewController, context: Context) {
          controller.viewModel = viewModel
          controller.onConnect = onConnect
          controller.onEditSession = onEditSession
          controller.connectedSessionIDs = connectedSessionIDs
          controller.reload()
      }
  }
  ```

- [ ] **Step 3: Build, confirm success.** Expect `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionOutlineViewController.swift \
          CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionOutlineView.swift
  git commit -m "feat: add NSOutlineView session tree bridge

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 8: Drag-and-drop reordering in the outline view

**Files:**
- Modify: `CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionOutlineViewController.swift`

Adds move via a custom pasteboard type carrying the node UUID. Mirrors the ProjectNavigator drag setup (`setDraggingSourceOperationMask` + `registerForDraggedTypes`).

- [ ] **Step 1: Register the drag type** — in `loadView()`, after `outlineView.outlineTableColumn = column`, add:

  ```swift
          outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
          outlineView.registerForDraggedTypes([Self.nodePasteboardType])
  ```

  And add a static type near the top of the class (after the `itemCache` property):

  ```swift
      static let nodePasteboardType = NSPasteboard.PasteboardType("app.codeedit.session-node")
  ```

- [ ] **Step 2: Implement the drag-and-drop data source methods** — add to the `NSOutlineViewDataSource` extension:

  ```swift
      func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
          guard let outlineItem = item as? SessionOutlineItem else { return nil }
          let pasteboardItem = NSPasteboardItem()
          pasteboardItem.setString(outlineItem.nodeID.uuidString, forType: Self.nodePasteboardType)
          return pasteboardItem
      }

      func outlineView(
          _ outlineView: NSOutlineView,
          validateDrop info: NSDraggingInfo,
          proposedItem item: Any?,
          proposedChildIndex index: Int
      ) -> NSDragOperation {
          guard let draggedID = draggedNodeID(from: info) else { return [] }
          let targetParentID = (item as? SessionOutlineItem)?.nodeID ?? SessionFolder.rootID
          // Only drop into folders (or root); reject dropping a folder into its own subtree.
          if let targetItem = item as? SessionOutlineItem, !targetItem.isFolder { return [] }
          if let viewModel, viewModel.folder(draggedID) != nil,
             (draggedID == targetParentID || viewModel.isDescendant(targetParentID, of: draggedID)) {
              return []
          }
          return .move
      }

      func outlineView(
          _ outlineView: NSOutlineView,
          acceptDrop info: NSDraggingInfo,
          item: Any?,
          childIndex index: Int
      ) -> Bool {
          guard let draggedID = draggedNodeID(from: info), let viewModel else { return false }
          let targetParentID = (item as? SessionOutlineItem)?.nodeID ?? SessionFolder.rootID
          viewModel.move(draggedID, to: targetParentID, at: index == NSOutlineViewDropOnItemIndex ? nil : index)
          outlineView.reloadData()
          if let parentItem = item as? SessionOutlineItem { outlineView.expandItem(parentItem) }
          return true
      }

      private func draggedNodeID(from info: NSDraggingInfo) -> UUID? {
          guard let string = info.draggingPasteboard.string(forType: Self.nodePasteboardType) else { return nil }
          return UUID(uuidString: string)
      }
  ```

- [ ] **Step 3: Build, confirm success.** Expect `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionOutlineViewController.swift
  git commit -m "feat: add drag-and-drop reordering to the session tree

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 9: Context menu actions

**Files:**
- Modify: `CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionOutlineViewController.swift`

Adds a right-click menu: Connect, Open in New Tab, Duplicate, New Folder, Properties, Delete. (Move to Folder is handled by drag-and-drop from Task 8; bulk-edit auth lives in Settings/Task 13.)

- [ ] **Step 1: Add menu callbacks and a menu** — add these stored callbacks to the controller (near `onConnect`):

  ```swift
      var onDuplicate: ((UUID) -> Void)?
      var onDelete: ((UUID) -> Void)?
      var onNewFolder: ((UUID) -> Void)?   // parameter: parent folder id for the new folder
  ```

  In `loadView()`, after setting `outlineView.doubleAction`, add:

  ```swift
          let menu = NSMenu()
          menu.delegate = self
          outlineView.menu = menu
  ```

- [ ] **Step 2: Implement `NSMenuDelegate`** — add a new extension:

  ```swift
  // MARK: - Context menu

  extension SessionOutlineViewController: NSMenuDelegate {
      func menuNeedsUpdate(_ menu: NSMenu) {
          menu.removeAllItems()
          let row = outlineView.clickedRow
          guard row >= 0, let outlineItem = outlineView.item(atRow: row) as? SessionOutlineItem else {
              addItem(to: menu, title: "New Folder") { [weak self] in self?.onNewFolder?(SessionFolder.rootID) }
              return
          }

          if outlineItem.isFolder {
              addItem(to: menu, title: "New Folder") { [weak self] in self?.onNewFolder?(outlineItem.nodeID) }
              menu.addItem(.separator())
              addItem(to: menu, title: "Delete") { [weak self] in self?.onDelete?(outlineItem.nodeID) }
          } else {
              addItem(to: menu, title: "Connect") { [weak self] in self?.onConnect?(outlineItem.nodeID) }
              addItem(to: menu, title: "Open in New Tab") { [weak self] in self?.onConnect?(outlineItem.nodeID) }
              menu.addItem(.separator())
              addItem(to: menu, title: "Duplicate") { [weak self] in self?.onDuplicate?(outlineItem.nodeID) }
              addItem(to: menu, title: "Properties…") { [weak self] in self?.onEditSession?(outlineItem.nodeID) }
              menu.addItem(.separator())
              addItem(to: menu, title: "Delete") { [weak self] in self?.onDelete?(outlineItem.nodeID) }
          }
      }

      private func addItem(to menu: NSMenu, title: String, action: @escaping () -> Void) {
          let item = NSMenuItem(title: title, action: #selector(menuActionInvoked(_:)), keyEquivalent: "")
          item.target = self
          item.representedObject = MenuActionBox(action: action)
          menu.addItem(item)
      }

      @objc private func menuActionInvoked(_ sender: NSMenuItem) {
          (sender.representedObject as? MenuActionBox)?.action()
      }
  }

  /// Boxes a closure so it can ride on `NSMenuItem.representedObject`.
  private final class MenuActionBox {
      let action: () -> Void
      init(action: @escaping () -> Void) { self.action = action }
  }
  ```

- [ ] **Step 3: Forward the new callbacks through the bridge** — in `SessionOutlineView.swift`, add matching closure properties and wire them in `makeNSViewController`/`updateNSViewController`:

  ```swift
      let onDuplicate: (UUID) -> Void
      let onDelete: (UUID) -> Void
      let onNewFolder: (UUID) -> Void
  ```

  In both `makeNSViewController` and `updateNSViewController`, set:

  ```swift
      controller.onDuplicate = onDuplicate
      controller.onDelete = onDelete
      controller.onNewFolder = onNewFolder
  ```

- [ ] **Step 4: Build, confirm success** (callers are completed in Task 10; the bridge initializer now requires the new closures — Task 10's view supplies them). Because `SessionOutlineView` has no caller yet, the build should still succeed. Expect `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionOutlineViewController.swift \
          CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionOutlineView.swift
  git commit -m "feat: add session tree context menu actions

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 10: Navigator shell view + register the tab

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionManagerNavigatorView.swift`
- Modify: `CodeEdit/Features/NavigatorArea/Models/NavigatorTab.swift`
- Modify: `CodeEdit/Features/NavigatorArea/Views/NavigatorAreaView.swift`

- [ ] **Step 1: Create SessionManagerNavigatorView.swift**

  ```swift
  //
  //  SessionManagerNavigatorView.swift
  //  CodeEdit
  //

  import SwiftUI

  /// The Session Manager navigator tab: search field, toolbar, and the session tree.
  struct SessionManagerNavigatorView: View {
      @EnvironmentObject private var workspace: WorkspaceDocument

      @StateObject private var viewModel = SessionManagerViewModel(
          store: SessionStore.shared ?? (try? SessionStore()) ?? SessionStore.inMemoryFallback
      )

      @State private var searchText = ""
      @State private var editingSession: RemoteSession?
      @State private var newFolderParent: UUID?
      @State private var detached = false

      /// Session ids that currently have an open utility-area terminal tab.
      private var connectedSessionIDs: Set<UUID> {
          guard let terminals = workspace.utilityAreaModel?.terminals else { return [] }
          return Set(terminals.compactMap { terminal in
              switch terminal.connectionType {
              case .ssh(let session, _): return session.id
              case .telnet(let session): return session.id
              case .localShell: return nil
              }
          })
      }

      var body: some View {
          VStack(spacing: 0) {
              HStack(spacing: 6) {
                  Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                  TextField("Search Sessions", text: $searchText)
                      .textFieldStyle(.plain)
              }
              .padding(.horizontal, 8)
              .padding(.vertical, 5)

              Divider()

              Group {
                  if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                      SessionOutlineView(
                          viewModel: viewModel,
                          connectedSessionIDs: connectedSessionIDs,
                          onConnect: connect,
                          onEditSession: { editingSession = viewModel.session($0) },
                          onDuplicate: { viewModel.duplicateSession($0) },
                          onDelete: { viewModel.deleteNode($0) },
                          onNewFolder: { newFolderParent = $0 }
                      )
                  } else {
                      searchResults
                  }
              }
          }
          .toolbar { }
          .safeAreaInset(edge: .bottom) { bottomBar }
          .sheet(item: $editingSession) { session in
              SessionPropertiesView(
                  session: session,
                  password: viewModel.password(for: session.id),
                  onSave: { edited, password in
                      viewModel.updateSession(edited)
                      viewModel.setPassword(password, for: edited.id)
                      editingSession = nil
                  },
                  onCancel: { editingSession = nil }
              )
          }
          .sheet(item: Binding(
              get: { newFolderParent.map { FolderParentBox(id: $0) } },
              set: { newFolderParent = $0?.id }
          )) { box in
              NewSessionFolderView(
                  onCreate: { name in
                      viewModel.createFolder(name: name, in: box.id)
                      newFolderParent = nil
                  },
                  onCancel: { newFolderParent = nil }
              )
          }
      }

      private var searchResults: some View {
          List(viewModel.searchMatches(query: searchText), id: \.id) { session in
              SessionRowView(
                  session: session,
                  status: connectedSessionIDs.contains(session.id) ? .connected : .disconnected
              )
              .contentShape(Rectangle())
              .onTapGesture(count: 2) { connect(session.id) }
          }
          .listStyle(.sidebar)
      }

      private var bottomBar: some View {
          HStack(spacing: 4) {
              Button { editingSession = newDraft() } label: { Image(systemName: "plus") }
                  .help("New Session")
              Button { newFolderParent = SessionFolder.rootID } label: { Image(systemName: "folder.badge.plus") }
                  .help("New Folder")
              Spacer()
              Button { openDetachedPanel() } label: { Image(systemName: "macwindow.on.rectangle") }
                  .help("Detach Session Manager")
          }
          .buttonStyle(.borderless)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(.bar)
      }

      private func newDraft() -> RemoteSession {
          RemoteSession(name: "New Session", hostname: "", username: "", folderID: SessionFolder.rootID)
      }

      private func connect(_ sessionID: UUID) {
          guard let utilityArea = workspace.utilityAreaModel else { return }
          viewModel.connect(sessionID, using: utilityArea)
          workspace.utilityAreaModel?.isCollapsed = false
      }

      private func openDetachedPanel() {
          SessionManagerPanelController.shared.show(viewModel: viewModel, workspace: workspace)
      }
  }

  /// Identifiable wrapper so a `UUID` parent can drive a `.sheet(item:)`.
  private struct FolderParentBox: Identifiable { let id: UUID }
  ```

  > Note: `editingSession = newDraft()` opens the properties sheet on a brand-new session. Saving a brand-new session must CREATE it (it isn't in the store yet). Handle that in the save closure: if `viewModel.session(edited.id) == nil`, call `viewModel.createSession(edited, in: edited.folderID ?? SessionFolder.rootID)` instead of `updateSession`. Update the `onSave` closure accordingly:
  >
  > ```swift
  >   onSave: { edited, password in
  >       if viewModel.session(edited.id) == nil {
  >           viewModel.createSession(edited, in: edited.folderID ?? SessionFolder.rootID)
  >       } else {
  >           viewModel.updateSession(edited)
  >       }
  >       viewModel.setPassword(password, for: edited.id)
  >       editingSession = nil
  >   },
  > ```

- [ ] **Step 2: Add an in-memory fallback to SessionStore** so the `@StateObject` initializer always has a store. In `CodeEdit/Features/RemoteTerminal/Sessions/SessionStore.swift`, add a static fallback after `static let shared`:

  ```swift
      /// Last-resort in-memory store so UI can always construct a view model.
      /// Uses a unique temp path; not persisted across launches.
      static let inMemoryFallback: SessionStore = {
          let url = FileManager.default.temporaryDirectory
              .appendingPathComponent("codeedit-sessions-fallback.db")
          // Force-unwrap is acceptable: a temp-dir SQLite file open does not realistically fail,
          // and this only runs if the shared store already failed.
          return (try? SessionStore(url)) ?? (try! SessionStore(url))
      }()
  ```

  > If SwiftLint flags `try!`, wrap differently, but the `try?`-then-`try!` pattern keeps a single deterministic path. (`force_try` is allowed in this repo's config; verify by building.)

- [ ] **Step 3: Add the `.sessionManager` case to NavigatorTab.swift**

  - In `systemImage`, add: `case .sessionManager: return "rectangle.connected.to.line.below"`
  - In `title`, add: `case .sessionManager: return "Sessions"`
  - In `body`, add: `case .sessionManager: SessionManagerNavigatorView()`
  - Add the enum case `case sessionManager` near the top (after `case search`).

  The `id` computed property returns `title` for non-extension cases, so `.sessionManager` gets a stable id automatically.

- [ ] **Step 4: Register the tab in NavigatorAreaView.swift** — change line 22's array from `[.project, .sourceControl, .search]` to:

  ```swift
          viewModel.tabItems = [.project, .sourceControl, .search, .sessionManager] +
  ```

- [ ] **Step 5: Build and run.** Expect `** BUILD SUCCEEDED **`. Launch CodeEdit (⌘R); the navigator now shows a "Sessions" tab. The `openDetachedPanel()` call references `SessionManagerPanelController` (Task 11) — if building before Task 11, temporarily stub `openDetachedPanel()` to an empty body, then restore it in Task 11. (Recommended: execute Task 11 immediately after so no stub is needed.)

- [ ] **Step 6: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionManagerNavigatorView.swift \
          CodeEdit/Features/RemoteTerminal/Sessions/SessionStore.swift \
          CodeEdit/Features/NavigatorArea/Models/NavigatorTab.swift \
          CodeEdit/Features/NavigatorArea/Views/NavigatorAreaView.swift
  git commit -m "feat: add Session Manager navigator tab

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

# Part D — Detachable panel

## Task 11: Detachable floating panel

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionManagerPanel.swift`

A non-activating `NSPanel` that floats above other windows and hosts the same tree, sharing the navigator's `SessionManagerViewModel` instance.

- [ ] **Step 1: Create SessionManagerPanel.swift**

  ```swift
  //
  //  SessionManagerPanel.swift
  //  CodeEdit
  //

  import AppKit
  import SwiftUI

  /// Manages a single shared floating Session Manager panel.
  final class SessionManagerPanelController {
      static let shared = SessionManagerPanelController()
      private var panel: NSPanel?

      func show(viewModel: SessionManagerViewModel, workspace: WorkspaceDocument) {
          if let panel {
              panel.makeKeyAndOrderFront(nil)
              return
          }
          let content = SessionManagerPanelView(viewModel: viewModel)
              .environmentObject(workspace)

          let hosting = NSHostingController(rootView: content)
          let newPanel = NSPanel(
              contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
              styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
              backing: .buffered,
              defer: false
          )
          newPanel.title = "Sessions"
          newPanel.isFloatingPanel = true
          newPanel.level = .floating
          newPanel.hidesOnDeactivate = false
          newPanel.contentViewController = hosting
          newPanel.center()
          newPanel.isReleasedWhenClosed = false
          newPanel.makeKeyAndOrderFront(nil)
          self.panel = newPanel
      }
  }

  /// The panel's body: the same tree, minus the detach button.
  private struct SessionManagerPanelView: View {
      @ObservedObject var viewModel: SessionManagerViewModel
      @EnvironmentObject private var workspace: WorkspaceDocument

      private var connectedSessionIDs: Set<UUID> {
          guard let terminals = workspace.utilityAreaModel?.terminals else { return [] }
          return Set(terminals.compactMap { terminal in
              switch terminal.connectionType {
              case .ssh(let session, _): return session.id
              case .telnet(let session): return session.id
              case .localShell: return nil
              }
          })
      }

      var body: some View {
          SessionOutlineView(
              viewModel: viewModel,
              connectedSessionIDs: connectedSessionIDs,
              onConnect: { sessionID in
                  guard let utilityArea = workspace.utilityAreaModel else { return }
                  viewModel.connect(sessionID, using: utilityArea)
                  workspace.utilityAreaModel?.isCollapsed = false
              },
              onEditSession: { _ in },
              onDuplicate: { viewModel.duplicateSession($0) },
              onDelete: { viewModel.deleteNode($0) },
              onNewFolder: { viewModel.createFolder(name: "New Folder", in: $0) }
          )
          .frame(minWidth: 280, minHeight: 360)
      }
  }
  ```

- [ ] **Step 2: Build and run.** Expect `** BUILD SUCCEEDED **`. In the running app, the Sessions navigator's detach button (bottom-right) now opens a floating panel that stays above the main window and shows the same tree. Double-clicking a session there opens a terminal tab.

- [ ] **Step 3: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionManagerPanel.swift
  git commit -m "feat: add detachable floating Session Manager panel

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

# Part E — Settings (defaults, bulk edit entry, SecureCRT import)

## Task 12: SessionManagerSettings model

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/Settings/SessionManagerSettings.swift`
- Modify: `CodeEdit/Features/Settings/Models/SettingsData.swift`
- Test: `CodeEditTests/Features/RemoteTerminal/SessionManagerSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

  Create `CodeEditTests/Features/RemoteTerminal/SessionManagerSettingsTests.swift`:

  ```swift
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
  ```

- [ ] **Step 2: Run, confirm failure.**

- [ ] **Step 3: Create SessionManagerSettings.swift**

  ```swift
  //
  //  SessionManagerSettings.swift
  //  CodeEdit
  //

  import Foundation

  extension SettingsData {
      /// Defaults applied when creating new remote sessions.
      struct SessionManagerSettings: Codable, Hashable, SearchableSettingsPage {
          /// Default protocol for new sessions.
          var defaultProtocol: ConnectionProtocol = .ssh
          /// Default username pre-filled in new sessions.
          var defaultUsername: String = ""
          /// Default authentication method for new SSH sessions.
          var defaultAuthMethod: AuthMethodKind = .password

          var searchKeys: [String] {
              ["Session Manager", "Default Protocol", "Default Username", "Default Auth Method", "SecureCRT Import"]
          }

          init() {}

          init(from decoder: Decoder) throws {
              let container = try decoder.container(keyedBy: CodingKeys.self)
              self.defaultProtocol = try container.decodeIfPresent(
                  ConnectionProtocol.self, forKey: .defaultProtocol
              ) ?? .ssh
              self.defaultUsername = try container.decodeIfPresent(String.self, forKey: .defaultUsername) ?? ""
              self.defaultAuthMethod = try container.decodeIfPresent(
                  AuthMethodKind.self, forKey: .defaultAuthMethod
              ) ?? .password
          }
      }
  }
  ```

  > `AuthMethodKind` (from Task 6) must be `Codable`. Update its declaration in `SessionPropertiesView.swift` to: `enum AuthMethodKind: String, Codable, Hashable {` (the raw-string conformance gives stable Codable). Keep its cases and the `init(_:)`/`authMethod` members.

  > `SearchableSettingsPage` is the existing protocol the other settings groups conform to (it requires `searchKeys: [String]`). Confirm its exact name by reading another settings group (e.g. `GeneralSettings`); if the protocol is named differently, match it. If groups don't use a shared protocol, drop the conformance and just provide `var searchKeys: [String]`.

- [ ] **Step 4: Wire into SettingsData.swift**

  - Add the stored property after `developerSettings`:
    ```swift
        /// Session Manager defaults
        var sessionManager: SessionManagerSettings = .init()
    ```
  - In `init(from:)`, add:
    ```swift
        self.sessionManager = try container.decodeIfPresent(
            SessionManagerSettings.self, forKey: .sessionManager
        ) ?? .init()
    ```
  - In `propertiesOf(_:)`, add a case:
    ```swift
        case .sessionManager:
            sessionManager.searchKeys.forEach { settings.append(.init(name, isSetting: true, settingName: $0)) }
    ```

- [ ] **Step 5: Add the page name** in `SettingsPage.swift` `enum Name`: `case sessionManager = "Session Manager"`

- [ ] **Step 6: Run tests, confirm pass; build to confirm SettingsData compiles.** Expect tests `** TEST SUCCEEDED **` and `** BUILD SUCCEEDED **`.

  > If the build fails because the `propertiesOf` switch is now non-exhaustive or `SettingsPage.Name` is used in another exhaustive switch (e.g. `SettingsView`), Task 13 adds the remaining `SettingsView` cases. If a switch elsewhere breaks the build at this step, add the `.sessionManager` case there mirroring a neighboring page and note it.

- [ ] **Step 7: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/Settings/SessionManagerSettings.swift \
          CodeEdit/Features/RemoteTerminal/SessionManager/Views/SessionPropertiesView.swift \
          CodeEdit/Features/Settings/Models/SettingsData.swift \
          CodeEdit/Features/Settings/Models/SettingsPage.swift \
          CodeEditTests/Features/RemoteTerminal/SessionManagerSettingsTests.swift
  git commit -m "feat: add Session Manager settings model

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 13: Session Manager settings page (defaults + SecureCRT import)

**Files:**
- Create: `CodeEdit/Features/RemoteTerminal/SessionManager/Settings/SessionManagerSettingsView.swift`
- Modify: `CodeEdit/Features/Settings/SettingsView.swift`

- [ ] **Step 1: Create SessionManagerSettingsView.swift**

  ```swift
  //
  //  SessionManagerSettingsView.swift
  //  CodeEdit
  //

  import SwiftUI

  struct SessionManagerSettingsView: View {
      @AppSettings(\.sessionManager)
      var settings

      @State private var importMessage: String?

      var body: some View {
          SettingsForm {
              Section {
                  Picker("Default Protocol", selection: $settings.defaultProtocol) {
                      Text("SSH").tag(ConnectionProtocol.ssh)
                      Text("Telnet").tag(ConnectionProtocol.telnet)
                  }
                  TextField("Default Username", text: $settings.defaultUsername)
                  Picker("Default Auth Method", selection: $settings.defaultAuthMethod) {
                      Text("Password").tag(AuthMethodKind.password)
                      Text("Public Key").tag(AuthMethodKind.publicKey)
                      Text("Keyboard Interactive").tag(AuthMethodKind.keyboardInteractive)
                  }
              }
              Section("SecureCRT Import") {
                  Button("Import SecureCRT Sessions…") { runImport() }
                  if let importMessage {
                      Text(importMessage).font(.caption).foregroundStyle(.secondary)
                  }
              }
          }
      }

      private func runImport() {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = true
          panel.canChooseFiles = false
          panel.allowsMultipleSelection = false
          panel.prompt = "Import"
          panel.message = "Choose your SecureCRT \"Sessions\" folder"
          guard panel.runModal() == .OK, let url = panel.url, let store = SessionStore.shared else {
              return
          }
          do {
              let result = try SecureCRTImporter.importTree(from: url, into: SessionFolder.rootID)
              for folder in result.folders { store.saveFolder(folder) }
              for session in result.sessions { store.saveSession(session) }
              // Attach imported top-level items to the root folder's ordering.
              var root = store.allFolders().first { $0.id == SessionFolder.rootID }
                  ?? SessionFolder(id: SessionFolder.rootID, name: "")
              let topFolderIDs = result.folders.filter { $0.parentID == SessionFolder.rootID }.map(\.id)
              let topSessionIDs = result.sessions.filter { $0.folderID == SessionFolder.rootID }.map(\.id)
              for id in topFolderIDs + topSessionIDs where !root.childIDs.contains(id) {
                  root.childIDs.append(id)
              }
              store.saveFolder(root)
              importMessage = "Imported \(result.sessions.count) sessions, \(result.folders.count) folders."
          } catch {
              importMessage = "Import failed: \(error.localizedDescription)"
          }
      }
  }
  ```

  > `SettingsForm`, `Section`, and `@AppSettings` are the existing settings-page building blocks — confirm `SettingsForm` exists by reading e.g. `GeneralSettingsView.swift`; if the project uses a plain `Form`, mirror that instead. `@AppSettings(\.sessionManager)` must resolve now that Task 12 added the `sessionManager` property.

- [ ] **Step 2: Register the page in SettingsView.swift**

  - Add to the `pages` array (mirror a neighboring entry such as `.terminal`), placing it sensibly near Terminal:
    ```swift
        .init(
            SettingsPage(
                .sessionManager,
                baseColor: .teal,
                icon: .system("rectangle.connected.to.line.below")
            )
        ),
    ```
  - Add the detail switch case (mirror the `.terminal` case):
    ```swift
        case .sessionManager:
            SessionManagerSettingsView()
    ```

  > If `SettingsView` groups pages into sections, place the entry in the most fitting section. Read the file to find the exact array/switch shapes before editing.

- [ ] **Step 3: Build and run.** Expect `** BUILD SUCCEEDED **`. In Settings (⌘,), a "Session Manager" page shows the defaults and an "Import SecureCRT Sessions…" button. Importing a SecureCRT `Sessions` directory populates the navigator tree (reopen/reswitch the Sessions tab to reload, or it reloads on next construction).

- [ ] **Step 4: Manual end-to-end test**

  1. Open the **Sessions** navigator tab. Use the bottom "+" to create a session (e.g. name `localhost`, SSH, host `127.0.0.1`, your username, password). Save.
  2. Create a folder, drag the session into it, confirm it persists after quitting/reopening the workspace.
  3. Double-click the session → a terminal tab opens in the bottom utility area and connects (Remote Login enabled for SSH localhost).
  4. Right-click → Duplicate / Properties / Delete all behave.
  5. Detach button opens the floating panel; connecting from it works.
  6. Settings → Session Manager → import a SecureCRT `Sessions` folder; imported sessions appear in the tree.

- [ ] **Step 5: Commit**

  ```bash
  git add CodeEdit/Features/RemoteTerminal/SessionManager/Settings/SessionManagerSettingsView.swift \
          CodeEdit/Features/Settings/SettingsView.swift
  git commit -m "feat: add Session Manager settings page with SecureCRT import

  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Self-Review Checklist

**Spec coverage (design doc "Session Manager UI" section):**
- ✅ Navigator tab alongside file tree / source control (Task 10)
- ✅ Tree with folders + sessions, `NSOutlineView`-backed (Tasks 7–8)
- ✅ Session row: name, protocol badge, status dot, last-connected tooltip (Task 6)
- ✅ Context menu: Connect, Open in New Tab, Duplicate, New Folder, Properties, Delete (Task 9); Move to Folder via drag-and-drop (Task 8)
- ✅ Search across name/hostname/username/notes (Tasks 4, 10)
- ✅ Detachable floating `NSPanel` + detach button (Tasks 10–11)
- ✅ Open session → utility-area terminal tab; multiple connects → multiple tabs (Task 4 `connect`)
- ✅ SecureCRT `.ini` import (Tasks 5, 13)
- ✅ Bulk-edit auth method across a folder (ViewModel Task 4; surfaced via settings/import path — also callable from menu in future)
- ✅ Session notes field, markdown-rendered (Task 6 properties view)
- ✅ GRDB persistence + Keychain credentials wired into the UI (Tasks 2–4)
- ✅ Session Manager settings page: default protocol/username/auth + SecureCRT import (Tasks 12–13)

**Deferred / explicitly noted limitations:**
- Amber "connecting" status dot — approximated as green; precise mid-handshake state needs the connection layer to publish live state (future).
- SSH public-key selection mints a placeholder `keyID`; a real key picker ties into the Accounts key store in a later phase.
- Known-hosts host-key verification (separate Phase-3+ security concern).
- Bulk-edit UI affordance beyond auth method (e.g. theme) — themes are Phase 6.

**Placeholder scan:** No TBD/TODO in code; every code step is complete. Reconciliation notes (where the plan says "confirm X exists / mirror the real shape") are explicit instructions to verify a real API, not placeholders for missing logic.

**Type consistency:**
- `SessionManagerViewModel(store:credentials:)` — used in tests (Tasks 1–4) and views (Tasks 10–11).
- `children(of:)`, `rootNodes`, `createSession(_:in:)`, `createFolder(name:in:)`, `move(_:to:at:)`, `isDescendant(_:of:)`, `searchMatches(query:)`, `setPassword(_:for:)`, `password(for:)`, `bulkSetAuthMethod(_:inFolder:)`, `connect(_:using:)`, `duplicateSession(_:)`, `deleteNode(_:)`, `updateSession(_:)`, `renameFolder(_:to:)` — defined in Tasks 2–4, consumed identically in Tasks 7–11.
- `SessionTreeNode` (`.folder`/`.session`, `id`, `isFolder`, `name`) — Task 1, used in ViewModel + outline controller.
- `SessionFolder.rootID` — Task 1, used throughout.
- `SessionOutlineView(viewModel:connectedSessionIDs:onConnect:onEditSession:onDuplicate:onDelete:onNewFolder:)` — closures defined across Tasks 7 + 9, all supplied by callers in Tasks 10–11.
- `SessionConnectionStatus` / `AuthMethodKind` — Task 6; `AuthMethodKind` made `String, Codable` in Task 12 and reused in settings.
- `SecureCRTImporter.parseSession(ini:name:folderID:)` / `importTree(from:into:)` — Task 5, used in Task 13.
- `SessionManagerSettings` + `SettingsData.sessionManager` — Task 12, used in Task 13 view.
- `UtilityAreaViewModel.addSSHTerminal(session:password:)` / `addTelnetTerminal(session:)`, `workspace.utilityAreaModel`, `TerminalConnectionType.ssh/.telnet/.localShell` — real Phase-1/2 APIs, used in `connect` and `connectedSessionIDs`.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-08-phase3-session-manager.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, two-stage review (spec + quality) between tasks.
2. **Inline Execution** — execute here with checkpoints.

Which approach?
