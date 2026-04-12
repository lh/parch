import ArgumentParser
import Foundation
import Logging

/// Identifies which engine performed a conversion.
enum Engine: String, Codable, Sendable {
    case vision
    case marker
}

/// The user's engine preference from the CLI.
enum EngineChoice: String, CaseIterable, ExpressibleByArgument, Sendable {
    case auto
    case vision
    case marker
}

/// Shared error type for all conversion engines.
enum ConversionError: Error {
    case condaNotFound(String)
    case markerFailed(exitCode: Int32, stderr: String)
    case outputNotCreated(String)
    case visionFailed(String)
}

/// A conversion engine that turns a PDF into markdown.
protocol ConversionEngine: Sendable {
    /// Which engine this is, for database tracking.
    var engine: Engine { get }

    /// Convert a PDF to markdown. Returns the output directory path.
    func convert(pdfPath: String) throws -> String
}
