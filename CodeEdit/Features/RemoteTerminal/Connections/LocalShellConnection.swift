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

        isConnected = true
        process.startProcess(
            executable: shellPath,
            args: shellArgs,
            environment: env,
            execName: resolvedShell.rawValue,
            currentDirectory: workspaceURL?.absolutePath
        )
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
        if let shellType = shell {
            return (shellType, shellType.defaultPath)
        }
        switch setting {
        case .system:
            let path = Shell.autoDetectDefaultShell()
            guard let type = Shell(rawValue: NSString(string: path).lastPathComponent) else {
                return nil
            }
            return (type, path)
        case .bash:
            return (.bash, Shell.bash.defaultPath)
        case .zsh:
            return (.zsh, Shell.zsh.defaultPath)
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
