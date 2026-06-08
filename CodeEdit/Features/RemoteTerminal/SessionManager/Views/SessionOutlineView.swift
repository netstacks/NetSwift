//
//  SessionOutlineView.swift
//  CodeEdit
//

import SwiftUI

/// Bridges ``SessionOutlineViewController`` into SwiftUI.
struct SessionOutlineView: NSViewControllerRepresentable {
    @ObservedObject var viewModel: SessionManagerViewModel
    let connectedSessionIDs: Set<UUID>
    let onConnect: (UUID) -> Void
    let onEditSession: (UUID) -> Void
    let onDuplicate: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onNewFolder: (UUID) -> Void

    func makeNSViewController(context: Context) -> SessionOutlineViewController {
        let controller = SessionOutlineViewController()
        controller.viewModel = viewModel
        controller.onConnect = onConnect
        controller.onEditSession = onEditSession
        controller.onDuplicate = onDuplicate
        controller.onDelete = onDelete
        controller.onNewFolder = onNewFolder
        controller.connectedSessionIDs = connectedSessionIDs
        return controller
    }

    func updateNSViewController(_ controller: SessionOutlineViewController, context: Context) {
        controller.viewModel = viewModel
        controller.onConnect = onConnect
        controller.onEditSession = onEditSession
        controller.onDuplicate = onDuplicate
        controller.onDelete = onDelete
        controller.onNewFolder = onNewFolder
        controller.connectedSessionIDs = connectedSessionIDs
        controller.reload()
    }
}
