//
//  SessionCredentialStore.swift
//  CodeEdit
//

import Foundation

/// Stores remote-session passwords in the macOS Keychain via ``CodeEditKeychain``.
/// Credentials are keyed by the session's UUID under a dedicated key prefix so they
/// never touch the session database on disk.
struct SessionCredentialStore {
    private let keychain: CodeEditKeychain

    init(keychain: CodeEditKeychain = CodeEditKeychain(keyPrefix: "session-credential-")) {
        self.keychain = keychain
    }

    /// Stores (or overwrites) the password for a session.
    func setPassword(_ password: String, forSessionID id: UUID) {
        keychain.set(password, forKey: id.uuidString)
    }

    /// Returns the stored password for a session, or `nil` if none is saved.
    func password(forSessionID id: UUID) -> String? {
        keychain.get(id.uuidString)
    }

    /// Removes any stored password for a session.
    func deletePassword(forSessionID id: UUID) {
        keychain.delete(id.uuidString)
    }
}
