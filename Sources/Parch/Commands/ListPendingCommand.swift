import ArgumentParser
import Logging

struct ListPending: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list-pending",
        abstract: "Show PDFs awaiting conversion"
    )

    @Option(name: .shortAndLong, help: "Maximum number of results")
    var limit: Int = 50

    mutating func run() async throws {
        let logger = makeLogger(level: .warning)
        let db = try ParchDatabase(logger: logger)
        let pending = try db.fetchPending(limit: limit)

        if pending.isEmpty {
            print("No pending conversions.")
            return
        }

        print("Pending conversions (\(pending.count)):")
        for pdf in pending {
            let sizeMB = String(format: "%.1f", Double(pdf.fileSize) / 1_048_576)
            print("  \(sizeMB) MB  \(pdf.filePath)")
        }
    }
}
