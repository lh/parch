import Foundation
import Logging

/// Creates symlinks from duplicate PDF output directories to canonical ones.
enum Symlinker {
    static func link(from duplicatePdfPath: String, to canonicalOutputDir: String, logger: Logger) throws {
        let linkDir = ScanRules.outputDirectory(forPDF: duplicatePdfPath)
        let fm = FileManager.default

        // Don't overwrite existing real directory
        if fm.fileExists(atPath: linkDir) {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: linkDir, isDirectory: &isDir)
            if isDir.boolValue {
                if let dest = try? fm.destinationOfSymbolicLink(atPath: linkDir),
                   dest == canonicalOutputDir {
                    return // already correct
                }
                logger.warning("Output directory already exists at \(linkDir), not symlinking")
                return
            }
        }

        let parent = (linkDir as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        try fm.createSymbolicLink(atPath: linkDir, withDestinationPath: canonicalOutputDir)
        logger.info("Symlinked \(linkDir) -> \(canonicalOutputDir)")
    }
}
