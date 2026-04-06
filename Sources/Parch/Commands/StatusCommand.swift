import ArgumentParser
import Logging

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show index summary"
    )

    mutating func run() async throws {
        let logger = makeLogger(level: .warning)
        let db = try ParchDatabase(logger: logger)
        let counts = try db.countByStatus()
        let total = try db.totalCount()

        let complete = counts[.complete] ?? 0
        let pending = counts[.pending] ?? 0
        let failed = counts[.failed] ?? 0
        let inProgress = counts[.inProgress] ?? 0

        print("Parch index: \(total) PDFs tracked")
        print("  complete:    \(complete)")
        print("  pending:     \(pending)")
        print("  in progress: \(inProgress)")
        print("  failed:      \(failed)")
    }
}
