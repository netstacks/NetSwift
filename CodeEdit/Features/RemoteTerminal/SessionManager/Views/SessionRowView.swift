//
//  SessionRowView.swift
//  CodeEdit
//

import SwiftUI

/// Connection status shown as a colored dot in a session row.
enum SessionConnectionStatus {
    case connected     // an open utility-area tab references this session
    case disconnected  // no open tab

    var color: Color {
        switch self {
        case .connected: return .green
        case .disconnected: return Color(nsColor: .tertiaryLabelColor)
        }
    }
}

/// A single row: status dot + name + protocol badge.
struct SessionRowView: View {
    let session: RemoteSession
    let status: SessionConnectionStatus

    private var helpText: String {
        var text = "\(session.username)@\(session.hostname):\(session.port)"
        if let last = session.lastConnectedAt {
            text += " — last connected \(last.formatted(date: .abbreviated, time: .shortened))"
        }
        return text
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 7, height: 7)
            Image(systemName: session.protocol == .ssh ? "lock.shield" : "network")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(session.name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text(session.protocol == .ssh ? "SSH" : "Telnet")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help(helpText)
    }
}

/// A folder row: folder icon + name.
struct SessionFolderRowView: View {
    let folder: SessionFolder

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text(folder.name)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }
}
