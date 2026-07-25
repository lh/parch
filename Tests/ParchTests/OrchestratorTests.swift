import Foundation
import GRDB
import Logging
import Synchronization
import Testing
@testable import parch

/// Engine that records what it was asked to convert and writes plausible
/// output, so tests can tell conversion from dedup without running marker.
private final class StubEngine: ConversionEngine {
    let engine: Engine = .marker
    private let calls = Mutex<[String]>([])

    var convertedPaths: [String] { calls.withLock { $0 } }

    func convert(pdfPath: String) throws -> String {
        calls.withLock { $0.append(pdfPath) }
        let outputDir = ScanRules.outputDirectory(forPDF: pdfPath)
        try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        try "converted \(pdfPath)"
            .write(toFile: ScanRules.markdownPath(forPDF: pdfPath), atomically: true, encoding: .utf8)
        return outputDir
    }
}

/// Throwaway directory plus in-memory index for one test.
private struct Fixture: ~Copyable {
    let root: String
    let db: ParchDatabase
    let engine = StubEngine()
    let orchestrator: Orchestrator

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parch-tests-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)

        var logger = Logger(label: "parch.tests")
        logger.logLevel = .critical
        db = try ParchDatabase(dbQueue: try DatabaseQueue(), logger: logger)
        orchestrator = Orchestrator(db: db, primaryEngine: engine, logger: logger, maxWorkers: 1)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Write a PDF with the given content and index it as pending.
    func addPDF(_ name: String, content: String) throws -> String {
        let path = (root as NSString).appendingPathComponent(name)
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        let values = try URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        try db.upsertDiscovered(
            filePath: path,
            fileSize: Int64(values.fileSize!),
            mtime: values.contentModificationDate!.timeIntervalSince1970
        )
        return path
    }

    /// Mark a PDF converted, optionally writing the markdown it claims to have.
    func markConverted(_ path: String, hash: String, writeOutput: Bool = true) throws {
        let outputDir = ScanRules.outputDirectory(forPDF: path)
        if writeOutput {
            try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
            try "canonical output"
                .write(toFile: ScanRules.markdownPath(forPDF: path), atomically: true, encoding: .utf8)
        }
        try db.setHash(hash, forPath: path)
        try db.markComplete(path: path, canonicalPath: outputDir, engine: .marker)
    }

    func row(_ path: String) throws -> IndexedPDF {
        try #require(try db.fetchByPath(path))
    }
}

@Suite("Orchestrator dedup")
struct OrchestratorDedupTests {

    @Test func dedupsWhenCanonicalOutputExists() async throws {
        let fixture = try Fixture()
        let canonical = try fixture.addPDF("original.pdf", content: "identical bytes")
        let duplicate = try fixture.addPDF("copy.pdf", content: "identical bytes")
        let hash = try FileHasher.sha256(of: URL(fileURLWithPath: canonical))
        try fixture.markConverted(canonical, hash: hash)

        let result = await fixture.orchestrator.convertPending()

        #expect(result.deduplicated == 1)
        #expect(result.converted == 0)
        #expect(fixture.engine.convertedPaths.isEmpty)

        let duplicateOutput = ScanRules.outputDirectory(forPDF: duplicate)
        #expect(ScanRules.symlinkDestination(of: duplicateOutput)
            == ScanRules.outputDirectory(forPDF: canonical))
        #expect(try fixture.row(duplicate).conversionStatus == .complete)
    }

    @Test func convertsWhenCanonicalOutputWasDeleted() async throws {
        let fixture = try Fixture()
        let canonical = try fixture.addPDF("original.pdf", content: "identical bytes")
        let duplicate = try fixture.addPDF("copy.pdf", content: "identical bytes")
        let hash = try FileHasher.sha256(of: URL(fileURLWithPath: canonical))
        try fixture.markConverted(canonical, hash: hash, writeOutput: false)

        let result = await fixture.orchestrator.convertPending()

        // The duplicate must be converted rather than symlinked to nothing.
        #expect(result.converted == 1)
        #expect(result.deduplicated == 0)
        #expect(fixture.engine.convertedPaths == [duplicate])

        let duplicateOutput = ScanRules.outputDirectory(forPDF: duplicate)
        #expect(ScanRules.symlinkDestination(of: duplicateOutput) == nil)
        #expect(FileManager.default.fileExists(atPath: ScanRules.markdownPath(forPDF: duplicate)))

        // The stale row stops advertising a conversion that is not there.
        let canonicalRow = try fixture.row(canonical)
        #expect(canonicalRow.conversionStatus == .pending)
        #expect(canonicalRow.canonicalPath == nil)
    }

    @Test func convertsWhenCanonicalDirectoryHasNoMarkdown() async throws {
        let fixture = try Fixture()
        let canonical = try fixture.addPDF("original.pdf", content: "identical bytes")
        let duplicate = try fixture.addPDF("copy.pdf", content: "identical bytes")
        let hash = try FileHasher.sha256(of: URL(fileURLWithPath: canonical))
        try fixture.markConverted(canonical, hash: hash, writeOutput: false)

        // A bare directory left behind by a half-finished conversion.
        try FileManager.default.createDirectory(
            atPath: ScanRules.outputDirectory(forPDF: canonical),
            withIntermediateDirectories: true
        )

        let result = await fixture.orchestrator.convertPending()

        #expect(result.converted == 1)
        #expect(result.deduplicated == 0)
        #expect(fixture.engine.convertedPaths == [duplicate])
        #expect(try fixture.row(canonical).conversionStatus == .pending)
    }

    @Test func changedFileDoesNotConvertThroughStaleDedupSymlink() async throws {
        let fixture = try Fixture()
        let canonical = try fixture.addPDF("original.pdf", content: "original bytes")
        let canonicalOutput = ScanRules.outputDirectory(forPDF: canonical)
        let canonicalHash = try FileHasher.sha256(of: URL(fileURLWithPath: canonical))
        try fixture.markConverted(canonical, hash: canonicalHash)

        // A duplicate that was deduped earlier, then edited: its content no
        // longer matches, but the symlink into the canonical output remains.
        let changed = try fixture.addPDF("copy.pdf", content: "different bytes now")
        let changedOutput = ScanRules.outputDirectory(forPDF: changed)
        try FileManager.default.createSymbolicLink(atPath: changedOutput, withDestinationPath: canonicalOutput)

        let result = await fixture.orchestrator.convertPending()

        #expect(result.converted == 1)
        #expect(ScanRules.symlinkDestination(of: changedOutput) == nil)
        #expect(try String(contentsOfFile: ScanRules.markdownPath(forPDF: changed), encoding: .utf8)
            .contains("copy.pdf"))
        // The canonical conversion must survive untouched.
        #expect(try String(contentsOfFile: ScanRules.markdownPath(forPDF: canonical), encoding: .utf8)
            == "canonical output")
    }
}

