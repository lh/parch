import ArgumentParser
import Logging

struct Convert: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convert pending PDFs to markdown (no scan)"
    )

    @Flag(name: .shortAndLong, help: "Show detailed output")
    var verbose: Bool = false

    @Option(name: .shortAndLong, help: "Maximum PDFs to convert")
    var limit: Int = 50

    @Option(name: .shortAndLong, help: "Number of parallel workers")
    var workers: Int = 1

    @Option(name: .long, help: "Conda environment containing marker-pdf")
    var condaEnv: String = "marker"

    @Option(name: .long, help: "Conversion engine: auto, vision, or marker")
    var engine: EngineChoice = .auto

    @Option(name: .long, help: "Only convert PDFs under this directory")
    var path: String?

    mutating func run() async throws {
        let logger = makeLogger(level: verbose ? .debug : .info)

        guard let lock = ProcessLock.acquire() else {
            logger.info("Another parch process is running, skipping this invocation")
            return
        }
        _ = lock // hold for lifetime of run

        let db = try ParchDatabase(logger: logger)
        let (primary, fallback) = EngineFactory.make(choice: engine, condaEnv: condaEnv, logger: logger)
        let orchestrator = Orchestrator(db: db, primaryEngine: primary, fallbackEngine: fallback, logger: logger, maxWorkers: workers)

        let counts = try db.countByStatus()
        let pending = counts[.pending] ?? 0
        if let path {
            print("Converting (up to \(limit) under \(path), \(workers) workers)...")
        } else {
            print("Converting (up to \(limit) of \(pending) pending, \(workers) workers)...")
        }

        let result = await orchestrator.convertPending(limit: limit, pathPrefix: path)
        print("Done: \(result.converted) converted, \(result.deduplicated) deduped, \(result.failed) failed, \(result.skipped) skipped")
    }
}
