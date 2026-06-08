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

    /// Reserved id for the hidden root folder whose `childIDs` define top-level ordering.
    /// Never shown in the UI.
    static let rootID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

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