@Suite("Orchestrator forced conversion")
struct OrchestratorForceTests {

    @Test func forceBypassesDedup() async throws {
        let fixture = try Fixture()
        let canonical = try fixture.addPDF("original.pdf", content: "identical bytes")
        let duplicate = try fixture.addPDF("copy.pdf", content: "identical bytes")
        let hash = try FileHasher.sha256(of: URL(fileURLWithPath: canonical))
        try fixture.markConverted(canonical, hash: hash)

        let result = await fixture.orchestrator.convertSingle(try fixture.row(duplicate))

        #expect(result.converted == 1)
        #expect(result.deduplicated == 0)
        #expect(fixture.engine.convertedPaths == [duplicate])

        let duplicateOutput = ScanRules.outputDirectory(forPDF: duplicate)
        #expect(ScanRules.symlinkDestination(of: duplicateOutput) == nil)
        #expect(try fixture.row(duplicate).canonicalPath == duplicateOutput)
    }

    @Test func forceReconvertsAlreadyCompleteFile() async throws {
        let fixture = try Fixture()
        let pdf = try fixture.addPDF("report.pdf", content: "some bytes")
        let hash = try FileHasher.sha256(of: URL(fileURLWithPath: pdf))
        try fixture.markConverted(pdf, hash: hash)

        let result = await fixture.orchestrator.convertSingle(try fixture.row(pdf))

        // Without the force path this self-dedups and reports deduplicated.
        #expect(result.converted == 1)
        #expect(result.deduplicated == 0)
        #expect(fixture.engine.convertedPaths == [pdf])
        #expect(try String(contentsOfFile: ScanRules.markdownPath(forPDF: pdf), encoding: .utf8)
            .contains("report.pdf"))
    }

    @Test func forceReplacesDedupSymlinkWithRealOutput() async throws {
        let fixture = try Fixture()
        let canonical = try fixture.addPDF("original.pdf", content: "identical bytes")
        let canonicalOutput = ScanRules.outputDirectory(forPDF: canonical)
        let hash = try FileHasher.sha256(of: URL(fileURLWithPath: canonical))
        try fixture.markConverted(canonical, hash: hash)

        // A duplicate already deduped: complete, pointing at the canonical
        // output, with its own output directory being a symlink there.
        let duplicate = try fixture.addPDF("copy.pdf", content: "identical bytes")
        let duplicateOutput = ScanRules.outputDirectory(forPDF: duplicate)
        try FileManager.default.createSymbolicLink(atPath: duplicateOutput, withDestinationPath: canonicalOutput)
        try fixture.db.setHash(hash, forPath: duplicate)
        try fixture.db.markComplete(path: duplicate, canonicalPath: canonicalOutput, engine: .marker)

        let result = await fixture.orchestrator.convertSingle(try fixture.row(duplicate))

        #expect(result.converted == 1)
        #expect(ScanRules.symlinkDestination(of: duplicateOutput) == nil)
        #expect(try fixture.row(duplicate).canonicalPath == duplicateOutput)
        // Forcing one file must not rewrite the other file's conversion.
        #expect(try String(contentsOfFile: ScanRules.markdownPath(forPDF: canonical), encoding: .utf8)
            == "canonical output")
    }
}
