//
//  UtilityAreaTerminal.swift
//  CodeEdit
//
//  Created by Austin Condiff on 5/25/23.
//

import SwiftUI
import Cocoa

// MARK: - SSH terminal cache

/// Caches ``CEConnectionTerminalView`` instances keyed by terminal UUID so that
/// switching away from an SSH tab and back does not disconnect the session.
private final class SSHTerminalCache: ObservableObject {
    private var views: [UUID: CEConnectionTerminalView] = [:]

    /// Returns an existing cached view or creates, connects, and caches a new one.
    func view(
        for terminal: UtilityAreaTerminal,
        session: RemoteSession,
        password: String?
    ) -> CEConnectionTerminalView {
        if let existing = views[terminal.id] {
            return existing
        }
        let connection = SSHConnection(session: session, password: password)
        let terminalView = CEConnectionTerminalView(connection: connection)
        views[terminal.id] = terminalView
        Task {
            do {
                try await connection.connect()
            } catch {
                let message = "\r\nConnection failed: \(error.localizedDescription)\r\n"
                await MainActor.run {
                    terminalView.feed(byteArray: ArraySlice(Array(message.utf8)))
                }
            }
        }
        return terminalView
    }

    /// Removes the cached view for a terminal, allowing it to be deallocated.
    func removeView(for id: UUID) {
        views[id] = nil
    }
}

// MARK: - NSViewRepresentable wrapper for CEConnectionTerminalView

/// Wraps a ``CEConnectionTerminalView`` (an ``NSView`` subclass) for use in SwiftUI.
private struct SSHTerminalNSView: NSViewRepresentable {
    let terminalView: CEConnectionTerminalView

    func makeNSView(context: Context) -> CEConnectionTerminalView {
        terminalView
    }

    func updateNSView(_ nsView: CEConnectionTerminalView, context: Context) {}
}

// MARK: - Main view

struct UtilityAreaTerminalView: View {
    @AppSettings(\.theme.matchAppearance)
    private var matchAppearance
    @AppSettings(\.terminal.darkAppearance)
    private var darkAppearance
    @AppSettings(\.theme.useThemeBackground)
    private var useThemeBackground
    @AppSettings(\.textEditing.font)
    private var textEditingFont
    @AppSettings(\.terminal.font)
    private var terminalFont
    @AppSettings(\.terminal.useTextEditorFont)
    private var useTextEditorFont

    @Environment(\.colorScheme)
    private var colorScheme

    @EnvironmentObject private var workspace: WorkspaceDocument

    @EnvironmentObject private var utilityAreaViewModel: UtilityAreaViewModel

    @State private var sidebarIsCollapsed = false

    @StateObject private var themeModel: ThemeModel = .shared

    @StateObject private var sshCache = SSHTerminalCache()

    @State private var isMenuVisible = false

    @State private var popoverSource: CGRect = .zero

    var font: NSFont {
        useTextEditorFont == true ? textEditingFont.current : terminalFont.current
    }

    /// Returns the `background` color of the selected theme
    private var backgroundColor: NSColor {
        if let selectedTheme = matchAppearance && darkAppearance
            ? themeModel.selectedDarkTheme
            : themeModel.selectedTheme,
           let index = themeModel.themes.firstIndex(of: selectedTheme) {
            return NSColor(themeModel.themes[index].terminal.background.swiftColor)
        }
        return .windowBackgroundColor
    }

    /// Decides the color scheme used in the terminal.
    ///
    /// Decision list:
    /// - If there is no selection, use the system color scheme ``UtilityAreaTerminalView/colorScheme``
    /// - If the match appearance and dark appearance settings are true, return dark if the selected dark theme is dark.
    /// - Otherwise, return dark if the selected theme is dark.
    private var terminalColorScheme: ColorScheme {
        return if utilityAreaViewModel.selectedTerminals.isEmpty {
            colorScheme
        } else if matchAppearance && darkAppearance {
            themeModel.selectedDarkTheme?.appearance == .dark ? .dark : .light
        } else {
            themeModel.selectedTheme?.appearance == .dark ? .dark : .light
        }
    }

    /// Finds the selected terminal.
    /// - Returns: The selected terminal.
    private func getSelectedTerminal() -> UtilityAreaTerminal? {
        guard let selectedTerminalID = utilityAreaViewModel.selectedTerminals.first else {
            return nil
        }
        return utilityAreaViewModel.terminals.first(where: { $0.id == selectedTerminalID })
    }

