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

    // MARK: - Write

    func upsertDiscovered(filePath: String, fileSize: Int64, mtime: Double) throws {
        try dbQueue.write { db in
            if var existing = try IndexedPDF.fetchByPath(filePath, db: db) {
                if existing.fileSize == fileSize && existing.mtime == mtime {
                    return // unchanged
                }
                // File changed - reset for re-conversion
                existing.fileSize = fileSize
                existing.mtime = mtime
                existing.contentHash = nil
                existing.conversionStatus = .pending
                existing.convertedAt = nil
                existing.failureReason = nil
                try existing.update(db)
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
                    failureReason: nil
                )
                try record.insert(db)
            }
        }
    }

    func upsertBatch(_ entries: [(filePath: String, fileSize: Int64, mtime: Double)]) throws -> (new: Int, updated: Int, skipped: Int) {
        var new = 0, updated = 0, skipped = 0
        try dbQueue.write { db in
            for entry in entries {
                if var existing = try IndexedPDF.fetchByPath(entry.filePath, db: db) {
                    if existing.fileSize == entry.fileSize && existing.mtime == entry.mtime {
                        skipped += 1
                        continue
                    }
                    existing.fileSize = entry.fileSize
                    existing.mtime = entry.mtime
                    existing.contentHash = nil
                    existing.conversionStatus = .pending
                    existing.convertedAt = nil
                    existing.failureReason = nil
                    try existing.update(db)
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
                        failureReason: nil
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

    func markComplete(path: String, canonicalPath: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE indexed_pdf
                    SET conversion_status = 'complete', converted_at = ?, canonical_path = ?, failure_reason = NULL
                    WHERE file_path = ?
                    """,
                arguments: [Date().timeIntervalSince1970, canonicalPath, path]
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
}
