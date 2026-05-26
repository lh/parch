import ArgumentParser
import Foundation
import Logging

struct ConvertFile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert-file",
        abstract: "Force-convert a single PDF by path (even if already converted)"
    )

    @Argument(help: "Path to the PDF file")
    var path: String

    @Flag(name: .shortAndLong, help: "Show detailed output")
    var verbose: Bool = false

    @Option(name: .long, help: "Conda environment containing marker-pdf")
    var condaEnv: String = "marker"

    @Option(name: .long, help: "Conversion engine: auto, vision, or marker")
    var engine: EngineChoice = .auto

    mutating func run() async throws {
        let logger = makeLogger(level: verbose ? .debug : .info)

        // Resolve to an absolute, standardized path
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path

        guard FileManager.default.fileExists(atPath: resolved) else {
            print("Error: file not found: \(resolved)")
            throw ExitCode.failure
        }
        guard ScanRules.isPDF(resolved) else {
            print("Error: not a PDF: \(resolved)")
            throw ExitCode.failure
        }

        // Stat the file so the row matches current size/mtime
        let url = URL(fileURLWithPath: resolved)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard let size = values.fileSize, let date = values.contentModificationDate else {
            print("Error: cannot stat: \(resolved)")
            throw ExitCode.failure
        }

        // Serialize with any running parch process
        guard let lock = ProcessLock.acquire() else {
            print("Another parch process is running; try again shortly")
            throw ExitCode.failure
        }
        _ = lock

        let db = try ParchDatabase(logger: logger)

        // Ensure the row exists; upsert handles both new files and
        // existing rows whose size/mtime have changed.
        try db.upsertDiscovered(
            filePath: resolved,
            fileSize: Int64(size),
            mtime: date.timeIntervalSince1970
        )

        guard let pdf = try db.fetchByPath(resolved) else {
            print("Error: failed to index \(resolved)")
            throw ExitCode.failure
        }

        let (primary, fallback) = EngineFactory.make(choice: engine, condaEnv: condaEnv, logger: logger)
        let orchestrator = Orchestrator(
            db: db,
            primaryEngine: primary,
            fallbackEngine: fallback,
            logger: logger,
            maxWorkers: 1
        )

        print("Converting \(resolved)...")
        let result = await orchestrator.convertSingle(pdf)

        if result.converted > 0 {
            let outDir = ScanRules.outputDirectory(forPDF: resolved)
            print("Done: converted -> \(outDir)")
        } else if result.deduplicated > 0 {
            print("Done: deduplicated (matched existing conversion)")
        } else if result.failed > 0 {
            if let refreshed = try? db.fetchByPath(resolved), let reason = refreshed.failureReason {
                print("Failed: \(reason)")
            } else {
                print("Failed")
            }
            throw ExitCode.failure
        } else {
            print("Skipped")
        }
    }
}
