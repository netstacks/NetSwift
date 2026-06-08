//
//  SessionTreeNode.swift
//  CodeEdit
//

import Foundation

/// A node in the session tree: either a folder or a session.
enum SessionTreeNode: Identifiable, Equatable {
    case folder(SessionFolder)
    case session(RemoteSession)

    var id: UUID {
        switch self {
        case .folder(let folder): return folder.id
        case .session(let session): return session.id
        }
    }

    var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    var name: String {
        switch self {
        case .folder(let folder): return folder.name
        case .session(let session): return session.name
        }
    }
}
