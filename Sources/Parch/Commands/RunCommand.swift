import ArgumentParser
import Foundation
import Logging

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan for PDFs, then convert pending files"
    )

    @Flag(name: .shortAndLong, help: "Show detailed output")
    var verbose: Bool = false

    @Flag(name: .long, help: "Scan only, do not convert")
    var scanOnly: Bool = false

    @Option(name: .shortAndLong, help: "Maximum PDFs to convert per run")
    var limit: Int = 50

    @Option(name: .shortAndLong, help: "Number of parallel workers")
    var workers: Int = 1

    @Option(name: .long, help: "Conda environment containing marker-pdf")
    var condaEnv: String = "marker"

    @Option(name: .long, help: "Conversion engine: auto, vision, marker, or ovis")
    var engine: EngineChoice = .auto

    @Option(name: .long, parsing: .upToNextOption, help: "Directories to scan (default: ~/Documents ~/Code)")
    var root: [String] = []

    private static let maxLogSize: UInt64 = 5 * 1024 * 1024 // 5 MB

    mutating func run() async throws {
        Self.rotateLogIfNeeded()
        let logger = makeLogger(level: verbose ? .debug : .info)

        guard let lock = ProcessLock.acquire() else {
            // Lock held by another parch run — silently exit. This is expected
            // when WatchPaths fires while a previous run is still going.
            return
        }
        _ = lock // hold for lifetime of run

        let db = try ParchDatabase(logger: logger)

        // Phase 1: scan
        let roots = root.isEmpty ? nil : root
        let scanner = Scanner(db: db, scanRoots: roots, logger: logger)
        print("Scanning for PDFs...")
        let scanResult = try scanner.scan()
        print("Scan: \(scanResult.discovered) found, \(scanResult.new) new, \(scanResult.updated) updated, \(scanResult.pruned) pruned")

        if scanOnly {
            return
        }

        // Phase 2: convert
        let (primary, fallback) = EngineFactory.make(choice: engine, condaEnv: condaEnv, logger: logger)
        let orchestrator = Orchestrator(db: db, primaryEngine: primary, fallbackPolicy: fallback, logger: logger, maxWorkers: workers)
        print("Converting pending PDFs (limit: \(limit), workers: \(workers))...")
        let convertResult = await orchestrator.convertPending(limit: limit)
        print("Convert: \(convertResult.converted) done, \(convertResult.deduplicated) deduped, \(convertResult.failed) failed, \(convertResult.skipped) skipped")
    }

    // MARK: - Log rotation

    private static func rotateLogIfNeeded() {
        let logPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parch/parch.log")
        let prevPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parch/parch.log.1")

        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogSize else { return }

        let fm = FileManager.default
        try? fm.removeItem(at: prevPath)
        try? fm.moveItem(at: logPath, to: prevPath)
    }
}
