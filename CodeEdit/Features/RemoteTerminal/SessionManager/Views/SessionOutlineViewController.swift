//
//  SessionOutlineViewController.swift
//  CodeEdit
//

import AppKit
import SwiftUI

/// Stable wrapper object for an outline item (NSOutlineView keys items by object identity).
final class SessionOutlineItem: NSObject {
    let nodeID: UUID
    let isFolder: Bool
    init(nodeID: UUID, isFolder: Bool) {
        self.nodeID = nodeID
        self.isFolder = isFolder
    }
}

/// Renders the session tree in an `NSOutlineView`.
final class SessionOutlineViewController: NSViewController {
    var scrollView: NSScrollView!
    var outlineView: NSOutlineView!

    weak var viewModel: SessionManagerViewModel?
    /// Set of session ids that currently have an open utility-area terminal tab.
    var connectedSessionIDs: Set<UUID> = [] {
        willSet { if newValue != connectedSessionIDs { outlineView?.reloadData() } }
    }
    /// Called when a session row is activated (double-click or Connect).
    var onConnect: ((UUID) -> Void)?
    /// Called when a session row is chosen for editing (Properties).
    var onEditSession: ((UUID) -> Void)?

    private var itemCache: [UUID: SessionOutlineItem] = [:]

    private func item(for nodeID: UUID, isFolder: Bool) -> SessionOutlineItem {
        if let cached = itemCache[nodeID] { return cached }
        let made = SessionOutlineItem(nodeID: nodeID, isFolder: isFolder)
        itemCache[nodeID] = made
        return made
    }

    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        view = scrollView

        outlineView = NSOutlineView()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = nil
        outlineView.rowHeight = 22
        outlineView.doubleAction = #selector(onItemDoubleClicked)
        outlineView.allowsMultipleSelection = true
        outlineView.setAccessibilityIdentifier("SessionManager")

        let column = NSTableColumn(identifier: .init(rawValue: "Cell"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        scrollView.documentView = outlineView
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.contentInsets = .init(top: 6, left: 0, bottom: 0, right: 0)
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
    }

    init() { super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        outlineView?.reloadData()
    }

    private func nodes(under item: Any?) -> [SessionTreeNode] {
        guard let viewModel else { return [] }
        if let outlineItem = item as? SessionOutlineItem {
            return viewModel.children(of: outlineItem.nodeID)
        }
        return viewModel.rootNodes
    }

    private func status(for sessionID: UUID) -> SessionConnectionStatus {
        connectedSessionIDs.contains(sessionID) ? .connected : .disconnected
    }

    @objc
    private func onItemDoubleClicked() {
        guard let outlineItem = outlineView.item(atRow: outlineView.clickedRow) as? SessionOutlineItem else {
            return
        }
        if outlineItem.isFolder {
            if outlineView.isItemExpanded(outlineItem) {
                outlineView.collapseItem(outlineItem)
            } else {
                outlineView.expandItem(outlineItem)
            }
        } else {
            onConnect?(outlineItem.nodeID)
        }
    }
}

// MARK: - Data source

extension SessionOutlineViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        nodes(under: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let node = nodes(under: item)[index]
        return self.item(for: node.id, isFolder: node.isFolder)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SessionOutlineItem)?.isFolder ?? false
    }
}

// MARK: - Delegate

extension SessionOutlineViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let outlineItem = item as? SessionOutlineItem, let viewModel else { return nil }
        let cell = NSTableCellView()
        let hosting: NSView
        if outlineItem.isFolder, let folder = viewModel.folder(outlineItem.nodeID) {
            hosting = NSHostingView(rootView: SessionFolderRowView(folder: folder))
        } else if let session = viewModel.session(outlineItem.nodeID) {
            hosting = NSHostingView(
                rootView: SessionRowView(session: session, status: status(for: session.id))
            )
        } else {
            return nil
        }
        hosting.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            hosting.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
