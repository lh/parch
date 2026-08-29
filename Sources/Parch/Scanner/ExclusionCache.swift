import Foundation

/// Answers "is this path excluded from parch?" with the ancestor walk memoized
/// per directory.
///
/// Exclusion is inherited: a `.nomarker` file excludes its directory and every
/// descendant, so deciding one file means walking its whole ancestor chain.
/// A scan asks that question once per PDF, and PDFs cluster in directories --
/// a fixture directory holding 200 of them would re-walk the same chain 200
/// times. One walk here populates every directory it passes through.
///
/// The cache is a snapshot: a marker created while a scan is running is not
/// picked up until the next scan. Scans are cheap and run hourly, so the
/// staleness resolves itself.
struct ExclusionCache {
    private var byDirectory: [String: Bool] = [:]

    /// Whether `path` is excluded, either by a static scan rule or by an
    /// exclusion marker in one of its ancestor directories.
    mutating func isExcluded(path: String) -> Bool {
        if ScanRules.shouldSkip(path: path) {
            return true
        }
        return isExcludedDirectory((path as NSString).deletingLastPathComponent)
    }

    private mutating func isExcludedDirectory(_ dir: String) -> Bool {
        if let known = byDirectory[dir] {
            return known
        }

        // Walk up until we hit a marker, a directory we have already decided,
        // or the filesystem root. Every directory passed through on the way
        // shares the answer, so record them all in one go.
        var unresolved: [String] = []
        var current = dir
        var excluded = false

        while current.count > 1 {
            if let known = byDirectory[current] {
                excluded = known
                break
            }
            unresolved.append(current)
            if ScanRules.hasExclusionMarker(inDirectory: current) {
                excluded = true
                break
            }
            current = (current as NSString).deletingLastPathComponent
        }

        for directory in unresolved {
            byDirectory[directory] = excluded
        }
        return excluded
    }
}
