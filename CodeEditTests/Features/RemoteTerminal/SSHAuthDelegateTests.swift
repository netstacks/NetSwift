//
//  SSHAuthDelegateTests.swift
//  CodeEditTests
//

import XCTest
import NIOCore
import NIOPosix
import NIOSSH
import Crypto
@testable import CodeEdit

final class SSHAuthDelegateTests: XCTestCase {

    func test_passwordDelegate_succeedsWithPasswordMethod() {
        let delegate = PasswordAuthDelegate(username: "admin", password: "secret")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)

        delegate.nextAuthenticationType(
            availableMethods: .password,
            nextChallengePromise: promise
        )

        // Swift 5.7+ flattens try? on Optional-returning functions:
        // try? futureResult.wait() yields NIOSSHUserAuthenticationOffer?
        let authOffer = try? promise.futureResult.wait()
        XCTAssertNotNil(authOffer)
        if case .password(let passwordOffer) = authOffer?.offer {
            XCTAssertEqual(passwordOffer.password, "secret")
        } else {
            XCTFail("Expected password offer")
        }
    }

    func test_passwordDelegate_succeedsNilWhenMethodUnavailable() {
        let delegate = PasswordAuthDelegate(username: "usr", password: "pwd")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)

        delegate.nextAuthenticationType(
            availableMethods: .publicKey,  // password not available
            nextChallengePromise: promise
        )

        // When the promise succeeds with nil, try? flatMap collapses to nil
        let authOffer = try? promise.futureResult.wait()
        XCTAssertNil(authOffer)
    }

    func test_acceptAllHostKeysDelegate_succeedsImmediately() throws {
        let delegate = AcceptAllHostKeysDelegate()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()

        // Generate an ephemeral key to obtain a real NIOSSHPublicKey.
        let privateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let hostKey = privateKey.publicKey

        let promise = loop.makePromise(of: Void.self)
        delegate.validateHostKey(hostKey: hostKey, validationCompletePromise: promise)
        XCTAssertNoThrow(try promise.futureResult.wait())
    }

    func test_keyboardInteractiveDelegate_succeedsWithNoneOffer() {
        let delegate = KeyboardInteractiveAuthDelegate(username: "admin")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)

        delegate.nextAuthenticationType(
            availableMethods: .all,
            nextChallengePromise: promise
        )

        let authOffer = try? promise.futureResult.wait()
        XCTAssertNotNil(authOffer)
        // Must match against the qualified enum case to avoid matching Optional.none
        if let resolved = authOffer {
            // resolved is NIOSSHUserAuthenticationOffer (non-optional)
            if case .none = resolved.offer {
                // Expected: keyboard-interactive starts with a .none offer
            } else {
                XCTFail("Expected NIOSSHUserAuthenticationOffer.Offer.none, got \(resolved.offer)")
            }
        } else {
            XCTFail("Expected a non-nil NIOSSHUserAuthenticationOffer")
        }
    }

    func test_keyboardInteractiveDelegate_succeedsNilWhenNoMethodsAvailable() {
        let delegate = KeyboardInteractiveAuthDelegate(username: "admin")
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)

        // swift-nio-ssh has no .keyboardInteractive OptionSet member, so we check
        // that an empty available-methods set (rawValue 0) causes the delegate to
        // yield nil rather than attempting a none offer.
        delegate.nextAuthenticationType(
            availableMethods: .init(rawValue: 0),
            nextChallengePromise: promise
        )

        let authOffer = try? promise.futureResult.wait()
        XCTAssertNil(authOffer)
    }

    func test_publicKeyDelegate_succeedsNilWhenMethodUnavailable() {
        let privateKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let delegate = PublicKeyAuthDelegate(username: "usr", privateKey: privateKey)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let loop = group.next()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)

        delegate.nextAuthenticationType(availableMethods: .password, nextChallengePromise: promise)
        let authOffer = try? promise.futureResult.wait()
        XCTAssertNil(authOffer)
    }
}
