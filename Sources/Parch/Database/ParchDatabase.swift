import Foundation
import GRDB
import Logging

final class ParchDatabase: Sendable {
    let dbQueue: DatabaseQueue
    private let logger: Logger

    init(logger: Logger) throws {
        self.logger = logger
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parch", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("index.db").path
        dbQueue = try DatabaseQueue(path: dbPath)
        try ParchMigrations.migrator.migrate(dbQueue)
        logger.info("Database opened at \(dbPath)")
    }

    /// For testing with in-memory database
    init(dbQueue: DatabaseQueue, logger: Logger) throws {
        self.dbQueue = dbQueue
        self.logger = logger
        try ParchMigrations.migrator.migrate(dbQueue)
    }

    // MARK: - Read

    func countByStatus() throws -> [IndexedPDF.ConversionStatus: Int] {
        try dbQueue.read { db in
            try IndexedPDF.countByStatus(db: db)
        }
    }

    func fetchPending(limit: Int = 100, pathPrefix: String? = nil) throws -> [IndexedPDF] {
        try dbQueue.read { db in
            if let prefix = pathPrefix {
                try IndexedPDF.fetchPendingByPrefix(prefix, db: db, limit: limit)
            } else {
                try IndexedPDF.fetchPending(db: db, limit: limit)
            }
        }
    }

    func fetchFailed() throws -> [IndexedPDF] {
        try dbQueue.read { db in
            try IndexedPDF.fetchFailed(db: db)
        }
    }

    func fetchByPath(_ path: String) throws -> IndexedPDF? {
        try dbQueue.read { db in
            try IndexedPDF.fetchByPath(path, db: db)
        }
    }

    func fetchByHash(_ hash: String) throws -> [IndexedPDF] {
        try dbQueue.read { db in
            try IndexedPDF.fetchByHash(hash, db: db)
        }
    }

    func filesWithSize(_ size: Int64) throws -> [IndexedPDF] {
        try dbQueue.read { db in
            try IndexedPDF.filesWithSize(size, db: db)
        }
    }

    func totalCount() throws -> Int {
        try dbQueue.read { db in
            try IndexedPDF.fetchCount(db)
        }
    }

    /// Every indexed file path. Used by the scan's prune phase, which has to
    /// re-test paths the index already holds rather than only what discovery
    /// just returned.
    func allIndexedPaths() throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT file_path FROM indexed_pdf")
        }
    }

    // MARK: - Write

    /// Whether two mtimes are the same modification event. Exact equality is
    /// wrong here: APFS keeps nanoseconds but different stat paths round
    /// differently (microseconds vs nanoseconds), so a stored mtime can
    /// drift from a fresh stat of the untouched file by under a
    /// millisecond. Treating that as a modification would needlessly reset
    /// completed conversions.
    static func sameMtime(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 0.001
    }

    /// Reset a changed file's row for re-conversion. Keyed on file_path like
    /// every other write: IndexedPDF has no primary-key mapping, so GRDB's
    /// record.update(db) throws "Key not found [rowid:NULL]".
    private static func resetChanged(
        _ db: Database, filePath: String, fileSize: Int64, mtime: Double
    ) throws {
        try db.execute(
            sql: """
                UPDATE indexed_pdf
                SET file_size = ?, mtime = ?, content_hash = NULL,
                    conversion_status = 'pending', converted_at = NULL, failure_reason = NULL
                WHERE file_path = ?
                """,
            arguments: [fileSize, mtime, filePath]
        )
    }

    func upsertDiscovered(filePath: String, fileSize: Int64, mtime: Double) throws {
        try dbQueue.write { db in
            if let existing = try IndexedPDF.fetchByPath(filePath, db: db) {
                if existing.fileSize == fileSize && Self.sameMtime(existing.mtime, mtime) {
                    return // unchanged
                }
                try Self.resetChanged(db, filePath: filePath, fileSize: fileSize, mtime: mtime)
            } else {
                let record = IndexedPDF(
                    contentHash: nil,
                    filePath: filePath,
                    fileSize: fileSize,
                    mtime: mtime,
                    conversionStatus: .pending,
                    canonicalPath: nil,
                    indexedAt: Date().timeIntervalSince1970,
                    convertedAt: nil,
                    failureReason: nil,
                    engine: nil
                )
                try record.insert(db)
            }
        }
    }

    func upsertBatch(_ entries: [(filePath: String, fileSize: Int64, mtime: Double)]) throws -> (new: Int, updated: Int, skipped: Int) {
        var new = 0, updated = 0, skipped = 0
        try dbQueue.write { db in
            for entry in entries {
                if let existing = try IndexedPDF.fetchByPath(entry.filePath, db: db) {
                    if existing.fileSize == entry.fileSize && Self.sameMtime(existing.mtime, entry.mtime) {
                        skipped += 1
                        continue
                    }
                    try Self.resetChanged(
                        db, filePath: entry.filePath,
                        fileSize: entry.fileSize, mtime: entry.mtime)
                    updated += 1
                } else {
                    let record = IndexedPDF(
                        contentHash: nil,
                        filePath: entry.filePath,
                        fileSize: entry.fileSize,
                        mtime: entry.mtime,
                        conversionStatus: .pending,
                        canonicalPath: nil,
                        indexedAt: Date().timeIntervalSince1970,
                        convertedAt: nil,
                        failureReason: nil,
                        engine: nil
                    )
                    try record.insert(db)
                    new += 1
                }
            }
        }
        return (new, updated, skipped)
    }

    func setHash(_ hash: String, forPath path: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE indexed_pdf SET content_hash = ? WHERE file_path = ?",
                arguments: [hash, path]
            )
        }
    }

    func markComplete(path: String, canonicalPath: String, engine: Engine? = nil) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE indexed_pdf
                    SET conversion_status = 'complete', converted_at = ?, canonical_path = ?, failure_reason = NULL, engine = ?
                    WHERE file_path = ?
                    """,
                arguments: [Date().timeIntervalSince1970, canonicalPath, engine?.rawValue, path]
            )
        }
    }

    /// Reset a row to pending and drop the conversion it advertised.
    /// Used when the output a `complete` row points at has gone missing, so the
    /// row stops offering a conversion that duplicates could link to.
    func markPending(path: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE indexed_pdf
                    SET conversion_status = 'pending', converted_at = NULL, canonical_path = NULL,
                        failure_reason = NULL, engine = NULL
                    WHERE file_path = ?
                    """,
                arguments: [path]
            )
        }
    }

    func markFailed(path: String, reason: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE indexed_pdf
                    SET conversion_status = 'failed', failure_reason = ?
                    WHERE file_path = ?
                    """,
                arguments: [reason, path]
            )
        }
    }

    func removePath(_ path: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM indexed_pdf WHERE file_path = ?", arguments: [path])
        }
    }

    /// Remove many paths in one transaction. A newly excluded directory can
    /// account for hundreds of rows; deleting them one transaction at a time
    /// leaves the index half-pruned if the run is interrupted partway.
    @discardableResult
    func removePaths(_ paths: [String]) throws -> Int {
        guard !paths.isEmpty else { return 0 }
        try dbQueue.write { db in
            for path in paths {
                try db.execute(
                    sql: "DELETE FROM indexed_pdf WHERE file_path = ?", arguments: [path])
            }
        }
        return paths.count
    }
}
