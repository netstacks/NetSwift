//
//  SessionManagerSettingsView.swift
//  CodeEdit
//

import SwiftUI

struct SessionManagerSettingsView: View {
    @AppSettings(\.sessionManager)
    var settings

    @State private var importMessage: String?

    var body: some View {
        SettingsForm {
            Section {
                Picker("Default Protocol", selection: $settings.defaultProtocol) {
                    Text("SSH").tag(ConnectionProtocol.ssh)
                    Text("Telnet").tag(ConnectionProtocol.telnet)
                }
                TextField("Default Username", text: $settings.defaultUsername)
                Picker("Default Auth Method", selection: $settings.defaultAuthMethod) {
                    Text("Password").tag(AuthMethodKind.password)
                    Text("Public Key").tag(AuthMethodKind.publicKey)
                    Text("Keyboard Interactive").tag(AuthMethodKind.keyboardInteractive)
                }
            }
            Section("SecureCRT Import") {
                Button("Import SecureCRT Sessions…") { runImport() }
                if let importMessage {
                    Text(importMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func runImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose your SecureCRT \"Sessions\" folder"
        guard panel.runModal() == .OK, let url = panel.url, let store = SessionStore.shared else {
            return
        }
        do {
            let result = try SecureCRTImporter.importTree(from: url, into: SessionFolder.rootID)
            for folder in result.folders { store.saveFolder(folder) }
            for session in result.sessions { store.saveSession(session) }
            var root = store.allFolders().first { $0.id == SessionFolder.rootID }
                ?? SessionFolder(id: SessionFolder.rootID, name: "")
            let topFolderIDs = result.folders.filter { $0.parentID == SessionFolder.rootID }.map(\.id)
            let topSessionIDs = result.sessions.filter { $0.folderID == SessionFolder.rootID }.map(\.id)
            for childID in topFolderIDs + topSessionIDs where !root.childIDs.contains(childID) {
                root.childIDs.append(childID)
            }
            store.saveFolder(root)
            importMessage = "Imported \(result.sessions.count) sessions, \(result.folders.count) folders."
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}
