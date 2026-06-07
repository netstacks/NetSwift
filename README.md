<p align="center">
  <h1 align="center">NetSwift for macOS</h1>
  <p align="center">Native macOS SSH/Telnet terminal, code editor, and AI assistant — built for network engineers.</p>
</p>

<p align="center">
  <a aria-label="Follow NetSwift on GitHub" href="https://github.com/netstacks/NetSwift" target="_blank">
    <img alt="" src="https://img.shields.io/badge/netstacks%2FNetSwift-black.svg?style=for-the-badge&logo=github">
  </a>
  <a aria-label="License" href="https://github.com/netstacks/NetSwift/blob/main/LICENSE.md" target="_blank">
    <img alt="" src="https://img.shields.io/github/license/netstacks/NetSwift?style=for-the-badge&color=orange">
  </a>
</p>

---

NetSwift is a native macOS code editor and remote terminal built for network engineers. It combines the editing power of a modern code editor with a full-featured SSH/Telnet client designed to replace SecureCRT — plus deep AI integration throughout.

Written entirely in Swift and SwiftUI, NetSwift is unapologetically native macOS. No Electron. No sidecar processes. No compromises.

> **Status:** Active development. Not yet recommended for production use.

## Features

### Remote Terminal
- **SSH and Telnet** connections with full VT100/VT220 terminal emulation
- **Session Manager** — folder-organized saved sessions with status indicators, drag-and-drop, bulk editing, and SecureCRT session import
- **Authentication** — password, SSH public key, and keyboard-interactive (TACACS+/RADIUS)
- **Multiple simultaneous connections** — each session opens as a native editor tab
- **Session reconnect** — disconnected tabs stay open with a one-click reconnect

### Keyword Highlighting
- **User-defined highlight rules** — keyword or full regex (PCRE-compatible), per-rule foreground/background color, bold, underline
- **Global and per-session rule sets** — global sets apply everywhere, per-session sets layer on top
- **Built-in starter sets** — Cisco IOS, Juniper JunOS, Arista EOS
- **Import/export** — share rule sets with your team as JSON
- **Live preview** — see highlighting applied as you write the rule

### Sanitization Layer
- **Type-enforced secrets redaction** — a structural guarantee that AI and session logs never receive unsanitized content, regardless of settings
- **Default rules** — redacts Cisco enable secrets, SNMP community strings, BGP passwords, RADIUS/TACACS+ keys, MD5 hashes, and private keys out of the box
- **User-defined rules** — add regex-based redaction rules with a live test field
- **Reveal toggle** — temporarily show raw content in the terminal display with an amber indicator and configurable auto-revert timer

### Terminal Themes
- **16-color ANSI palette** — fully configurable per theme
- **Per-session theme assignment**
- **Built-in themes** — Solarized Dark/Light, Nord, Dracula, One Dark, Material Dark, and more
- **Import/export** themes as JSON

### AI Integration
- **Copilot-style ghost text** in the code editor and terminal input line — context-aware, debounced, uses a fast lightweight model
- **Cmd+K explain panel** — select terminal output, get an AI explanation, send suggested commands with one keystroke
- **Proactive suggestions** — AI triggers on local pattern matches (errors, interface state changes), not on continuous streaming
- **Session-context-aware** — AI understands what device you're on and what it just output
- **Local ring buffer** — terminal content stays local; AI is only called on explicit triggers, not continuously streamed
- **Model tiering** — configurable per surface (ghost text, explain, full analysis)

### Code Editor
Everything from the CodeEdit foundation: syntax highlighting, code completion, project find and replace, snippets, integrated terminal, task running, debugging, git integration, extensions, and more.

## Architecture

NetSwift is built on a unified `TerminalConnection` protocol — local shell, SSH, and Telnet are all the same interface. The pipeline is:

```
Raw bytes → ANSI Highlight Preprocessor → Sanitization Processor → Display Gate / AI Observer / Session Logger → Terminal View
```

The sanitization layer uses Swift's type system to make it impossible for the AI observer to receive unsanitized bytes — not a policy, a compile-time guarantee.

See the full design spec at [`docs/superpowers/specs/2026-06-07-remote-terminal-design.md`](docs/superpowers/specs/2026-06-07-remote-terminal-design.md).

## Built On CodeEdit

NetSwift is a fork of [**CodeEdit**](https://github.com/CodeEditApp/CodeEdit), the open-source native macOS code editor built by the community. The entire editor foundation — syntax highlighting, file tree, source control integration, extensions, the terminal emulator, and more — comes from the CodeEdit project and its contributors.

We are grateful to the CodeEdit team and all contributors for building such a solid native macOS foundation to build on.

> If you are looking for a general-purpose code editor, please check out the original [CodeEdit project](https://github.com/CodeEditApp/CodeEdit).

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 16+ (to build from source)

## Building from Source

```bash
git clone https://github.com/netstacks/NetSwift.git
cd NetSwift
open CodeEdit.xcodeproj
```

Resolve Swift Package Manager dependencies in Xcode, then build and run.

## Dependencies

| Package | Purpose |
|---|---|
| [SwiftTerm](https://github.com/thecoolwinter/SwiftTerm) | Terminal emulator engine (custom fork) |
| [swift-nio-ssh](https://github.com/apple/swift-nio-ssh) | SSH protocol |
| [GRDB](https://github.com/groue/GRDB.swift) | Session persistence |
| [CodeEditSourceEditor](https://github.com/CodeEditApp/CodeEditSourceEditor) | Text editor engine |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Auto-updates |

## License

NetSwift is available under the MIT License. See [LICENSE.md](LICENSE.md) for details.

As a fork, this project incorporates code from [CodeEdit](https://github.com/CodeEditApp/CodeEdit), also MIT licensed. All original CodeEdit copyrights are retained.

---

<p align="center">Built on <a href="https://github.com/CodeEditApp/CodeEdit">CodeEdit</a> — the native macOS code editor built by the community.</p>
