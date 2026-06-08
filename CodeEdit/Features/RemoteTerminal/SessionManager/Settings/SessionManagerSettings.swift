//
//  SessionManagerSettings.swift
//  CodeEdit
//

import Foundation

/// Top-level alias so the nested settings group can be referenced unqualified,
/// matching how `SettingsData.SessionManagerSettings` is used across the app.
typealias SessionManagerSettings = SettingsData.SessionManagerSettings

extension SettingsData {
    /// Defaults applied when creating new remote sessions.
    struct SessionManagerSettings: Codable, Hashable, SearchableSettingsPage {
        /// Default protocol for new sessions.
        var defaultProtocol: ConnectionProtocol = .ssh

        /// Default username pre-filled in new sessions.
        var defaultUsername: String = ""

        /// Default authentication method for new SSH sessions.
        var defaultAuthMethod: AuthMethodKind = .password

        /// The search keys
        var searchKeys: [String] {
            [
                "Session Manager",
                "Default Protocol",
                "Default Username",
                "Default Auth Method",
                "SecureCRT Import"
            ]
            .map { NSLocalizedString($0, comment: "") }
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.defaultProtocol = try container.decodeIfPresent(
                ConnectionProtocol.self, forKey: .defaultProtocol
            ) ?? .ssh
            self.defaultUsername = try container.decodeIfPresent(String.self, forKey: .defaultUsername) ?? ""
            self.defaultAuthMethod = try container.decodeIfPresent(
                AuthMethodKind.self, forKey: .defaultAuthMethod
            ) ?? .password
        }
    }
}
