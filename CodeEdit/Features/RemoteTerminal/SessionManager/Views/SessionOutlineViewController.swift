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
    var onDuplicate: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onNewFolder: ((UUID) -> Void)?   // parameter: parent folder id for the new folder

    private var itemCache: [UUID: SessionOutlineItem] = [:]

    static let nodePasteboardType = NSPasteboard.PasteboardType("app.codeedit.session-node")

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
        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu
        outlineView.allowsMultipleSelection = true
        outlineView.setAccessibilityIdentifier("SessionManager")

        let column = NSTableColumn(identifier: .init(rawValue: "Cell"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.registerForDraggedTypes([Self.nodePasteboardType])

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

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let outlineItem = item as? SessionOutlineItem else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(outlineItem.nodeID.uuidString, forType: Self.nodePasteboardType)
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let draggedID = draggedNodeID(from: info) else { return [] }
        let targetParentID = (item as? SessionOutlineItem)?.nodeID ?? SessionFolder.rootID
        // Only drop into folders (or root); reject dropping a folder into its own subtree.
        if let targetItem = item as? SessionOutlineItem, !targetItem.isFolder { return [] }
        if let viewModel, viewModel.folder(draggedID) != nil,
           draggedID == targetParentID || viewModel.isDescendant(targetParentID, of: draggedID) {
            return []
        }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let draggedID = draggedNodeID(from: info), let viewModel else { return false }
        let targetParentID = (item as? SessionOutlineItem)?.nodeID ?? SessionFolder.rootID
        viewModel.move(draggedID, to: targetParentID, at: index == NSOutlineViewDropOnItemIndex ? nil : index)
        outlineView.reloadData()
        if let parentItem = item as? SessionOutlineItem { outlineView.expandItem(parentItem) }
        return true
    }

    private func draggedNodeID(from info: NSDraggingInfo) -> UUID? {
        guard let string = info.draggingPasteboard.string(forType: Self.nodePasteboardType) else { return nil }
        return UUID(uuidString: string)
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

// MARK: - Context menu

extension SessionOutlineViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outlineView.clickedRow
        guard row >= 0, let outlineItem = outlineView.item(atRow: row) as? SessionOutlineItem else {
            addItem(to: menu, title: "New Folder") { [weak self] in self?.onNewFolder?(SessionFolder.rootID) }
            return
        }

        if outlineItem.isFolder {
            addItem(to: menu, title: "New Folder") { [weak self] in self?.onNewFolder?(outlineItem.nodeID) }
            menu.addItem(.separator())
            addItem(to: menu, title: "Delete") { [weak self] in self?.onDelete?(outlineItem.nodeID) }
        } else {
            addItem(to: menu, title: "Connect") { [weak self] in self?.onConnect?(outlineItem.nodeID) }
            addItem(to: menu, title: "Open in New Tab") { [weak self] in self?.onConnect?(outlineItem.nodeID) }
            menu.addItem(.separator())
            addItem(to: menu, title: "Duplicate") { [weak self] in self?.onDuplicate?(outlineItem.nodeID) }
            addItem(to: menu, title: "Properties…") { [weak self] in self?.onEditSession?(outlineItem.nodeID) }
            menu.addItem(.separator())
            addItem(to: menu, title: "Delete") { [weak self] in self?.onDelete?(outlineItem.nodeID) }
        }
    }

    private func addItem(to menu: NSMenu, title: String, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(menuActionInvoked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuActionBox(action: action)
        menu.addItem(item)
    }

    @objc
    private func menuActionInvoked(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuActionBox)?.action()
    }
}

/// Boxes a closure so it can ride on `NSMenuItem.representedObject`.
private final class MenuActionBox {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
}
