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
        // CETerminalView does not create the Terminal — must be done here, same as CELocalShellTerminalView.
        terminal = Terminal(delegate: self, options: TerminalOptions(scrollback: 2000))
        terminalDelegate = self

        pipeline = TerminalPipeline(connection: connection) { [weak self] bytes in
            // TerminalPipeline already dispatches to main; feed directly.
            self?.feed(byteArray: bytes)
        }

        // Wire window size provider so LocalShellConnection can query terminal dimensions.
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

// MARK: - Delegate Protocol

protocol CEConnectionTerminalViewDelegate: AnyObject {
    func sizeChanged(source: CEConnectionTerminalView, newCols: Int, newRows: Int)
    func setTerminalTitle(source: CEConnectionTerminalView, title: String)
    func hostCurrentDirectoryUpdate(source: CEConnectionTerminalView, directory: String?)
}
