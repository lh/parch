import Foundation
import GRDB
import Logging
import Testing
@testable import parch

@Suite("Database upsert")
struct ParchDatabaseTests {
    private func makeDB() throws -> ParchDatabase {
        var logger = Logger(label: "parch.tests")
        logger.logLevel = .critical
        return try ParchDatabase(dbQueue: try DatabaseQueue(), logger: logger)
    }

    /// Regression: the changed-file branch used record.update(db), which
    /// throws "Key not found [rowid:NULL]" because IndexedPDF carries no
    /// primary-key mapping. It must reset the row instead of throwing.
    @Test func upsertDiscoveredResetsChangedFileWithoutThrowing() throws {
        let db = try makeDB()
        try db.upsertDiscovered(filePath: "/x/a.pdf", fileSize: 100, mtime: 1000)
        try db.markComplete(path: "/x/a.pdf", canonicalPath: "/x/a", engine: .vision)

        try db.upsertDiscovered(filePath: "/x/a.pdf", fileSize: 200, mtime: 2000)

        let row = try #require(try db.fetchByPath("/x/a.pdf"))
        #expect(row.conversionStatus == .pending)
        #expect(row.fileSize == 200)
        #expect(row.mtime == 2000)
        #expect(row.contentHash == nil)
    }

    /// Regression: stored mtimes can differ from a fresh stat of the
    /// untouched file by sub-millisecond rounding (microsecond vs nanosecond
    /// precision). That must not reset a completed conversion.
    @Test func upsertDiscoveredIgnoresSubMillisecondMtimeDrift() throws {
        let db = try makeDB()
        try db.upsertDiscovered(filePath: "/x/b.pdf", fileSize: 100, mtime: 1787521402.994384)
        try db.markComplete(path: "/x/b.pdf", canonicalPath: "/x/b", engine: .vision)

        try db.upsertDiscovered(
            filePath: "/x/b.pdf", fileSize: 100, mtime: 1787521402.994383717)

        let row = try #require(try db.fetchByPath("/x/b.pdf"))
        #expect(row.conversionStatus == .complete)
    }

    @Test func upsertBatchResetsChangedFileWithoutThrowing() throws {
        let db = try makeDB()
        _ = try db.upsertBatch([(filePath: "/x/c.pdf", fileSize: 100, mtime: 1000)])
        try db.markComplete(path: "/x/c.pdf", canonicalPath: "/x/c", engine: .vision)

        let result = try db.upsertBatch([
            (filePath: "/x/c.pdf", fileSize: 100, mtime: 3000),
            (filePath: "/x/d.pdf", fileSize: 50, mtime: 1000),
        ])
        #expect(result.updated == 1)
        #expect(result.new == 1)

        let row = try #require(try db.fetchByPath("/x/c.pdf"))
        #expect(row.conversionStatus == .pending)
        #expect(row.mtime == 3000)
    }
}
