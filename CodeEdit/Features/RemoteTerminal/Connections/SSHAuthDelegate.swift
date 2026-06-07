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
/// Set `responseProvider` before connecting to receive and respond to prompts.
///
/// Note: swift-nio-ssh does not expose a `.keyboardInteractive` method constant on
/// `NIOSSHAvailableUserAuthenticationMethods`. Keyboard-interactive authentication is
/// initiated by sending a `.none` offer; the server then sends prompts via
/// SSH_MSG_USERAUTH_INFO_REQUEST messages. This delegate triggers that flow whenever
/// the server advertises any methods (i.e., the available set is non-empty).
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
        // swift-nio-ssh has no `.keyboardInteractive` OptionSet member; the library
        // only tracks publicKey, password, and hostBased. Keyboard-interactive starts
        // with a `.none` offer when the server advertises any methods.
        guard availableMethods != .init(rawValue: 0) else {
            nextChallengePromise.succeed(nil)
            return
        }
        // Keyboard-interactive starts with a none offer; the server sends prompts via
        // SSH_MSG_USERAUTH_INFO_REQUEST.
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
