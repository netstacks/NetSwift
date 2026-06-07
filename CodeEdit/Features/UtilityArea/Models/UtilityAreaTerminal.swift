//
//  UtilityAreaTerminal.swift
//  CodeEdit
//
//  Created by Khan Winter on 7/27/24.
//

import Foundation

/// Describes how a terminal tab obtains its shell session.
enum TerminalConnectionType {
    case localShell
    case ssh(session: RemoteSession, password: String?)
}

final class UtilityAreaTerminal: ObservableObject, Identifiable, Equatable {
    let id: UUID
    @Published var url: URL
    @Published var title: String
    @Published var terminalTitle: String
    @Published var shell: Shell?
    @Published var customTitle: Bool
    @Published var connectionType: TerminalConnectionType

    init(id: UUID, url: URL, title: String, shell: Shell?, connectionType: TerminalConnectionType = .localShell) {
        self.id = id
        self.title = title
        self.terminalTitle = title
        self.url = url
        self.shell = shell
        self.customTitle = false
        self.connectionType = connectionType
    }

    static func == (lhs: UtilityAreaTerminal, rhs: UtilityAreaTerminal) -> Bool {
        lhs.id == rhs.id
    }
}
