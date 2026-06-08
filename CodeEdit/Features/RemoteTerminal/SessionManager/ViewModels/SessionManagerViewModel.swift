//
//  SessionManagerViewModel.swift
//  CodeEdit
//

import Foundation
import Combine

/// Owns the in-memory session tree and writes through to ``SessionStore`` (config)
/// and ``SessionCredentialStore`` (passwords). Ordering lives in each folder's
/// `childIDs`; the hidden ``SessionFolder/rootID`` folder holds top-level ordering.
final class SessionManagerViewModel: ObservableObject {
    private let store: SessionStore
    private let credentials: SessionCredentialStore

    @Published private(set) var folders: [UUID: SessionFolder] = [:]
    @Published private(set) var sessions: [UUID: RemoteSession] = [:]
    /// Live search text; empty means show the full tree.
    @Published var searchQuery: String = ""

    init(store: SessionStore, credentials: SessionCredentialStore = SessionCredentialStore()) {
        self.store = store
        self.credentials = credentials
        reload()
    }

    // MARK: - Loading

    func reload() {
        folders = Dictionary(uniqueKeysWithValues: store.allFolders().map { ($0.id, $0) })
        sessions = Dictionary(uniqueKeysWithValues: store.allSessions().map { ($0.id, $0) })
        ensureRoot()
    }

    private func ensureRoot() {
        if folders[SessionFolder.rootID] == nil {
            let root = SessionFolder(id: SessionFolder.rootID, name: "")
            folders[root.id] = root
            store.saveFolder(root)
        }
    }

    // MARK: - Queries

    func folder(_ id: UUID) -> SessionFolder? { folders[id] }
    func session(_ id: UUID) -> RemoteSession? { sessions[id] }

    /// Ordered children of a folder, resolved from its `childIDs` (dangling ids skipped).
    func children(of parentID: UUID) -> [SessionTreeNode] {
        guard let parent = folders[parentID] else { return [] }
        return parent.childIDs.compactMap { childID in
            if let folder = folders[childID] { return .folder(folder) }
            if let session = sessions[childID] { return .session(session) }
            return nil
        }
    }

    var rootNodes: [SessionTreeNode] { children(of: SessionFolder.rootID) }

    // MARK: - Create

    @discardableResult
    func createSession(_ session: RemoteSession, in parentID: UUID) -> RemoteSession {
        var stored = session
        stored.folderID = parentID
        sessions[stored.id] = stored
        store.saveSession(stored)
        appendChild(stored.id, to: parentID)
        return stored
    }

    @discardableResult
    func createFolder(name: String, in parentID: UUID) -> SessionFolder {
        let folder = SessionFolder(name: name, parentID: parentID)
        folders[folder.id] = folder
        store.saveFolder(folder)
        appendChild(folder.id, to: parentID)
        return folder
    }

    private func appendChild(_ childID: UUID, to parentID: UUID) {
        ensureRoot()
        guard var parent = folders[parentID] else { return }
        if !parent.childIDs.contains(childID) {
            parent.childIDs.append(childID)
        }
        folders[parentID] = parent
        store.saveFolder(parent)
    }

    // MARK: - Update / rename

    func updateSession(_ session: RemoteSession) {
        guard sessions[session.id] != nil else { return }
        sessions[session.id] = session
        store.saveSession(session)
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard var folder = folders[id] else { return }
        folder.name = name
        folders[id] = folder
        store.saveFolder(folder)
    }

    // MARK: - Delete

    func deleteNode(_ id: UUID) {
        if let folder = folders[id], id != SessionFolder.rootID {
            for child in folder.childIDs { deleteNode(child) }
            folders[id] = nil
            store.deleteFolder(id: id)
            detachFromParent(id, parentID: folder.parentID)
        } else if let session = sessions[id] {
            sessions[id] = nil
            store.deleteSession(id: id)
            credentials.deletePassword(forSessionID: id)
            detachFromParent(id, parentID: session.folderID)
        }
    }

    private func detachFromParent(_ childID: UUID, parentID: UUID?) {
        let pid = parentID ?? SessionFolder.rootID
        guard var parent = folders[pid] else { return }
        parent.childIDs.removeAll { $0 == childID }
        folders[pid] = parent
        store.saveFolder(parent)
    }

    // MARK: - Credentials

    func setPassword(_ password: String?, for sessionID: UUID) {
        if let password, !password.isEmpty {
            credentials.setPassword(password, forSessionID: sessionID)
        } else {
            credentials.deletePassword(forSessionID: sessionID)
        }
    }

    // MARK: - Duplicate

    @discardableResult
    func duplicateSession(_ id: UUID) -> RemoteSession? {
        guard let original = sessions[id] else { return nil }
        let parentID = original.folderID ?? SessionFolder.rootID
        var copy = original
        copy.id = UUID()
        copy.name = original.name + " copy"
        copy.folderID = parentID
        sessions[copy.id] = copy
        store.saveSession(copy)
        // Insert immediately after the original in the parent's ordering.
        if var parent = folders[parentID], let index = parent.childIDs.firstIndex(of: id) {
            parent.childIDs.insert(copy.id, at: index + 1)
            folders[parentID] = parent
            store.saveFolder(parent)
        } else {
            appendChild(copy.id, to: parentID)
        }
        // Copy the stored password too, if any.
        if let password = credentials.password(forSessionID: id) {
            credentials.setPassword(password, forSessionID: copy.id)
        }
        return copy
    }

    // MARK: - Move / reorder

    /// Moves a node to `parentID` at the given index (append if `index` is nil).
    /// No-op for the root sentinel, unknown nodes, or moving a folder into its own subtree.
    func move(_ nodeID: UUID, to parentID: UUID, at index: Int?) {
        guard nodeID != SessionFolder.rootID, folders[parentID] != nil else { return }
        if folders[nodeID] != nil, nodeID == parentID || isDescendant(parentID, of: nodeID) {
            return
        }

        let oldParentID: UUID
        if let folder = folders[nodeID] {
            oldParentID = folder.parentID ?? SessionFolder.rootID
        } else if let session = sessions[nodeID] {
            oldParentID = session.folderID ?? SessionFolder.rootID
        } else {
            return
        }

        // Detach from old parent.
        if var oldParent = folders[oldParentID] {
            oldParent.childIDs.removeAll { $0 == nodeID }
            folders[oldParentID] = oldParent
            store.saveFolder(oldParent)
        }

        // Update the node's parent reference.
        if var folder = folders[nodeID] {
            folder.parentID = parentID
            folders[nodeID] = folder
            store.saveFolder(folder)
        } else if var session = sessions[nodeID] {
            session.folderID = parentID
            sessions[nodeID] = session
            store.saveSession(session)
        }

        // Insert into new parent at the requested position.
        guard var newParent = folders[parentID] else { return }
        newParent.childIDs.removeAll { $0 == nodeID }
        let clamped = max(0, min(index ?? newParent.childIDs.count, newParent.childIDs.count))
        newParent.childIDs.insert(nodeID, at: clamped)
        folders[parentID] = newParent
        store.saveFolder(newParent)
    }

    /// True if `candidate` is `ancestor` or lives anywhere beneath it.
    func isDescendant(_ candidate: UUID, of ancestor: UUID) -> Bool {
        var current: UUID? = candidate
        while let id = current {
            if id == ancestor { return true }
            current = folders[id]?.parentID
            if current == SessionFolder.rootID && ancestor != SessionFolder.rootID { return false }
        }
        return false
    }
}
