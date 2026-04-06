import ArgumentParser
import Logging

struct ListFailed: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-failed",
        abstract: "Show PDFs that failed conversion"
    )

    mutating func run() async throws {
        let logger = makeLogger(level: .warning)
        let db = try ParchDatabase(logger: logger)
        let failed = try db.fetchFailed()

        if failed.isEmpty {
            print("No failed conversions.")
            return
        }

        print("Failed conversions (\(failed.count)):")
        for pdf in failed {
            let reason = pdf.failureReason ?? "unknown"
            print("  \(pdf.filePath)")
            print("    reason: \(reason)")
        }
    }
}
