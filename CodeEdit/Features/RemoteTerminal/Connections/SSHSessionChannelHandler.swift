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

    var cols: Int = 80
    var rows: Int = 24

    // MARK: - Init

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
    func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.readyContinuation = continuation
        }
    }

    /// Sends a window-size change notification to the SSH server.
    func sendResize(cols newCols: Int, rows newRows: Int) {
        guard let ctx = context else { return }
        let resize = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: newCols,
            terminalRowHeight: newRows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        ctx.triggerUserOutboundEvent(resize, promise: nil)
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
