//
//  NewTelnetConnectionView.swift
//  CodeEdit
//

import SwiftUI

/// A sheet for establishing a new Telnet connection.
/// Telnet auth is interactive (the server prompts in-band), so there is no password field.
/// Phase 3 (Session Manager) replaces this with the full session picker.
struct NewTelnetConnectionView: View {
    /// Called by Cancel and Connect to close the AppKit sheet.
    /// `@Environment(\.dismiss)` is a no-op when presented via NSHostingController + presentAsSheet.
    var onDismiss: () -> Void
    @EnvironmentObject private var utilityAreaViewModel: UtilityAreaViewModel

    @State private var hostname = ""
    @State private var port = "23"
    @State private var username = ""
    @State private var sessionName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Telnet Connection")
                .font(.headline)

            Group {
                LabeledContent("Session Name") {
                    TextField("My Switch", text: $sessionName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Hostname") {
                    TextField("192.168.1.1", text: $hostname)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Port") {
                    TextField("23", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
                LabeledContent("Username") {
                    TextField("optional", text: $username)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hostname.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func connect() {
        let name = sessionName.isEmpty ? hostname : sessionName
        let portInt = Int(port) ?? 23
        let session = RemoteSession(
            name: name,
            protocol: .telnet,
            hostname: hostname,
            port: portInt,
            username: username
        )
        utilityAreaViewModel.addTelnetTerminal(session: session)
        onDismiss()
    }
}
