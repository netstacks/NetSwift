# Remote Terminal Feature Design
**Date:** 2026-06-07
**Status:** Approved

## Overview

This document specifies the design for a SecureCRT-replacement remote terminal feature in this CodeEdit fork. The feature adds SSH and Telnet connectivity, a full session manager, keyword highlighting, a type-enforced sanitization layer, AI integration, and terminal themes — all as a unified in-process feature with no sidecar processes.

This is a development fork, not a production app. All existing code is fair game for refactoring.

---

## Goals

- Replace SecureCRT as the primary remote terminal tool
- Match SecureCRT feature parity, exceed it where possible
- Full AI integration across terminal and editor surfaces from day one
- Sanitization layer that is architecturally impossible for AI to bypass
- All-in-one process: swift-nio-ssh, Network.framework, GRDB, AI API calls — no helpers

---

## Architecture

### TerminalConnection Protocol

The entire terminal system — local shell, SSH, and Telnet — is unified under a single protocol. This is a refactor of the existing `TerminalEmulator` feature.

```swift
protocol TerminalConnection: AnyObject {
    var id: UUID { get }
    var observers: [any TerminalConnectionObserver] { get set }
    func connect() async throws
    func disconnect()
    func send(data: ArraySlice<UInt8>)
}

protocol TerminalConnectionObserver: AnyObject {
    // Mutating observers transform the stream
    func process(bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8>
    // Non-mutating observers receive sanitized plain text only
    func didReceive(text: SanitizedText, from connection: any TerminalConnection)
    func didSend(text: String, to connection: any TerminalConnection)
}
```

**Three conformances:**
- `LocalShellConnection` — refactored from existing `CELocalShellTerminalView`, wraps `LocalProcess`
- `SSHConnection` — wraps swift-nio-ssh via `NIOAsyncChannel`
- `TelnetConnection` — wraps Network.framework TCP + NVT protocol

`CETerminalView` (the SwiftTerm display wrapper) holds a `TerminalConnection` and feeds bytes from the pipeline. It knows nothing about connection type.

### Full Pipeline

```
Raw bytes from connection
        ↓
ANSIHighlightPreprocessor       ← injects ANSI color codes for keyword rules
        ↓
SanitizationProcessor           ← produces SanitizedText (opaque type)
        ├── SanitizedText ─────→ AIObserver        (always, type-enforced)
        ├── SanitizedText ─────→ SessionLogger     (always, no raw logs on disk)
        └── DisplayGate
                ├── [default]  → SanitizedText ──→ CETerminalView
                └── [revealed] → raw bytes ──────→ CETerminalView + ⚠️ indicator
```

### Async/Await Throughout

swift-nio-ssh uses SwiftNIO event loops. All connection types bridge to Swift structured concurrency via `NIOAsyncChannel`. The entire app uses `async/await` uniformly — no callbacks, no manual thread management. AI service calls are `async` functions on the same concurrency model.

### Feature Module Structure

```
CodeEdit/Features/RemoteTerminal/
    Connections/
        TerminalConnection.swift         ← protocol + observer protocol
        SSHConnection.swift
        TelnetConnection.swift
        LocalShellConnection.swift       ← refactored from TerminalEmulator
    Sessions/
        RemoteSession.swift
        SessionFolder.swift
        SessionStore.swift               ← GRDB persistence
    SessionManager/
        Views/
            SessionManagerView.swift     ← navigator tab + detachable panel
            SessionManagerTree.swift
            SessionPropertiesView.swift
        ViewModels/
            SessionManagerViewModel.swift
    Highlighting/
        HighlightRule.swift
        HighlightRuleSet.swift
        ANSIHighlightPreprocessor.swift
    Sanitization/
        SanitizedText.swift              ← opaque type, fileprivate init
        SanitizationRule.swift
        SanitizationProcessor.swift
        DefaultSanitizationRules.swift
    AI/
        AIService.swift                  ← protocol, registered in ServiceContainer
        ClaudeAIService.swift            ← concrete implementation
        AITerminalObserver.swift
        AIEditorObserver.swift
        AIContextBuffer.swift            ← local ring buffer, no API calls
    Themes/
        TerminalTheme.swift
        TerminalThemeStore.swift
        BuiltInThemes.swift
    Settings/
        RemoteTerminalSettings.swift     ← extends SettingsData
```

