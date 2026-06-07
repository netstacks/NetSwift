//
//  SSHConnection.swift
//  CodeEdit
//

import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// SSH connection conforming to `TerminalConnection`.
///
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

    /// The TCP transport channel (outer NIO channel carrying the SSH protocol).
    private var transportChannel: (any Channel)?
    /// The NIOSSHHandler stored during channelInitializer so we can call createChannel.
    private var sshHandler: NIOSSHHandler?
    /// The SSH session channel handler (inner child channel).
    private var sessionHandler: SSHSessionChannelHandler?
    /// The Swift concurrency Task that forwards bytes from the inbound stream.
    private var dataTask: Task<Void, Never>?

    /// Shared event loop group — reused across all SSH connections.
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

        // Capture the NIOSSHHandler during channel initialization so we can call
        // createChannel on it from an async context without needing pipeline.handler(type:).
        var capturedSSHHandler: NIOSSHHandler?

        let transportChannel = try await ClientBootstrap(group: Self.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let sync = channel.pipeline.syncOperations
                    let handler = NIOSSHHandler(
                        role: .client(clientConfig),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    capturedSSHHandler = handler
                    try sync.addHandler(handler)
                }
            }
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                value: 1
            )
            .channelOption(
                ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY),
                value: 1
            )
            .connect(host: session.hostname, port: session.port)
            .get()

        self.transportChannel = transportChannel

        guard let sshHandler = capturedSSHHandler else {
            transportChannel.close(promise: nil)
            throw SSHConnectionError.notConnected
        }
        self.sshHandler = sshHandler

        // Open an SSH session channel and attach our handler.
        let channelPromise = transportChannel.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(channelPromise) { childChannel, channelType in
            guard channelType == .session else {
                return childChannel.close()
            }
            return childChannel.eventLoop.makeCompletedFuture {
                try childChannel.pipeline.syncOperations.addHandler(sessionHandler)
            }
        }
        _ = try await channelPromise.futureResult.get()

        // Wait for PTY + shell to be granted before declaring connected.
        try await sessionHandler.waitUntilReady()
        isConnected = true

        // Forward bytes from the async stream to onDataReceived.
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
        sshHandler = nil
        sessionHandler = nil
        isConnected = false
    }

    func send(data: ArraySlice<UInt8>) {
        guard isConnected, let handler = sessionHandler, let ctx = handler.context else { return }
        var buffer = ctx.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        ctx.eventLoop.execute {
            // NIOAny wraps any NIO message type for pipeline writes.
            ctx.writeAndFlush(NIOAny(channelData), promise: nil)
        }
    }

    func resize(cols: Int, rows: Int) {
        guard isConnected else { return }
        sessionHandler?.sendResize(cols: cols, rows: rows)
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
            // Fall back to password if no key was provided.
            return PasswordAuthDelegate(username: session.username, password: password ?? "")
        case .keyboardInteractive:
            return KeyboardInteractiveAuthDelegate(
                username: session.username,
                responseProvider: keyboardInteractiveResponseProvider ?? { _ in "" }
            )
        }
    }
}
