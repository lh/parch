import ArgumentParser
import Logging

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan for PDFs and update the index"
    )

    @Flag(name: .shortAndLong, help: "Show detailed output")
    var verbose: Bool = false

    mutating func run() async throws {
        let logger = makeLogger(level: verbose ? .debug : .info)
        let db = try ParchDatabase(logger: logger)
        let scanner = Scanner(db: db, logger: logger)

        print("Scanning for PDFs...")
        let result = try scanner.scan()

        print("Scan complete:")
        print("  discovered: \(result.discovered)")
        print("  new:        \(result.new)")
        print("  updated:    \(result.updated)")
        print("  unchanged:  \(result.skipped)")
    }
}
