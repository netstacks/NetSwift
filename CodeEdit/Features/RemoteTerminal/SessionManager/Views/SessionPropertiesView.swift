//
//  SessionPropertiesView.swift
//  CodeEdit
//

import SwiftUI

/// Edits a session's properties. Used both for creating a new session and editing an existing one.
///
/// Deliberately mirrors the plain `VStack` / `LabeledContent` layout of `NewSSHConnectionView`
/// (which presents reliably as an AppKit sheet). A grouped `Form` here made the Save/Cancel
/// buttons stop receiving clicks inside the `NSHostingController` sheet.
struct SessionPropertiesView: View {
    @State private var draft: RemoteSession
    @State private var password: String
    private let onSave: (RemoteSession, String?) -> Void
    private let onCancel: () -> Void

    init(
        session: RemoteSession,
        password: String?,
        onSave: @escaping (RemoteSession, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: session)
        _password = State(initialValue: password ?? "")
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var portString: Binding<String> {
        Binding(
            get: { String(draft.port) },
            set: { draft.port = Int($0) ?? draft.protocol.defaultPort }
        )
    }

    private var authBinding: Binding<AuthMethodKind> {
        Binding(
            get: { AuthMethodKind(draft.authMethod) },
            set: { draft.authMethod = $0.authMethod }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Session Properties").font(.headline)

            Group {
                LabeledContent("Name") {
                    TextField("My Router", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Protocol") {
                    Picker("", selection: $draft.protocol) {
                        Text("SSH").tag(ConnectionProtocol.ssh)
                        Text("Telnet").tag(ConnectionProtocol.telnet)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                LabeledContent("Hostname") {
                    TextField("192.168.1.1", text: $draft.hostname)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Port") {
                    TextField("22", text: portString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                LabeledContent("Username") {
                    TextField("admin", text: $draft.username)
                        .textFieldStyle(.roundedBorder)
                }
                if draft.protocol == .ssh {
                    LabeledContent("Auth") {
                        Picker("", selection: authBinding) {
                            Text("Password").tag(AuthMethodKind.password)
                            Text("Public Key").tag(AuthMethodKind.publicKey)
                            Text("Keyboard Interactive").tag(AuthMethodKind.keyboardInteractive)
                        }
                        .labelsHidden()
                    }
                    if case .password = draft.authMethod {
                        LabeledContent("Password") {
                            SecureField("Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                LabeledContent("Notes") {
                    TextField("", text: $draft.notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    print("[SM] Save button tapped — name='\(draft.name)' host='\(draft.hostname)'")
                    onSave(draft, draft.protocol == .ssh && draft.authMethod == .password ? password : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.hostname.isEmpty || draft.name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

/// A plain (no associated value) mirror of ``AuthMethod`` for use as a Picker tag.
/// Selecting Public Key mints a placeholder keyID; a real SSH-key picker is a later phase.
enum AuthMethodKind: String, Codable, Hashable {
    case password, publicKey, keyboardInteractive

    init(_ method: AuthMethod) {
        switch method {
        case .password: self = .password
        case .publicKey: self = .publicKey
        case .keyboardInteractive: self = .keyboardInteractive
        }
    }

    var authMethod: AuthMethod {
        switch self {
        case .password: return .password
        case .publicKey: return .publicKey(keyID: UUID())
        case .keyboardInteractive: return .keyboardInteractive
        }
    }
}
