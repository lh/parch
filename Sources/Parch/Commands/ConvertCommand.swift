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
    var workers: Int = 2

    mutating func run() async throws {
        let logger = makeLogger(level: verbose ? .debug : .info)
        let db = try ParchDatabase(logger: logger)
        let converter = Converter(logger: logger)
        let orchestrator = Orchestrator(db: db, converter: converter, logger: logger, maxWorkers: workers)

        let counts = try db.countByStatus()
        let pending = counts[.pending] ?? 0
        print("Converting (up to \(limit) of \(pending) pending, \(workers) workers)...")

        let result = await orchestrator.convertPending(limit: limit)
        print("Done: \(result.converted) converted, \(result.deduplicated) deduped, \(result.failed) failed, \(result.skipped) skipped")
    }
}
