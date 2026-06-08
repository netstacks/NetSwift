//
//  SessionManagerNavigatorView.swift
//  CodeEdit
//

import SwiftUI

/// The Session Manager navigator tab: search field, toolbar, and the session tree.
struct SessionManagerNavigatorView: View {
    @EnvironmentObject private var workspace: WorkspaceDocument

    @StateObject private var viewModel = SessionManagerViewModel(
        store: SessionStore.shared ?? (try? SessionStore()) ?? SessionStore.inMemoryFallback
    )

    @State private var searchText = ""
    @State private var editingSession: RemoteSession?
    @State private var newFolderParent: UUID?

    /// Session ids that currently have an open utility-area terminal tab.
    private var connectedSessionIDs: Set<UUID> {
        guard let terminals = workspace.utilityAreaModel?.terminals else { return [] }
        return Set(terminals.compactMap { terminal in
            switch terminal.connectionType {
            case .ssh(let session, _): return session.id
            case .telnet(let session): return session.id
            case .localShell: return nil
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Sessions", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)

            Divider()

            Group {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    SessionOutlineView(
                        viewModel: viewModel,
                        connectedSessionIDs: connectedSessionIDs,
                        onConnect: connect,
                        onEditSession: { editingSession = viewModel.session($0) },
                        onDuplicate: { viewModel.duplicateSession($0) },
                        onDelete: { viewModel.deleteNode($0) },
                        onNewFolder: { newFolderParent = $0 }
                    )
                } else {
                    searchResults
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(item: $editingSession) { session in
            SessionPropertiesView(
                session: session,
                password: viewModel.password(for: session.id),
                onSave: { edited, password in
                    if viewModel.session(edited.id) == nil {
                        viewModel.createSession(edited, in: edited.folderID ?? SessionFolder.rootID)
                    } else {
                        viewModel.updateSession(edited)
                    }
                    viewModel.setPassword(password, for: edited.id)
                    editingSession = nil
                },
                onCancel: { editingSession = nil }
            )
        }
        .sheet(item: Binding(
            get: { newFolderParent.map { FolderParentBox(id: $0) } },
            set: { newFolderParent = $0?.id }
        )) { box in
            NewSessionFolderView(
                onCreate: { name in
                    viewModel.createFolder(name: name, in: box.id)
                    newFolderParent = nil
                },
                onCancel: { newFolderParent = nil }
            )
        }
    }

    private var searchResults: some View {
        List(viewModel.searchMatches(query: searchText), id: \.id) { session in
            SessionRowView(
                session: session,
                status: connectedSessionIDs.contains(session.id) ? .connected : .disconnected
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { connect(session.id) }
        }
        .listStyle(.sidebar)
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            Button { editingSession = newDraft() } label: { Image(systemName: "plus") }
                .help("New Session")
            Button { newFolderParent = SessionFolder.rootID } label: { Image(systemName: "folder.badge.plus") }
                .help("New Folder")
            Spacer()
            Button { openDetachedPanel() } label: { Image(systemName: "macwindow.on.rectangle") }
                .help("Detach Session Manager")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func newDraft() -> RemoteSession {
        RemoteSession(name: "New Session", hostname: "", username: "", folderID: SessionFolder.rootID)
    }

    private func connect(_ sessionID: UUID) {
        guard let utilityArea = workspace.utilityAreaModel else { return }
        viewModel.connect(sessionID, using: utilityArea)
        workspace.utilityAreaModel?.isCollapsed = false
    }

    private func openDetachedPanel() {
        SessionManagerPanelController.shared.show(viewModel: viewModel, workspace: workspace)
    }
}

/// Identifiable wrapper so a `UUID` parent can drive a `.sheet(item:)`.
private struct FolderParentBox: Identifiable { let id: UUID }
