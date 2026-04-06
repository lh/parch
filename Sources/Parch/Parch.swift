import ArgumentParser
import Logging

@main
struct Parch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parch",
        abstract: "Background PDF-to-markdown indexer",
        subcommands: [
            Status.self,
            ListPending.self,
            ListFailed.self,
            Run.self,
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
