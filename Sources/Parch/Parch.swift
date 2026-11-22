import ArgumentParser
import Logging

@main
struct Parch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parch",
        abstract: "Background PDF-to-markdown indexer",
        // Bump alongside an annotated git tag so a deployed binary can be
        // traced back to a commit.
        version: "0.3.0",
        subcommands: [
            Status.self,
            ListPending.self,
            ListFailed.self,
            Run.self,
            Convert.self,
            ConvertFile.self,
        ]
    )
}

// MARK: - Shared

func makeLogger(level: Logger.Level = .info) -> Logger {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardError(label: label)
        handler.logLevel = level
        return handler
    }
    return Logger(label: "parch")
}
