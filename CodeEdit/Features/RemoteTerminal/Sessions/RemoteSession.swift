//
//  RemoteSession.swift
//  CodeEdit
//

import Foundation

/// The network protocol used for a remote connection.
enum ConnectionProtocol: String, Codable, CaseIterable {
    case ssh
    case telnet

    var defaultPort: Int {
        switch self {
        case .ssh:    return 22
        case .telnet: return 23
        }
    }
}

/// Authentication method for an SSH session.
enum AuthMethod: Codable, Equatable {
    case password
    case publicKey(keyID: UUID)
    case keyboardInteractive
}

/// Persisted configuration for a remote terminal session.
/// Phase 2 adds GRDB persistence; for now this is in-memory only.
struct RemoteSession: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var `protocol`: ConnectionProtocol
    var hostname: String
    var port: Int
    var username: String
    var authMethod: AuthMethod
    var notes: String
    var createdAt: Date
    var lastConnectedAt: Date?
    var folderID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        protocol connectionProtocol: ConnectionProtocol = .ssh,
        hostname: String,
        port: Int? = nil,
        username: String,
        authMethod: AuthMethod = .password,
        folderID: UUID? = nil,
        notes: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.protocol = connectionProtocol
        self.hostname = hostname
        self.port = port ?? connectionProtocol.defaultPort
        self.username = username
        self.authMethod = authMethod
        self.folderID = folderID
        self.notes = notes
        self.createdAt = createdAt
    }

    static func == (lhs: RemoteSession, rhs: RemoteSession) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - AuthMethod Codable

extension AuthMethod {
    private enum CodingKeys: String, CodingKey {
        case type, keyID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "password":
            self = .password
        case "publicKey":
            let keyID = try container.decode(UUID.self, forKey: .keyID)
            self = .publicKey(keyID: keyID)
        case "keyboardInteractive":
            self = .keyboardInteractive
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown auth method: \(type)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .password:
            try container.encode("password", forKey: .type)
        case .publicKey(let keyID):
            try container.encode("publicKey", forKey: .type)
            try container.encode(keyID, forKey: .keyID)
        case .keyboardInteractive:
            try container.encode("keyboardInteractive", forKey: .type)
        }
    }
}
