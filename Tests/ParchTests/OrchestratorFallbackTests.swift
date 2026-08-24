import Foundation
import GRDB
import Logging
import Synchronization
import Testing
@testable import parch

/// Vision-like engine that writes markdown plus a quality sidecar with the
/// given score, so tests can drive the orchestrator's fallback decision.
private final class SidecarVisionStub: ConversionEngine {
    let engine: Engine = .vision
    private let quality: QualityScore

    init(quality: QualityScore) {
        self.quality = quality
    }

    func convert(pdfPath: String) throws -> String {
        let outputDir = ScanRules.outputDirectory(forPDF: pdfPath)
        try FileManager.default.createDirectory(
            atPath: outputDir, withIntermediateDirectories: true)
        try "vision output"
            .write(toFile: ScanRules.markdownPath(forPDF: pdfPath),
                   atomically: true, encoding: .utf8)
        let data = try JSONEncoder().encode(quality)
        try data.write(to: URL(fileURLWithPath: outputDir)
            .appendingPathComponent(".vision-quality.json"))
        return outputDir
    }
}

/// Fallback engine that records calls; optionally fails.
private final class RecordingStub: ConversionEngine, Sendable {
    let engine: Engine
    private let fails: Bool
    private let calls = Mutex<[String]>([])

    var convertedPaths: [String] { calls.withLock { $0 } }

    init(engine: Engine, fails: Bool = false) {
        self.engine = engine
        self.fails = fails
    }

    func convert(pdfPath: String) throws -> String {
        calls.withLock { $0.append(pdfPath) }
        if fails {
            throw ConversionError.ovisFailed(exitCode: 1, stderr: "stub failure")
        }
        let outputDir = ScanRules.outputDirectory(forPDF: pdfPath)
        try FileManager.default.createDirectory(
            atPath: outputDir, withIntermediateDirectories: true)
        try "\(engine.rawValue) output"
            .write(toFile: ScanRules.markdownPath(forPDF: pdfPath),
                   atomically: true, encoding: .utf8)
        return outputDir
    }
}

private let poorQuality = QualityScore(
    confidence: 0.2, characterCount: 500, pageCount: 1, garbledRatio: 0.0)
private let imageOnlyQuality = QualityScore(
    confidence: 0, characterCount: 0, pageCount: 1, garbledRatio: 0.0)

@Suite("Orchestrator fallback routing")
struct OrchestratorFallbackTests {
    private let root: String
    private let db: ParchDatabase
    private let logger: Logger

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parch-fallback-tests-" + UUID().uuidString).path
        try FileManager.default.createDirectory(
            atPath: root, withIntermediateDirectories: true)
        var logger = Logger(label: "parch.tests")
        logger.logLevel = .critical
        self.logger = logger
        db = try ParchDatabase(dbQueue: try DatabaseQueue(), logger: logger)
    }

    private func addPDF(_ name: String) throws -> String {
        let path = (root as NSString).appendingPathComponent(name)
        try "not a real pdf".write(toFile: path, atomically: true, encoding: .utf8)
        try db.upsertDiscovered(filePath: path, fileSize: 10, mtime: 1000)
        return path
    }

    private func orchestrator(
        primary: ConversionEngine, policy: FallbackPolicy?
    ) -> Orchestrator {
        Orchestrator(
            db: db, primaryEngine: primary, fallbackPolicy: policy,
            logger: logger, maxWorkers: 1)
    }

    @Test func poorVisionQualityRoutesToPolicyEngine() async throws {
        let path = try addPDF("scan.pdf")
        let ovis = RecordingStub(engine: .ovis)
        var policy = FallbackPolicy(marker: nil, ovis: ovis)
        policy.isDigital = { @Sendable _ in false }

        let result = await orchestrator(
            primary: SidecarVisionStub(quality: poorQuality), policy: policy
        ).convertPending()

        #expect(result.converted == 1)
        #expect(ovis.convertedPaths == [path])
        let row = try #require(try db.fetchByPath(path))
        #expect(row.engine == "ovis")
    }

    /// Regression for the Devon canary finding: documents where Vision finds
    /// no text have nothing to transcribe, and ovis fabricates content for
    /// them. They must fail without consulting the fallback policy.
    @Test func imageOnlyPDFFailsWithoutFallback() async throws {
        let path = try addPDF("images.pdf")
        let ovis = RecordingStub(engine: .ovis)
        var policy = FallbackPolicy(marker: nil, ovis: ovis)
        policy.isDigital = { @Sendable _ in false }

        let result = await orchestrator(
            primary: SidecarVisionStub(quality: imageOnlyQuality), policy: policy
        ).convertPending()

        #expect(result.failed == 1)
        #expect(ovis.convertedPaths.isEmpty)
        let row = try #require(try db.fetchByPath(path))
        #expect(row.conversionStatus == .failed)
        #expect(row.failureReason?.contains("Image-only") == true)
    }

    @Test func failedFallbackRestoresVisionOutput() async throws {
        let path = try addPDF("flaky.pdf")
        let ovis = RecordingStub(engine: .ovis, fails: true)
        var policy = FallbackPolicy(marker: nil, ovis: ovis)
        policy.isDigital = { @Sendable _ in false }

        let result = await orchestrator(
            primary: SidecarVisionStub(quality: poorQuality), policy: policy
        ).convertPending()

        #expect(result.converted == 1)
        #expect(ovis.convertedPaths == [path])
        let row = try #require(try db.fetchByPath(path))
        #expect(row.engine == "vision")
        let markdown = try String(
            contentsOfFile: ScanRules.markdownPath(forPDF: path), encoding: .utf8)
        #expect(markdown == "vision output")
    }
}
