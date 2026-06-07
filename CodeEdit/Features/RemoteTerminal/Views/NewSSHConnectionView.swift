//
//  NewSSHConnectionView.swift
//  CodeEdit
//

import SwiftUI

/// A sheet for establishing a new SSH connection.
/// Phase 3 (Session Manager) replaces this with the full session picker.
struct NewSSHConnectionView: View {
    @Environment(\.dismiss)
    private var dismiss
    @EnvironmentObject private var utilityAreaViewModel: UtilityAreaViewModel

    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var password = ""
    @State private var sessionName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New SSH Connection")
                .font(.headline)

            Group {
                LabeledContent("Session Name") {
                    TextField("My Router", text: $sessionName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Hostname") {
                    TextField("192.168.1.1", text: $hostname)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Port") {
                    TextField("22", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
                LabeledContent("Username") {
                    TextField("admin", text: $username)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Password") {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hostname.isEmpty || username.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func connect() {
        let name = sessionName.isEmpty ? hostname : sessionName
        let portInt = Int(port) ?? 22
        let session = RemoteSession(
            name: name,
            hostname: hostname,
            port: portInt,
            username: username,
            authMethod: .password
        )
        utilityAreaViewModel.addSSHTerminal(session: session, password: password.isEmpty ? nil : password)
        dismiss()
    }
}
