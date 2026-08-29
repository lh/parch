import Foundation
import GRDB
import Logging
import Testing
@testable import parch

/// Runs `body` with a fresh temporary directory tree that is cleaned up after.
private func withTempTree(_ body: (String) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("parch-exclusion-" + UUID().uuidString)
        .resolvingSymlinksInPath().path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try body(dir)
}

private func makeDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
}

private func writeFile(_ path: String, _ contents: String = "x") throws {
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
}

@Suite("Exclusion cache")
struct ExclusionCacheTests {

    @Test func markerExcludesItsOwnDirectory() throws {
        try withTempTree { root in
            try writeFile((root as NSString).appendingPathComponent(ScanRules.exclusionMarkerName))
            var cache = ExclusionCache()
            let excluded = cache.isExcluded(path: (root as NSString).appendingPathComponent("a.pdf"))
            #expect(excluded)
        }
    }

    @Test func markerExcludesDescendants() throws {
        try withTempTree { root in
            let repo = (root as NSString).appendingPathComponent("repo")
            let deep = (repo as NSString).appendingPathComponent("tests/fixtures/master")
            try makeDirectory(deep)
            try writeFile((repo as NSString).appendingPathComponent(ScanRules.exclusionMarkerName))

            var cache = ExclusionCache()
            let excluded = cache.isExcluded(path: (deep as NSString).appendingPathComponent("a.pdf"))
            #expect(excluded)
        }
    }

    @Test func markerDoesNotExcludeSiblings() throws {
        try withTempTree { root in
            let excluded = (root as NSString).appendingPathComponent("excluded")
            let kept = (root as NSString).appendingPathComponent("kept")
            try makeDirectory(excluded)
            try makeDirectory(kept)
            try writeFile((excluded as NSString).appendingPathComponent(ScanRules.exclusionMarkerName))

            var cache = ExclusionCache()
            let excludedResult = cache.isExcluded(
                path: (excluded as NSString).appendingPathComponent("a.pdf"))
            let keptResult = cache.isExcluded(
                path: (kept as NSString).appendingPathComponent("b.pdf"))
            #expect(excludedResult)
            #expect(!keptResult)
        }
    }

    /// A cached "not excluded" ancestor must not mask a marker that sits
    /// below it. The walk records every directory it passes, so an answer
    /// cached for the parent has to be consistent with each child's own marker.
    @Test func cachedAncestorDoesNotMaskDeeperMarker() throws {
        try withTempTree { root in
            let parent = (root as NSString).appendingPathComponent("parent")
            let child = (parent as NSString).appendingPathComponent("child")
            try makeDirectory(child)
            try writeFile((child as NSString).appendingPathComponent(ScanRules.exclusionMarkerName))

            var cache = ExclusionCache()
            // Resolve and cache the parent first, then ask about the child.
            let parentResult = cache.isExcluded(
                path: (parent as NSString).appendingPathComponent("a.pdf"))
            let childResult = cache.isExcluded(
                path: (child as NSString).appendingPathComponent("b.pdf"))
            #expect(!parentResult)
            #expect(childResult)
        }
    }

    /// Repeated questions must keep returning the same answer -- the whole
    /// point of the cache is that the second ask skips the ancestor walk.
    @Test func repeatedLookupsAgree() throws {
        try withTempTree { root in
            let repo = (root as NSString).appendingPathComponent("repo/deep")
            try makeDirectory(repo)
            try writeFile((root as NSString).appendingPathComponent(ScanRules.exclusionMarkerName))

            var cache = ExclusionCache()
            let path = (repo as NSString).appendingPathComponent("a.pdf")
            let first = cache.isExcluded(path: path)
            let second = cache.isExcluded(path: path)
            #expect(first)
            #expect(second)
        }
    }

    @Test func staticSkipRulesStillApply() {
        var cache = ExclusionCache()
        let inNodeModules = cache.isExcluded(path: "/Users/test/project/node_modules/lib/doc.pdf")
        let inSystem = cache.isExcluded(path: "/System/Library/doc.pdf")
        #expect(inNodeModules)
        #expect(inSystem)
    }
}

@Suite("Scan pruning")
struct ScanPruningTests {
    private func makeDB() throws -> ParchDatabase {
        var logger = Logger(label: "parch.tests")
        logger.logLevel = .critical
        return try ParchDatabase(dbQueue: try DatabaseQueue(), logger: logger)
    }

    private func makeLogger() -> Logger {
        var logger = Logger(label: "parch.tests")
        logger.logLevel = .critical
        return logger
    }

