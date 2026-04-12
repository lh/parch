import Foundation
import GRDB

struct IndexedPDF: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "indexed_pdf"

    var contentHash: String?
    var filePath: String
    var fileSize: Int64
    var mtime: Double
    var conversionStatus: ConversionStatus
    var canonicalPath: String?
    var indexedAt: Double
    var convertedAt: Double?
    var failureReason: String?
    var engine: String?

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case filePath = "file_path"
        case fileSize = "file_size"
        case mtime
        case conversionStatus = "conversion_status"
        case canonicalPath = "canonical_path"
        case indexedAt = "indexed_at"
        case convertedAt = "converted_at"
        case failureReason = "failure_reason"
        case engine
    }

    enum ConversionStatus: String, Codable, Sendable, DatabaseValueConvertible {
        case pending
        case inProgress = "in_progress"
        case complete
        case failed
    }
}

// MARK: - Queries

extension IndexedPDF {
    static func fetchPending(db: Database, limit: Int = 100) throws -> [IndexedPDF] {
        try IndexedPDF
            .filter(Column("conversion_status") == ConversionStatus.pending.rawValue)
            .order(Column("indexed_at").asc)
            .limit(limit)
            .fetchAll(db)
    }

    static func fetchPendingByPrefix(_ prefix: String, db: Database, limit: Int = 100) throws -> [IndexedPDF] {
        try IndexedPDF
            .filter(Column("conversion_status") == ConversionStatus.pending.rawValue)
            .filter(Column("file_path").like("\(prefix)%"))
            .order(Column("indexed_at").asc)
            .limit(limit)
            .fetchAll(db)
    }

    static func fetchFailed(db: Database) throws -> [IndexedPDF] {
        try IndexedPDF
            .filter(Column("conversion_status") == ConversionStatus.failed.rawValue)
            .order(Column("indexed_at").desc)
            .fetchAll(db)
    }

    static func fetchByHash(_ hash: String, db: Database) throws -> [IndexedPDF] {
        try IndexedPDF
            .filter(Column("content_hash") == hash)
            .fetchAll(db)
    }

    static func fetchByPath(_ path: String, db: Database) throws -> IndexedPDF? {
        try IndexedPDF
            .filter(Column("file_path") == path)
            .fetchOne(db)
    }

    static func countByStatus(db: Database) throws -> [ConversionStatus: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT conversion_status, COUNT(*) as count
            FROM indexed_pdf
            GROUP BY conversion_status
            """)
        var result: [ConversionStatus: Int] = [:]
        for row in rows {
            if let status = ConversionStatus(rawValue: row["conversion_status"]) {
                result[status] = row["count"]
            }
        }
        return result
    }

    static func filesWithSize(_ size: Int64, db: Database) throws -> [IndexedPDF] {
        try IndexedPDF
            .filter(Column("file_size") == size)
            .fetchAll(db)
    }
}
