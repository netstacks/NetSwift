//
//  SessionStore.swift
//  CodeEdit
//

import Foundation
import GRDB
import OSLog

/// Persists ``RemoteSession`` and ``SessionFolder`` records to a SQLite database
/// at `~/Library/Application Support/CodeEdit/sessions.db`.
///
/// Mirrors the `EditorStateRestoration` pattern: a globally shared, synchronous
/// `DatabaseQueue` with a `DatabaseMigrator`. Each record is stored as a JSON blob
/// keyed by its UUID string.
///
/// # If changes are required
///
/// Add a new migration version in `attemptMigration`. **Never** delete a migration
/// that has shipped in a released build.
final class SessionStore {
    /// Optional so callers can degrade gracefully if the database fails to open.
    static let shared: SessionStore? = try? SessionStore()

    /// Last-resort in-memory store so UI can always construct a view model.
    /// Uses a unique temp path; not persisted across launches.
    static let inMemoryFallback: SessionStore = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codeedit-sessions-fallback.db")
        // A temp-dir SQLite file open does not realistically fail, and this only runs
        // if the shared store already failed. `force_try` is disallowed by SwiftLint,
        // so use do/catch and fatalError on the practically impossible failure.
        do {
            return try SessionStore(url)
        } catch {
            fatalError("Failed to open in-memory fallback session store: \(error)")
        }
    }()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "",
        category: "SessionStore"
    )

    struct SessionRecord: Codable, TableRecord, FetchableRecord, PersistableRecord {
        static let databaseTableName = "remoteSession"
        let id: String
        let data: Data
    }

    struct FolderRecord: Codable, TableRecord, FetchableRecord, PersistableRecord {
        static let databaseTableName = "sessionFolder"
        let id: String
        let data: Data
    }

    private var databaseQueue: DatabaseQueue?
    private var databaseURL: URL

    /// - Parameter databaseURL: File URL for the database. If `nil`, uses
    ///   `sessions.db` in the application support directory.
    init(_ databaseURL: URL? = nil) throws {
        self.databaseURL = databaseURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/CodeEdit", directoryHint: .isDirectory)
            .appending(path: "sessions.db", directoryHint: .notDirectory)
        try attemptMigration(retry: true)
    }

    func attemptMigration(retry: Bool) throws {
        do {
            let databaseQueue = try DatabaseQueue(path: databaseURL.absolutePath, configuration: .init())

            var migrator = DatabaseMigrator()
            migrator.registerMigration("Version 0") { db in
                try db.create(table: "remoteSession") { table in
                    table.column("id", .text).primaryKey().notNull()
                    table.column("data", .blob).notNull()
                }
                try db.create(table: "sessionFolder") { table in
                    table.column("id", .text).primaryKey().notNull()
                    table.column("data", .blob).notNull()
                }
            }

            try migrator.migrate(databaseQueue)
            self.databaseQueue = databaseQueue
        } catch {
            if retry {
                // The DB is unusable. Preserve it as a breadcrumb rather than silently
                // discarding user-authored session data, then retry with a fresh file.
                let corruptURL = databaseURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
                do {
                    try FileManager.default.moveItem(at: databaseURL, to: corruptURL)
                } catch {
                    try? FileManager.default.removeItem(at: databaseURL)
                }
                try attemptMigration(retry: false)
                return
            }
            Self.logger.error("Failed to start session database: \(error)")
            throw error
        }
    }

    // MARK: - Sessions

    func allSessions() -> [RemoteSession] {
        do {
            let records = try databaseQueue?.read { try SessionRecord.fetchAll($0) } ?? []
            return records.compactMap { try? JSONDecoder().decode(RemoteSession.self, from: $0.data) }
        } catch {
            Self.logger.error("Failed to fetch sessions: \(error)")
            return []
        }
    }

    func saveSession(_ session: RemoteSession) {
        do {
            let data = try JSONEncoder().encode(session)
            let record = SessionRecord(id: session.id.uuidString, data: data)
            try databaseQueue?.write { try record.upsert($0) }
        } catch {
            Self.logger.error("Failed to save session: \(error)")
        }
    }

    func deleteSession(id: UUID) {
        do {
            _ = try databaseQueue?.write { try SessionRecord.deleteOne($0, key: id.uuidString) }
        } catch {
            Self.logger.error("Failed to delete session: \(error)")
        }
    }

    // MARK: - Folders

    func allFolders() -> [SessionFolder] {
        do {
            let records = try databaseQueue?.read { try FolderRecord.fetchAll($0) } ?? []
            return records.compactMap { try? JSONDecoder().decode(SessionFolder.self, from: $0.data) }
        } catch {
            Self.logger.error("Failed to fetch folders: \(error)")
            return []
        }
    }

    func saveFolder(_ folder: SessionFolder) {
        do {
            let data = try JSONEncoder().encode(folder)
            let record = FolderRecord(id: folder.id.uuidString, data: data)
            try databaseQueue?.write { try record.upsert($0) }
        } catch {
            Self.logger.error("Failed to save folder: \(error)")
        }
    }

    func deleteFolder(id: UUID) {
        do {
            _ = try databaseQueue?.write { try FolderRecord.deleteOne($0, key: id.uuidString) }
        } catch {
            Self.logger.error("Failed to delete folder: \(error)")
        }
    }
}
