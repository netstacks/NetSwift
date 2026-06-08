//
//  SessionManagerNavigatorView.swift
//  CodeEdit
//

import AppKit
import SwiftUI

/// The Session Manager navigator tab: search field, toolbar, and the session tree.
struct SessionManagerNavigatorView: View {
    @EnvironmentObject private var workspace: WorkspaceDocument

    @AppSettings(\.sessionManager)
    var sessionDefaults

    @StateObject private var viewModel = SessionManagerViewModel(
        store: SessionStore.shared ?? (try? SessionStore()) ?? SessionStore.inMemoryFallback
    )

    @State private var searchText = ""

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
                        onEditSession: { sessionID in
                            if let session = viewModel.session(sessionID) { editSession(session) }
                        },
                        onDuplicate: { viewModel.duplicateSession($0) },
                        onDelete: { viewModel.deleteNode($0) },
                        onNewFolder: { newFolder(in: $0) }
                    )
                } else {
                    searchResults
                }
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear {
            // Deferred so the model mutation does not publish during the view update.
            DispatchQueue.main.async { viewModel.reload() }
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
            Button { editSession(newDraft()) } label: { Image(systemName: "plus") }
                .help("New Session")
            Button { newFolder(in: SessionFolder.rootID) } label: { Image(systemName: "folder.badge.plus") }
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
        RemoteSession(
            name: "New Session",
            protocol: sessionDefaults.defaultProtocol,
            hostname: "",
            username: sessionDefaults.defaultUsername,
            authMethod: sessionDefaults.defaultAuthMethod.authMethod,
            folderID: SessionFolder.rootID
        )
    }

    private func connect(_ sessionID: UUID) {
        guard let utilityArea = workspace.utilityAreaModel else { return }
        viewModel.connect(sessionID, using: utilityArea)
        workspace.utilityAreaModel?.isCollapsed = false
    }

    private func openDetachedPanel() {
        SessionManagerPanelController.shared.show(viewModel: viewModel, workspace: workspace)
    }

    // MARK: - AppKit-hosted dialogs

    /// Presents the session properties editor as an AppKit sheet on the workspace window.
    /// SwiftUI `.sheet` is unreliable inside this AppKit-hosted navigator (the same reason
    /// the SSH/Telnet "New Connection" dialogs use `presentAsSheet`), so dialogs go through AppKit.
    private func editSession(_ session: RemoteSession) {
        presentDialog(size: NSSize(width: 440, height: 700)) { dismiss in
            SessionPropertiesView(
                session: session,
                password: viewModel.password(for: session.id),
                onSave: { edited, password in
                    print("[SM] onSave invoked — existing=\(viewModel.session(edited.id) != nil)")
                    if viewModel.session(edited.id) == nil {
                        viewModel.createSession(edited, in: edited.folderID ?? SessionFolder.rootID)
                    } else {
                        viewModel.updateSession(edited)
                    }
                    viewModel.setPassword(password, for: edited.id)
                    print("[SM] after save — rootNodes=\(viewModel.rootNodes.count)")
                    dismiss()
                    print("[SM] dismiss() returned")
                },
                onCancel: dismiss
            )
        }
    }

    private func newFolder(in parentID: UUID) {
        presentDialog(size: NSSize(width: 300, height: 170)) { dismiss in
            NewSessionFolderView(
                onCreate: { name in
                    viewModel.createFolder(name: name, in: parentID)
                    dismiss()
                },
                onCancel: dismiss
            )
        }
    }

    /// Presents `content` as an AppKit sheet on the workspace window, passing a `dismiss`
    /// closure that closes it. Mirrors `CodeEditWindowController.openSSHConnectionSheet`.
    private func presentDialog<Content: View>(
        size: NSSize,
        @ViewBuilder content: (@escaping () -> Void) -> Content
    ) {
        guard let presenter = workspace.windowControllers.first?.contentViewController else {
            print("[SM] presentDialog: NO presenter (windowControllers=\(workspace.windowControllers.count))")
            return
        }
        print("[SM] presentDialog: presenting AppKit sheet")
        var hosting: NSHostingController<AnyView>?
        let dismiss: () -> Void = { [weak presenter] in
            guard let controller = hosting else { return }
            presenter?.dismiss(controller)
            hosting = nil
        }
        hosting = NSHostingController(rootView: AnyView(content(dismiss)))
        // Fixed size on purpose: `.sizingOptions = [.preferredContentSize]` makes the
        // hosting controller resize the sheet on every SwiftUI re-measure, which loops the
        // window's Update-Constraints pass and crashes. Mirrors the SSH/Telnet dialogs.
        hosting?.preferredContentSize = size
        if let hosting {
            presenter.presentAsSheet(hosting)
        }
    }
}