`CETerminalView` moves from `TerminalEmulator/` to a shared location used by both `TerminalEmulator/` and `RemoteTerminal/`.

---

## Session Data Model & Persistence

### Models

```swift
struct RemoteSession: Identifiable, Codable {
    var id: UUID
    var name: String
    var folderID: UUID?
    var protocol: ConnectionProtocol      // .ssh | .telnet
    var hostname: String
    var port: Int                         // default: SSH=22, Telnet=23
    var username: String
    var authMethod: AuthMethod
    var highlightSetIDs: [UUID]           // per-session assigned sets
    var themeID: UUID?                    // nil = use global default
    var lastConnectedAt: Date?
    var notes: String
    var terminalSettings: TerminalSessionSettings
}

enum AuthMethod {
    case password                         // credential in Keychain
    case publicKey(keyID: UUID)           // references AccountsSettings key store
    case keyboardInteractive              // TACACS+/RADIUS, prompts at connect time
}

struct SessionFolder: Identifiable, Codable {
    var id: UUID
    var name: String
    var parentID: UUID?
    var childIDs: [UUID]                  // ordered mix of folder and session IDs
}
```

### Persistence

- **GRDB** (already a dependency) — sessions and folders stored in SQLite at `~/Library/Application Support/CodeEdit/sessions.db`
- **Keychain** — passwords and key passphrases via existing `KeyChain` utility
- **SSH keys** — reference existing `AccountsSettings` key store by UUID

**Advantage over SecureCRT:** SecureCRT uses flat `.ini` files. GRDB gives fast search across hundreds of sessions, proper relational queries, and a clean SecureCRT import path.

---

## Session Manager UI

### Navigator Tab

New tab in the Navigator area alongside the file tree and source control. SwiftUI `List` with `DisclosureGroup` backed by `NSOutlineView` for drag-and-drop reordering. Each session row shows:
- Session name
- Protocol badge (SSH / Telnet)
- Status dot: green = connected, amber = connecting, gray = disconnected
- Last connected timestamp on hover

Context menu (right-click): Connect, Open in New Tab, Duplicate, Move to Folder, Properties, Delete.
Search field at top — filters live across name, hostname, username, and notes.

### Detachable Window