    /// Estimate the font's height for keeping the terminal aligned with the bottom.
    /// - Parameter nsFont: The font being used in the terminal.
    /// - Returns: The height in pixels of the font.
    func fontTotalHeight(nsFont: NSFont) -> CGFloat {
        let ctFont = nsFont as CTFont
        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        return ascent + descent + leading
    }

    var body: some View {
        UtilityAreaTabView(model: utilityAreaViewModel.tabViewModel) { tabState in
            ZStack {
                // Keeps the sidebar from changing sizes because TerminalEmulatorView takes a µs to load in
                HStack { Spacer() }

                if let selectedTerminal = getSelectedTerminal() {
                    GeometryReader { geometry in
                        let containerHeight = geometry.size.height
                        let totalFontHeight = fontTotalHeight(nsFont: font).rounded(.up)
                        let constrainedHeight = containerHeight - containerHeight.truncatingRemainder(
                            dividingBy: totalFontHeight
                        )
                        VStack(spacing: 0) {
                            Spacer(minLength: 0).frame(minHeight: 0)
                            switch selectedTerminal.connectionType {
                            case .localShell:
                                TerminalEmulatorView(
                                    url: selectedTerminal.url,
                                    terminalID: selectedTerminal.id,
                                    shellType: selectedTerminal.shell,
                                    onTitleChange: { [weak selectedTerminal] newTitle in
                                        guard let id = selectedTerminal?.id else { return }
                                        // This can be called whenever, even in a view update so it needs to be dispatched.
                                        DispatchQueue.main.async { [weak utilityAreaViewModel] in
                                            utilityAreaViewModel?.updateTerminal(id, title: newTitle)
                                        }
                                    }
                                )
                                .frame(height: max(0, constrainedHeight - 1))
                                .id(selectedTerminal.id)
                                .accessibilityIdentifier("terminal")
                            case let .ssh(session, password):
                                SSHTerminalNSView(
                                    terminalView: sshCache.view(
                                        for: selectedTerminal,
                                        session: session,
                                        password: password
                                    )
                                )
                                .frame(height: max(0, constrainedHeight - 1))
                                .id(selectedTerminal.id)
                                .accessibilityIdentifier("terminal")
                            }
                        }
                    }
                } else {
                    CEContentUnavailableView("No Selection")
                }
            }
            .padding(.horizontal, 10)
            .paneToolbar {
                PaneToolbarSection {
                    UtilityAreaTerminalPicker(
                        selectedIDs: $utilityAreaViewModel.selectedTerminals,
                        terminals: utilityAreaViewModel.terminals
                    )
                    .opacity(tabState.leadingSidebarIsCollapsed ? 1 : 0)
                }
                Spacer()
                PaneToolbarSection {
                    Button {
                        guard let terminal = getSelectedTerminal() else {
                            return
                        }
                        utilityAreaViewModel.replaceTerminal(terminal.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Reset the terminal")
                    .disabled(getSelectedTerminal() == nil)
                    Button {
                        // split terminal
                    } label: {
                        Image(systemName: "square.split.2x1")
                    }
                    .help("Implementation Needed")
                    .disabled(true)
                }
            }
            .background {
                backgroundEffectView
            }
            .colorScheme(terminalColorScheme)
        } leadingSidebar: { _ in
            UtilityAreaTerminalSidebar()
        }
        .onAppear {
            guard let workspaceURL = workspace.fileURL else {
                assertionFailure("Workspace does not have a file URL.")
                return
            }
            utilityAreaViewModel.initializeTerminals(workspaceURL: workspaceURL)
        }
        .onChange(of: utilityAreaViewModel.terminals) { oldTerminals, newTerminals in
            // Remove cached SSH views for terminals that no longer exist.
            let activeIDs = Set(newTerminals.map(\.id))
            for oldTerminal in oldTerminals where !activeIDs.contains(oldTerminal.id) {
                sshCache.removeView(for: oldTerminal.id)
            }
        }
        .accessibilityIdentifier("terminal-area")
    }

    @ViewBuilder var backgroundEffectView: some View {
        if utilityAreaViewModel.selectedTerminals.isEmpty {
            EffectView(.contentBackground)
        } else if useThemeBackground {
            Color(nsColor: backgroundColor)
        } else {
            if colorScheme == .dark {
                EffectView(.underPageBackground)
            } else {
                EffectView(.contentBackground)
            }
        }
    }
}
