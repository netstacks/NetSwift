//
//  SessionPropertiesView.swift
//  CodeEdit
//

import SwiftUI

/// Edits a session's properties. Used both for creating a new session and editing an existing one.
/// Notes render as Markdown in a preview below the editable field.
struct SessionPropertiesView: View {
    /// The session being edited (a working copy).
    @State private var draft: RemoteSession
    @State private var password: String
    private let originalID: UUID
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
        self.originalID = session.id
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var portString: Binding<String> {
        Binding(
            get: { String(draft.port) },
            set: { draft.port = Int($0) ?? draft.protocol.defaultPort }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Session Properties").font(.headline)

            Form {
                TextField("Name", text: $draft.name)
                Picker("Protocol", selection: $draft.protocol) {
                    Text("SSH").tag(ConnectionProtocol.ssh)
                    Text("Telnet").tag(ConnectionProtocol.telnet)
                }
                TextField("Hostname", text: $draft.hostname)
                TextField("Port", text: portString)
                TextField("Username", text: $draft.username)

                if draft.protocol == .ssh {
                    Picker("Auth", selection: authBinding) {
                        Text("Password").tag(AuthMethodKind.password)
                        Text("Public Key").tag(AuthMethodKind.publicKey)
                        Text("Keyboard Interactive").tag(AuthMethodKind.keyboardInteractive)
                    }
                    if case .password = draft.authMethod {
                        SecureField("Password", text: $password)
                    }
                }
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 4) {
                Text("Notes").font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $draft.notes)
                    .font(.body.monospaced())
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor)))
                if !draft.notes.isEmpty, let rendered = try? AttributedString(markdown: draft.notes) {
                    Text(rendered)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft, draft.protocol == .ssh && draft.authMethod == .password ? password : nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.hostname.isEmpty || draft.name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// Bridges the associated-value `AuthMethod` to a plain picker tag.
    private var authBinding: Binding<AuthMethodKind> {
        Binding(
            get: { AuthMethodKind(draft.authMethod) },
            set: { draft.authMethod = $0.authMethod }
        )
    }
}

/// A plain (no associated value) mirror of ``AuthMethod`` for use as a Picker tag.
/// Selecting Public Key mints a placeholder keyID; a real SSH-key picker is a later phase.
enum AuthMethodKind: Hashable {
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
