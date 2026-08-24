import Foundation
import Logging

final class MarkerEngine: ConversionEngine, Sendable {
    let engine: Engine = .marker

    private let condaPath: String
    private let condaEnv: String
    private let logger: Logger

    init(condaEnv: String = "marker", logger: Logger) {
        self.condaPath = CondaLocator.find()
        self.condaEnv = condaEnv
        self.logger = logger
    }

    /// Whether conda and the marker environment appear to be installed.
    static func isAvailable(condaEnv: String = "marker") -> Bool {
        CondaLocator.envExists(condaEnv)
    }

    /// Convert a single PDF to markdown using marker_single via conda.
    /// Returns the path to the output directory.
    func convert(pdfPath: String) throws -> String {
        let outputDir = ScanRules.outputDirectory(forPDF: pdfPath)

        guard FileManager.default.fileExists(atPath: condaPath) else {
            throw ConversionError.condaNotFound(condaPath)
        }

        // marker_single writes into a subdirectory of --output_dir named after the PDF stem.
        // We pass the parent directory so the output lands where we expect.
        let parentDir = (outputDir as NSString).deletingLastPathComponent

        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nice")
        process.arguments = [
            "-n", "20",
            condaPath, "run", "-n", condaEnv,
            "marker_single", pdfPath, "--output_dir", parentDir,
        ]
        process.qualityOfService = .background
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

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
            if FileManager.default.fileExists(atPath: outputDir) {
                logger.debug("Markdown at expected path not found, but output dir exists: \(outputDir)")
            } else {
                throw ConversionError.outputNotCreated(expectedMd)
            }
        }

        return outputDir
    }
}