    /// The bug this fixes: a directory excluded *after* its PDFs were indexed
    /// kept converting, because discovery filtering never revisits rows the
    /// index already holds.
    @Test func scanPrunesAlreadyIndexedFilesUnderANewMarker() throws {
        try withTempTree { root in
            let repo = (root as NSString).appendingPathComponent("repo")
            try makeDirectory(repo)
            let pdf = (repo as NSString).appendingPathComponent("fixture.pdf")
            try writeFile(pdf, "%PDF-1.4")

            let db = try makeDB()
            try db.upsertDiscovered(filePath: pdf, fileSize: 8, mtime: 1000)
            #expect(try db.allIndexedPaths() == [pdf])

            // Exclude the directory only now, after indexing.
            try writeFile((repo as NSString).appendingPathComponent(ScanRules.exclusionMarkerName))

            let scanner = Scanner(db: db, scanRoots: [root], logger: makeLogger())
            let result = try scanner.scan()

            #expect(result.pruned == 1)
            #expect(try db.allIndexedPaths().isEmpty)
        }
    }

    @Test func scanKeepsIndexedFilesOutsideExcludedDirectories() throws {
        try withTempTree { root in
            let kept = (root as NSString).appendingPathComponent("kept")
            let excluded = (root as NSString).appendingPathComponent("excluded")
            try makeDirectory(kept)
            try makeDirectory(excluded)
            let keptPDF = (kept as NSString).appendingPathComponent("keep.pdf")
            let droppedPDF = (excluded as NSString).appendingPathComponent("drop.pdf")
            try writeFile(keptPDF, "%PDF-1.4")
            try writeFile(droppedPDF, "%PDF-1.4")
            try writeFile((excluded as NSString).appendingPathComponent(ScanRules.exclusionMarkerName))

            let db = try makeDB()
            try db.upsertDiscovered(filePath: keptPDF, fileSize: 8, mtime: 1000)
            try db.upsertDiscovered(filePath: droppedPDF, fileSize: 8, mtime: 1000)

            let scanner = Scanner(db: db, scanRoots: [root], logger: makeLogger())
            let result = try scanner.scan()

            #expect(result.pruned == 1)
            #expect(try db.allIndexedPaths() == [keptPDF])
        }
    }

    /// A pruned file must not be re-added by the same scan's discovery phase,
    /// or every run would prune and re-index the same rows forever.
    @Test func prunedFilesAreNotRediscovered() throws {
        try withTempTree { root in
            let repo = (root as NSString).appendingPathComponent("repo")
            try makeDirectory(repo)
            let pdf = (repo as NSString).appendingPathComponent("fixture.pdf")
            try writeFile(pdf, "%PDF-1.4")
            try writeFile((repo as NSString).appendingPathComponent(ScanRules.exclusionMarkerName))

            let db = try makeDB()
            let scanner = Scanner(db: db, scanRoots: [root], logger: makeLogger())

            _ = try scanner.scan()
            #expect(try db.allIndexedPaths().isEmpty)

            let second = try scanner.scan()
            #expect(second.pruned == 0)
            #expect(try db.allIndexedPaths().isEmpty)
        }
    }

    /// A marker at the scan root itself is never handed to the directory
    /// enumerator, so only the per-file check can catch it.
    @Test func markerAtScanRootExcludesEverythingBeneath() throws {
        try withTempTree { root in
            try writeFile((root as NSString).appendingPathComponent(ScanRules.exclusionMarkerName))
            let pdf = (root as NSString).appendingPathComponent("top.pdf")
            try writeFile(pdf, "%PDF-1.4")

            let db = try makeDB()
            let scanner = Scanner(db: db, scanRoots: [root], logger: makeLogger())
            _ = try scanner.scan()

            #expect(try db.allIndexedPaths().isEmpty)
        }
    }

    @Test func removePathsDeletesInOneGo() throws {
        let db = try makeDB()
        for i in 0..<5 {
            try db.upsertDiscovered(filePath: "/x/\(i).pdf", fileSize: 1, mtime: 1)
        }
        let removed = try db.removePaths(["/x/1.pdf", "/x/3.pdf"])

        #expect(removed == 2)
        #expect(try db.allIndexedPaths().sorted() == ["/x/0.pdf", "/x/2.pdf", "/x/4.pdf"])
    }

    @Test func removePathsOnEmptyListIsANoOp() throws {
        let db = try makeDB()
        try db.upsertDiscovered(filePath: "/x/a.pdf", fileSize: 1, mtime: 1)
        #expect(try db.removePaths([]) == 0)
        #expect(try db.allIndexedPaths() == ["/x/a.pdf"])
    }
}
