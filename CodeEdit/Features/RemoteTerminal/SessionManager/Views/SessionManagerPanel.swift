//
//  SessionManagerPanel.swift
//  CodeEdit
//

import AppKit
import SwiftUI

/// Manages a single shared floating Session Manager panel.
final class SessionManagerPanelController {
    static let shared = SessionManagerPanelController()
    private var panel: NSPanel?

    func show(viewModel: SessionManagerViewModel, workspace: WorkspaceDocument) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let content = SessionManagerPanelView(viewModel: viewModel)
            .environmentObject(workspace)

        let hosting = NSHostingController(rootView: content)
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Sessions"
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.hidesOnDeactivate = false
        newPanel.contentViewController = hosting
        newPanel.center()
        newPanel.isReleasedWhenClosed = false
        newPanel.makeKeyAndOrderFront(nil)
        self.panel = newPanel
    }
}

/// The panel's body: the same tree, minus the detach button.
private struct SessionManagerPanelView: View {
    @ObservedObject var viewModel: SessionManagerViewModel
    @EnvironmentObject private var workspace: WorkspaceDocument

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
        SessionOutlineView(
            viewModel: viewModel,
            connectedSessionIDs: connectedSessionIDs,
            onConnect: { sessionID in
                guard let utilityArea = workspace.utilityAreaModel else { return }
                viewModel.connect(sessionID, using: utilityArea)
                workspace.utilityAreaModel?.isCollapsed = false
            },
            onEditSession: { _ in },
            onDuplicate: { viewModel.duplicateSession($0) },
            onDelete: { viewModel.deleteNode($0) },
            onNewFolder: { viewModel.createFolder(name: "New Folder", in: $0) }
        )
        .frame(minWidth: 280, minHeight: 360)
    }
}
