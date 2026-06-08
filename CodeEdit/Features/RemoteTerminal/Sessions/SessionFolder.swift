//
//  SessionFolder.swift
//  CodeEdit
//

import Foundation

/// A folder in the remote-session tree. Holds an ordered list of child IDs,
/// which may reference either nested ``SessionFolder``s or ``RemoteSession``s.
struct SessionFolder: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var parentID: UUID?
    var childIDs: [UUID]

    init(
        id: UUID = UUID(),
        name: String,
        parentID: UUID? = nil,
        childIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.childIDs = childIDs
    }
}