The session manager tears off as a non-activating `NSPanel` that floats above other windows (matching SecureCRT's Connect dialog behavior). Same tree view and all the same actions. Detach button in the navigator tab toolbar.

### Opening a Session

Double-click or "Connect" opens the session as an **editor tab**. Tab title = session name + protocol badge. Multiple simultaneous connections to the same session each get their own tab. Disconnected tabs show a **Reconnect** button in the jump bar area — they do not auto-close.

### Better Than SecureCRT

- Import existing SecureCRT session trees (parse SecureCRT `.ini` session files)
- Bulk-edit sessions: change auth method or theme across an entire folder
- Search spans name, hostname, username, and notes simultaneously
- Session notes field (markdown-rendered in properties panel)

---

## Connections

### SSH (swift-nio-ssh)

Apple's official Swift SSH library. Handles all SSH protocol: key exchange, encryption, channel multiplexing. Bridged to Swift concurrency via `NIOAsyncChannel`.

**Authentication:**
- Password: retrieved from Keychain at connect time
- Public key: loaded from AccountsSettings key store by keyID
- Keyboard-interactive: presents a native prompt sheet for each challenge (TACACS+/RADIUS compatible)

**Host key verification:** configurable per the Remote Connections settings (strict / warn / ignore). Known hosts stored in `~/Library/Application Support/CodeEdit/known_hosts`.

### Telnet (Network.framework)

`NWConnection` over TCP. NVT (Network Virtual Terminal) option negotiation handled in `TelnetConnection`. No additional dependencies.

---

## Terminal Display

Existing `CETerminalView` (SwiftTerm wrapper) is reused unchanged as the display layer. It accepts bytes from the pipeline and renders them. It has no knowledge of connection type, sanitization state, or AI.

The `DisplayGate` sits between the pipeline and `CETerminalView`, choosing between sanitized and raw bytes based on the reveal toggle state.

---

## Terminal Themes

Terminal themes define the base rendering palette. They are a distinct system from keyword highlighting (which layers on top) and editor themes (different color semantics entirely).

### Theme Model

```swift
struct TerminalTheme: Identifiable, Codable {
    var id: UUID
    var name: String
    var isBuiltIn: Bool

    // Base colors
    var background: Color
    var foreground: Color
    var boldColor: Color
    var cursorColor: Color
    var cursorStyle: CursorStyle        // .block | .underline | .bar
    var cursorBlinks: Bool
    var selectionColor: Color

    // 16 ANSI colors
    var ansiColors: ANSIColorPalette    // 8 standard + 8 bright
}
```

### Built-In Themes

Solarized Dark, Solarized Light, Nord, Dracula, One Dark, Material Dark, Classic (SecureCRT default equivalent).

### Rendering Order

Terminal theme colors are the base layer. Keyword highlight rules inject ANSI escape codes on top. Highlight rules always win over theme defaults when both apply.

### Per-Session Assignment

Each session can specify a `themeID`. If nil, the global default theme applies. Changed in session properties.

---

## Keyword Highlighting Engine

### Models

```swift
struct HighlightRule: Identifiable {
    var id: UUID
    var pattern: HighlightPattern       // .keyword(String) | .regex(String)
    var isCaseSensitive: Bool
    var foreground: Color?
    var background: Color?
    var bold: Bool
    var underline: Bool
    var priority: Int                   // higher wins on overlapping matches
}

struct HighlightRuleSet: Identifiable {
    var id: UUID
    var name: String
    var isGlobal: Bool
    var rules: [HighlightRule]          // ordered by priority
}
```

### Merge Behavior

Global sets always apply. Per-session sets merge on top — session rules win on conflict. Merge is computed once at connection open, not per-byte.

### ANSIHighlightPreprocessor

1. Parse incoming bytes — separate ANSI escape sequences from plain text
2. Match plain text segments against merged rule set (regex compiled once at merge time)
3. Wrap matches with ANSI color escape codes
4. Reconstruct byte stream — original escape codes + injected highlight codes
5. Pass downstream

### Better Than SecureCRT

- Full `NSRegularExpression` (PCRE-compatible) vs SecureCRT's limited regex
- Explicit priority ordering with drag-to-reorder UI
- Live preview in rule editor — type pattern, see it highlighted against sample output in real time
- Import/export rule sets as JSON — share "Cisco IOS" or "Juniper" sets with teammates
- Built-in starter sets for Cisco IOS, Juniper JunOS, Arista EOS shipped with the app

---

## Sanitization Layer

### Core Guarantee

`SanitizedText` is an opaque type with a `fileprivate` initializer. Only `SanitizationProcessor` can construct it. `AIObserver` and `SessionLogger` accept only `SanitizedText`. The Swift compiler enforces this — no runtime check, no policy, no configuration bypasses it.

```swift
struct SanitizedText {
    let value: String
    fileprivate init(_ text: String) { self.value = text }
}
```

### Pipeline Position

Sanitization runs after `ANSIHighlightPreprocessor` and before `AIObserver`, `SessionLogger`, and `DisplayGate`. The AI path is structurally downstream of sanitization with no alternative route.

### Default Rules (Protected)

Displayed read-only in settings. Cannot be globally deleted. Can be disabled per-session only, with explicit intent.

| Pattern | Matches | Replacement |
|---|---|---|
| `enable secret \S+` | Cisco enable secrets | `enable secret [REDACTED]` |
| `password \S+` | IOS password fields | `password [REDACTED]` |
| `community \S+` | SNMP community strings | `community [REDACTED]` |
| `neighbor \S+ password \S+` | BGP neighbor passwords | `neighbor X password [REDACTED]` |
| `radius-server key \S+` | RADIUS shared keys | `radius-server key [REDACTED]` |
| `tacacs-server key \S+` | TACACS+ keys | `tacacs-server key [REDACTED]` |
| `key-string \S+` | NTP/routing auth keys | `key-string [REDACTED]` |
| `\$1\$[A-Za-z0-9./]+` | Cisco MD5 hashes | `[REDACTED-HASH]` |
| `-----BEGIN .* KEY-----[\s\S]+?-----END` | Private keys | `[REDACTED-KEY]` |

### User-Defined Rules

Full CRUD in settings. Regex input with live test field — paste sample text, see redaction result inline before saving. Replacement text configurable per-rule.

### Reveal Toggle

- Lock icon in terminal tab toolbar — locked (sanitized) by default
- On reveal: terminal border turns amber, banner reads **"Sensitive data visible — sanitization paused"**
- Auto-revert timer shown in banner — default 60 seconds, configurable
- On re-lock (manual or auto): terminal clears and replays from sanitized session log. Message: *"Terminal cleared — sanitization restored."*
- Clear-on-relock is on by default. Configurable off (new bytes sanitized, old raw content remains visible until scroll-off).

### Session Logs

Always store `SanitizedText`. No raw bytes written to disk, ever. Raw transcript export is a separate explicit action with a warning dialog.

---

## AI Integration

### No Streaming

The `AITerminalObserver` never streams to the API. It maintains a **local in-memory ring buffer** of plain text (ANSI stripped, sanitized). Zero API calls during normal terminal operation.

### Trigger Model

```
Terminal output → local ring buffer (free, always)
                        ↓
           [trigger fires] → API call (costs tokens)
```

**Three trigger types:**

| Trigger | Who initiates | Context sent | Model |
|---|---|---|---|
| Explicit (Cmd+K) | User | Last N lines (configurable, default 50) | Sonnet |
| Ghost text — terminal | 300ms typing pause | Partial command + last 10 lines | Haiku |
| Ghost text — editor | 300ms typing pause | Current line + 20 surrounding lines + language | Haiku |
| Proactive | Local pattern match gate | Matching chunk only | Haiku → Sonnet on demand |

**Proactive triggers use the keyword highlight rules as the gate.** If no local pattern matches, no API call is made. Local match fires → small targeted call. The keyword engine is already scanning every line — AI piggybacks on that work for free.

### Model Tiering

| Surface | Default model | User-overridable |
|---|---|---|
| Ghost text (editor + terminal) | Haiku | Yes |
| Proactive triage | Haiku | Yes |
| Explain / Cmd+K | Sonnet | Yes |
| Full session analysis | Opus | Yes |

### What AI Can Do

- **Observe** — reads sanitized output, builds session context in local buffer
- **Explain** — select terminal text → Cmd+K → explanation in inline panel
- **Suggest** — proactive command suggestions when errors/events detected
- **Inject** — suggested commands appear as ghost text or action panel; user approves with one keystroke before bytes are sent to connection
- **Semantic highlighting** — AI can emit dynamic highlight rules back to the highlight engine, layered on top of static keyword rules
- **Editor completions** — Copilot-style ghost text in file editing (scripts, configs)
- **Terminal input completions** — ghost text in terminal prompt, session-context-aware

### AI UI Surfaces

1. **Inline terminal panel** — slides up from terminal tab bottom on Cmd+K, shows response + suggested commands with one-click send. Dismisses cleanly.
2. **Inspector area tab** — persistent AI context panel: session summary, recent suggestions, history. Available across all features.
3. **Command palette** — natural language queries routed to AI, generated commands sent to active session.
4. **Editor inline** — ghost text overlay in `CodeEditSourceEditor` (requires forking `CodeEditSourceEditor` package).
5. **Terminal input ghost text** — intercepted at SwiftTerm input pipeline before bytes are sent.

### AIService in ServiceContainer

```swift
// Registered at launch in CodeEditApp.swift, same pattern as LSPService
ServiceContainer.register(ClaudeAIService())

// All features access it the same way
@Environment(\.aiService) var aiService
```

Single service, single API key, single model configuration. All features — terminal, editor, source control, navigator — share it.

---

## Settings Pages

All new pages integrated into the existing CodeEdit Settings window.

### Remote Connections
- Default SSH port (default: 22)
- Default Telnet port (default: 23)
- Connection timeout
- Keep-alive interval
- Host key verification: strict / warn / ignore
- Known hosts file location (default: `~/Library/Application Support/CodeEdit/known_hosts`)
- Password storage: Keychain / prompt each time
- Keyboard-interactive auth timeout
- Auto-reconnect on drop: on/off, retry count, retry interval

### Session Manager
- Default protocol for new sessions
- Default username
- Default auth method
- SecureCRT session import: file picker + import action

### Terminal Themes
- Theme list: create, duplicate, delete, set as default
- Theme editor: all palette colors, cursor style/color/blink, selection color
- Import / export themes as JSON
- Per-session theme assignment in session properties

### Keyword Highlighting
- Global rule set management: create, edit, delete, reorder, enable/disable
- Import / export rule sets as JSON
- Built-in starter sets toggle (Cisco IOS, Juniper JunOS, Arista EOS)
- Rule editor: pattern (keyword or regex), case sensitivity, colors, bold/underline, live preview field

### Sanitization
- Protected default rules: read-only list with per-session disable toggle
- User-defined rules: create, edit, delete with live test field
- Redaction replacement text (configurable per-rule, default: `[REDACTED]`)
- Reveal timeout: duration in seconds, or disable auto-revert
- Clear terminal on re-lock: on/off
- Session log behavior: informational display (always sanitized, not toggleable)

### AI
- API key entry
- Model per surface: ghost text (default Haiku), explain (default Sonnet), full analysis (default Opus) — each independently overridable
- Enable/disable ghost text in editor
- Enable/disable ghost text in terminal input
- Enable/disable proactive suggestions
- Completion debounce delay (default 300ms)
- Context window size — lines of terminal history sent to AI (default 50)
- Proactive trigger sensitivity: conservative / balanced / aggressive

### Terminal Display (extend existing)
- Scrollback buffer size
- Session logging: enable/disable, log file location, rotation policy (by size / by time)
- Terminal encoding (default UTF-8)

---

## Dependencies

| Library | Purpose | Status |
|---|---|---|
| SwiftTerm | Terminal display | Already a dep (custom fork) |
| swift-nio-ssh | SSH protocol | New — add via SPM |
| Network.framework | Telnet TCP | Built into macOS, no addition needed |
| GRDB | Session persistence | Already a dep |
| KeyChain (internal) | Credential storage | Already exists in Utils/ |

**CodeEditSourceEditor fork required** for editor ghost text. Ghost text rendering hooks must live inside the package — they cannot be bolted on from outside.

---

## Out of Scope for v1

- Serial / COM port connections
- SFTP / SCP file transfer
- Port forwarding / tunneling
- X11 forwarding
- Session recording playback (logs are stored, UI replay is v2)
- Multi-pane split terminal within a single session tab (v2)
- Local AI models (Ollama etc.) — API-based only at launch

---

## Open Questions (resolved)

- **Architecture:** Approach C — unified `TerminalConnection` protocol, full refactor, dev fork so no production risk.
- **AI streaming:** Rejected. Local ring buffer + on-demand API calls only.
- **Sanitization scope:** Both display and AI path. Display has reveal toggle. AI path has no toggle.
- **Protocols v1:** SSH + Telnet only. Serial deferred.
- **Sidecar processes:** None. All in-process.
