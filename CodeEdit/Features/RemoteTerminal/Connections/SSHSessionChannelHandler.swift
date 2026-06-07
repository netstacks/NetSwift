//
//  SSHSessionChannelHandler.swift
//  CodeEdit
//
//  Created by Casey Davis on 2025-06-07.
//

import Foundation
import NIOCore
import NIOSSH

/// NIO channel handler for an SSH session channel.
///
/// Requests a PTY and shell, then bridges inbound data to an `AsyncStream`
/// that `SSHConnection` reads from on a Swift concurrency Task.
///
/// The real API uses separate `ChannelSuccessEvent` / `ChannelFailureEvent`
/// events (not a unified `RequestResponse` type), so we track state with
/// `pendingStage` to know which request a success/failure refers to.
final class SSHSessionChannelHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    // MARK: - AsyncStream bridge

    private var inboundContinuation: AsyncStream<ArraySlice<UInt8>>.Continuation?

    /// Consume this to receive all bytes sent by the SSH server.
    let inboundStream: AsyncStream<ArraySlice<UInt8>>

    // MARK: - Session setup state

    private enum PendingStage {
        case pty
        case shell
        case ready
    }

    private var pendingStage: PendingStage = .pty
    private var readyContinuation: CheckedContinuation<Void, Error>?

    private(set) var context: ChannelHandlerContext?

    /// Stored once in `channelActive`/`handlerAdded` (on the event loop).
    /// Safe to read from a Swift concurrency Task after that point because
    /// `Channel` itself is a reference type with its own internal thread-safety.
    private var channel: (any Channel)?

    // `cols` and `rows` are set at init time and are immutable afterward,
    // eliminating the cross-thread mutation window between construction and
    // the first event-loop callback.
    private let cols: Int
    private let rows: Int

    // MARK: - Init

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
        var continuation: AsyncStream<ArraySlice<UInt8>>.Continuation!
        inboundStream = AsyncStream { continuation = $0 }
        inboundContinuation = continuation
    }

    // MARK: - ChannelInboundHandler

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isActive {
            self.channel = context.channel
            requestPTY(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.context = context
        self.channel = context.channel
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
        inboundContinuation = nil
        readyContinuation?.resume(throwing: SSHConnectionError.connectionClosed)
        readyContinuation = nil
        self.context = nil
        self.channel = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        inboundContinuation?.finish()
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        context.close(promise: nil)
    }

    /// Handles `ChannelSuccessEvent` / `ChannelFailureEvent` for PTY and shell
    /// requests, and forwards unrecognised events down the pipeline.
    ///
    /// Note: the NIOSSH library fires `ChannelSuccessEvent` / `ChannelFailureEvent`
    /// (top-level types, not `SSHChannelRequestEvent.RequestResponse`) in response
    /// to `wantReply: true` outbound events.
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            handleSuccess(context: context)
        case is ChannelFailureEvent:
            handleFailure()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    // MARK: - Private helpers

    private func requestPTY(context: ChannelHandlerContext) {
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(ptyRequest, promise: nil)
    }

    private func handleSuccess(context: ChannelHandlerContext) {
        switch pendingStage {
        case .pty:
            // PTY granted — ask for a shell.
            pendingStage = .shell
            context.triggerUserOutboundEvent(
                SSHChannelRequestEvent.ShellRequest(wantReply: true),
                promise: nil
            )
        case .shell:
            pendingStage = .ready
            readyContinuation?.resume()
            readyContinuation = nil
        case .ready:
            break
        }
    }

    private func handleFailure() {
        switch pendingStage {
        case .pty:
            readyContinuation?.resume(throwing: SSHConnectionError.ptyFailed)
            readyContinuation = nil
        case .shell:
            readyContinuation?.resume(throwing: SSHConnectionError.shellFailed)
            readyContinuation = nil
        case .ready:
            break
        }
    }

    // MARK: - Public API

    /// Suspends until the PTY and shell are both granted by the server.
    ///
    /// All mutation of `readyContinuation` is marshalled onto the event loop so
    /// it races with neither the NIO callbacks nor other callers.
    func waitUntilReady() async throws {
        guard let channel else {
            throw SSHConnectionError.notConnected
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            channel.eventLoop.execute { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SSHConnectionError.notConnected)
                    return
                }
                guard channel.isActive else {
                    continuation.resume(throwing: SSHConnectionError.connectionClosed)
                    return
                }
                self.readyContinuation = continuation
            }
        }
    }

    /// Sends a window-size change notification to the SSH server.
    ///
    /// May be called from any thread; the actual NIO write is marshalled onto
    /// the event loop to satisfy NIO's thread-safety requirements.
    func sendResize(cols newCols: Int, rows newRows: Int) {
        guard let ctx = context else { return }
        ctx.eventLoop.execute {
            ctx.triggerUserOutboundEvent(
                SSHChannelRequestEvent.WindowChangeRequest(
                    terminalCharacterWidth: newCols,
                    terminalRowHeight: newRows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0
                ),
                promise: nil
            )
        }
    }
}

// MARK: - Errors

/// Errors that can occur during an SSH connection lifecycle.
enum SSHConnectionError: Error, LocalizedError {
    case ptyFailed
    case shellFailed
    case connectionClosed
    case notConnected
    case alreadyConnected

    var errorDescription: String? {
        switch self {
        case .ptyFailed:
            return "The server refused to allocate a pseudo-terminal."
        case .shellFailed:
            return "The server refused to open a shell channel."
        case .connectionClosed:
            return "The connection closed unexpectedly."
        case .notConnected:
            return "Not connected to a remote host."
        case .alreadyConnected:
            return "Already connected."
        }
    }
}
