import ArgumentParser
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
    var workers: Int = 2

    @Option(name: .long, help: "Conda environment containing marker-pdf")
    var condaEnv: String = "marker"

    mutating func run() async throws {
        let logger = makeLogger(level: verbose ? .debug : .info)
        let db = try ParchDatabase(logger: logger)

        // Phase 1: scan
        let scanner = Scanner(db: db, logger: logger)
        print("Scanning for PDFs...")
        let scanResult = try scanner.scan()
        print("Scan: \(scanResult.discovered) found, \(scanResult.new) new, \(scanResult.updated) updated")

        if scanOnly {
            return
        }

        // Phase 2: convert
        let converter = Converter(condaEnv: condaEnv, logger: logger)
        let orchestrator = Orchestrator(db: db, converter: converter, logger: logger, maxWorkers: workers)
        print("Converting pending PDFs (limit: \(limit), workers: \(workers))...")
        let convertResult = await orchestrator.convertPending(limit: limit)
        print("Convert: \(convertResult.converted) done, \(convertResult.deduplicated) deduped, \(convertResult.failed) failed, \(convertResult.skipped) skipped")
    }
}
