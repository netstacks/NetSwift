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
