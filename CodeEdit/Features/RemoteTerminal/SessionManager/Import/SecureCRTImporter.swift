//
//  SecureCRTImporter.swift
//  CodeEdit
//

import Foundation

/// Parses SecureCRT `.ini` session files into ``RemoteSession`` / ``SessionFolder`` values.
enum SecureCRTImporter {

    /// The result of importing a directory tree of SecureCRT sessions.
    struct ImportResult: Equatable {
        var folders: [SessionFolder]
        var sessions: [RemoteSession]
    }

    /// Parses a single `.ini` file's contents into a session. Returns `nil` if there is no hostname.
    static func parseSession(ini: String, name: String, folderID: UUID? = nil) -> RemoteSession? {
        var values: [String: String] = [:]
        for rawLine in ini.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = keyName(of: String(line[..<eq]))
            let value = String(line[line.index(after: eq)...])
            if let key { values[key] = value }
        }

        guard let hostname = values["Hostname"], !hostname.isEmpty else { return nil }

        let proto: ConnectionProtocol
        switch values["Protocol Name"]?.lowercased() {
        case "telnet": proto = .telnet
        default:       proto = .ssh   // SSH2/SSH1/unknown -> SSH
        }

        let port = values.first { $0.key.hasSuffix("Port") }
            .flatMap { Int($0.value, radix: 16) } ?? proto.defaultPort

        return RemoteSession(
            name: name,
            protocol: proto,
            hostname: hostname,
            port: port,
            username: values["Username"] ?? "",
            folderID: folderID
        )
    }

    /// Extracts the quoted key name from a SecureCRT typed key like `S:"Hostname"` or `D:"[SSH2] Port"`.
    private static func keyName(of typedKey: String) -> String? {
        guard let open = typedKey.firstIndex(of: "\""),
              let close = typedKey.lastIndex(of: "\""),
              open < close else { return nil }
        return String(typedKey[typedKey.index(after: open)..<close])
    }

    /// Recursively imports a directory of `.ini` files. Subdirectories become folders.
    /// `parentID` is the folder these top-level items attach to.
    static func importTree(from directory: URL, into parentID: UUID) throws -> ImportResult {
        var result = ImportResult(folders: [], sessions: [])
        let fileManager = FileManager.default
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var childOrder: [UUID] = []
        for entry in entries {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                var folder = SessionFolder(name: entry.lastPathComponent, parentID: parentID)
                let nested = try importTree(from: entry, into: folder.id)
                folder.childIDs = orderedIDs(folders: nested.folders, sessions: nested.sessions, under: folder.id)
                result.folders.append(folder)
                result.folders.append(contentsOf: nested.folders)
                result.sessions.append(contentsOf: nested.sessions)
                childOrder.append(folder.id)
            } else if entry.pathExtension.lowercased() == "ini" {
                let contents = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
                let name = entry.deletingPathExtension().lastPathComponent
                if let session = parseSession(ini: contents, name: name, folderID: parentID) {
                    result.sessions.append(session)
                    childOrder.append(session.id)
                }
            }
        }
        // Stamp the parent's direct-child ordering onto any folder we created for it.
        if let index = result.folders.firstIndex(where: { $0.id == parentID }) {
            result.folders[index].childIDs = childOrder
        }
        return result
    }

    private static func orderedIDs(
        folders: [SessionFolder],
        sessions: [RemoteSession],
        under parentID: UUID
    ) -> [UUID] {
        let folderIDs = folders.filter { $0.parentID == parentID }.map(\.id)
        let sessionIDs = sessions.filter { $0.folderID == parentID }.map(\.id)
        return folderIDs + sessionIDs
    }
}
