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

    /// Marker file that excludes its directory and everything beneath it.
    /// Named for the Marker engine, which was the only engine when the
    /// mechanism was added; it now excludes a directory from parch entirely,
    /// whichever engine would have run.
    static let exclusionMarkerName = ".nomarker"

    /// Whether `dir` itself carries an exclusion marker. Says nothing about
    /// its ancestors -- use `ExclusionCache` to ask about a whole path.
    static func hasExclusionMarker(inDirectory dir: String) -> Bool {
        let marker = (dir as NSString).appendingPathComponent(exclusionMarkerName)
        return FileManager.default.fileExists(atPath: marker)
    }

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

    /// Whether the PDF has a same-stem sibling with one of `extensions` --
    /// no point converting a PDF back to markdown when the original source is
    /// right there. Only the same stem counts: a `.tex` elsewhere in the
    /// directory is as likely to be a document that includes this PDF as a
    /// figure, or one that cites it, as the PDF's own source.
    ///
    /// The candidate is built by string concatenation rather than
    /// `URL.appendingPathExtension`, and must be a regular file, so that no
    /// extension can resolve to the conversion output directory (the bare
    /// stem) and shadow every converted PDF.
    static func hasSourceFile(forPDF pdfPath: String, extensions: Set<String>) -> Bool {
        let stem = (pdfPath as NSString).deletingPathExtension
        let fm = FileManager.default
        for ext in extensions where !ext.isEmpty {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: stem + "." + ext, isDirectory: &isDirectory), !isDirectory.boolValue {
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

    /// Whether a conversion output directory still holds usable markdown.
    /// An index row claiming `complete` is not evidence the output survived:
    /// output directories get deleted, and a dedup symlink dangles as soon as
    /// its target goes away. The markdown filename depends on which engine and
    /// which PDF stem produced it, so any non-empty `.md` counts.
    static func hasMarkdownOutput(inDirectory dir: String) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return false }
        return entries.contains { entry in
            guard entry.lowercased().hasSuffix(".md") else { return false }
            let full = (dir as NSString).appendingPathComponent(entry)
            let size = try? URL(fileURLWithPath: full)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize
            return (size ?? 0) > 0
        }
    }

    /// The destination of `path` if it is a symbolic link, otherwise nil.
    static func symlinkDestination(of path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }
}
