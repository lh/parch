import Foundation

enum ScanRules {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var defaultScanRoots: [String] {
        [
            home + "/Documents",
            home + "/Code",
        ]
    }

    private static let skippedDirectoryNames: Set<String> = [
        "node_modules",
        "__pycache__",
        ".venv",
        ".git",
        ".Trash",
        "DerivedData",
        ".build",
    ]

    private static let skippedPathPrefixes: [String] = [
        "/System",
        "/Library",
        "/Volumes/com.apple.TimeMachine",
        home + "/Library/Containers",
        home + "/Library/Caches",
        home + "/Library/Application Support",
        "/usr",
    ]

    static func shouldSkip(path: String) -> Bool {
        // Skip app bundles
        if path.contains(".app/Contents") {
            return true
        }

        // Skip system paths
        for prefix in skippedPathPrefixes {
            if path.hasPrefix(prefix) {
                return true
            }
        }

        // Skip if any path component is a known skip directory
        let components = (path as NSString).pathComponents
        for component in components {
            if skippedDirectoryNames.contains(component) {
                return true
            }
        }

        return false
    }

    static func isPDF(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".pdf")
    }

    /// Skip PDFs that have a sibling source file -- no point converting
    /// a PDF back to markdown when the original source is right there.
    private static let sourceExtensions = ["tex", "md", "markdown", "typ", "rst", "rmd"]

    static func hasSourceFile(forPDF pdfPath: String) -> Bool {
        let url = URL(fileURLWithPath: pdfPath)
        let stem = url.deletingPathExtension()
        for ext in sourceExtensions {
            if FileManager.default.fileExists(atPath: stem.appendingPathExtension(ext).path) {
                return true
            }
        }
        return false
    }

    /// The output directory for a given PDF path.
    /// /path/to/report.pdf -> /path/to/report/
    static func outputDirectory(forPDF pdfPath: String) -> String {
        let url = URL(fileURLWithPath: pdfPath)
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(stem).path
    }

    /// The expected markdown path for a given PDF.
    /// /path/to/report.pdf -> /path/to/report/report.md
    static func markdownPath(forPDF pdfPath: String) -> String {
        let url = URL(fileURLWithPath: pdfPath)
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent().appendingPathComponent(stem)
        return dir.appendingPathComponent(stem + ".md").path
    }
}
