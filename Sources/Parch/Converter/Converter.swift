import Foundation
import Logging

enum ConversionError: Error {
    case markerNotFound(String)
    case markerFailed(exitCode: Int32, stderr: String)
    case outputNotCreated(String)
}

final class Converter: Sendable {
    private let markerPath: String
    private let logger: Logger

    init(logger: Logger) {
        // Resolve marker_single location
        self.markerPath = Self.findMarker()
        self.logger = logger
    }

    /// Convert a single PDF to markdown using marker_single.
    /// Returns the path to the output directory.
    func convert(pdfPath: String) throws -> String {
        let outputDir = ScanRules.outputDirectory(forPDF: pdfPath)

        guard FileManager.default.fileExists(atPath: markerPath) else {
            throw ConversionError.markerNotFound(markerPath)
        }

        // marker_single writes into a subdirectory of --output_dir named after the PDF stem.
        // We pass the parent directory so the output lands where we expect.
        let parentDir = (outputDir as NSString).deletingLastPathComponent

        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = ["-n", "20", markerPath, pdfPath, "--output_dir", parentDir]
        process.qualityOfService = .background
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        // Force CPU to avoid MPS/Metal bugs in surya-ocr
        var env = ProcessInfo.processInfo.environment
        env["TORCH_DEVICE"] = "cpu"
        process.environment = env

        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderrOutput = String(data: stderrData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw ConversionError.markerFailed(
                exitCode: process.terminationStatus,
                stderr: String(stderrOutput.suffix(500))
            )
        }

        // Verify output was created
        let expectedMd = ScanRules.markdownPath(forPDF: pdfPath)
        if !FileManager.default.fileExists(atPath: expectedMd) {
            // marker_single may name the output directory slightly differently
            // (e.g. spaces, special chars). Check if the output dir exists at all.
            if FileManager.default.fileExists(atPath: outputDir) {
                logger.debug("Markdown at expected path not found, but output dir exists: \(outputDir)")
            } else {
                throw ConversionError.outputNotCreated(expectedMd)
            }
        }

        return outputDir
    }

    /// Create a symlink from the duplicate's expected output to the canonical output.
    func symlink(from duplicatePdfPath: String, to canonicalOutputDir: String) throws {
        let linkDir = ScanRules.outputDirectory(forPDF: duplicatePdfPath)
        let fm = FileManager.default

        // Don't overwrite existing real directory
        if fm.fileExists(atPath: linkDir) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: linkDir, isDirectory: &isDir)
            if isDir.boolValue {
                // Check if it's already a symlink pointing to the right place
                if let dest = try? fm.destinationOfSymbolicLink(atPath: linkDir),
                   dest == canonicalOutputDir {
                    return // already correct
                }
                // Real directory exists - don't touch it
                logger.warning("Output directory already exists at \(linkDir), not symlinking")
                return
            }
        }

        // Create parent directory if needed
        let parent = (linkDir as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        try fm.createSymbolicLink(atPath: linkDir, withDestinationPath: canonicalOutputDir)
        logger.info("Symlinked \(linkDir) -> \(canonicalOutputDir)")
    }

    // MARK: - Marker discovery

    private static func findMarker() -> String {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/marker_single").path,
            "/usr/local/bin/marker_single",
            "/opt/homebrew/bin/marker_single",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return candidates[0] // default, will fail with clear error
    }
}
