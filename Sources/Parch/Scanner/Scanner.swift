import Foundation
import Logging

struct ScanResult: Sendable {
    var discovered: Int = 0
    var new: Int = 0
    var updated: Int = 0
    var skipped: Int = 0
    var pruned: Int = 0
}

final class Scanner: Sendable {
    private let db: ParchDatabase
    private let scanRoots: [String]
    private let logger: Logger

    init(db: ParchDatabase, scanRoots: [String]? = nil, logger: Logger) {
        self.db = db
        self.scanRoots = scanRoots ?? ScanRules.defaultScanRoots
        self.logger = logger
    }

    func scan() throws -> ScanResult {
        var result = ScanResult()
        var exclusions = ExclusionCache()

        // Phase 0: drop indexed files that are now excluded. Discovery filters
        // excluded paths, but filtering alone never reaches a file already in
        // the index: nothing else revisits those rows, so a directory excluded
        // after it was indexed would keep converting.
        result.pruned = try pruneExcluded(&exclusions)

        // Phase 1: mdfind scoped to scan roots
        let mdfindPaths = try runMdfind(&exclusions)
        logger.info("mdfind returned \(mdfindPaths.count) PDFs")

        // Phase 2: filesystem walk for anything mdfind missed
        let walkPaths = try walkScanRoots(excluding: Set(mdfindPaths), exclusions: &exclusions)
        logger.info("Filesystem walk found \(walkPaths.count) additional PDFs")

        let allPaths = mdfindPaths + walkPaths
        result.discovered = allPaths.count

        // Batch upsert into the index
        let entries = try gatherFileInfo(paths: allPaths)
        let batchSize = 500
        for start in stride(from: 0, to: entries.count, by: batchSize) {
            let end = min(start + batchSize, entries.count)
            let batch = Array(entries[start..<end])
            let counts = try db.upsertBatch(batch)
            result.new += counts.new
            result.updated += counts.updated
            result.skipped += counts.skipped
        }

        return result
    }

    // MARK: - Prune

    /// Remove indexed files that now sit under an excluded directory.
    ///
    /// Deleting the row rather than parking it is deliberate: a row left
    /// `pending` would be handed back by every `fetchPending` call and never
    /// convert, starving the queue of files that can. Rows come back on their
    /// own if the exclusion is lifted, since the next scan rediscovers them.
    private func pruneExcluded(_ exclusions: inout ExclusionCache) throws -> Int {
        let indexed = try db.allIndexedPaths()
        let excluded = indexed.filter { exclusions.isExcluded(path: $0) }
        guard !excluded.isEmpty else { return 0 }

        try db.removePaths(excluded)
        logger.info("Pruned \(excluded.count) indexed files now under an excluded directory")
        return excluded.count
    }

    // MARK: - mdfind

    private func runMdfind(_ exclusions: inout ExclusionCache) throws -> [String] {
        var args: [String] = []
        for root in scanRoots {
            args.append(contentsOf: ["-onlyin", root])
        }
        args.append("kMDItemFSName == '*.pdf'")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Read before waiting to avoid pipe buffer deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var kept: [String] = []
        for path in output.split(separator: "\n").map(String.init) {
            guard !exclusions.isExcluded(path: path) else { continue }
            guard !ScanRules.hasSourceFile(forPDF: path) else { continue }
            kept.append(path)
        }
        return kept
    }

    // MARK: - Filesystem walk

    private func walkScanRoots(
        excluding known: Set<String>, exclusions: inout ExclusionCache
    ) throws -> [String] {
        var found: [String] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]

        for root in scanRoots {
            let rootURL = URL(fileURLWithPath: root)
            guard fm.fileExists(atPath: root) else { continue }

            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { url, error in
                    return true // skip unreadable directories
                }
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let path = fileURL.standardizedFileURL.path

                if ScanRules.shouldSkip(path: path) {
                    enumerator.skipDescendants()
                    continue
                }

                let values = try? fileURL.resourceValues(forKeys: Set(keys))

                // Skip symlinks entirely. Following them would reach outside the
                // declared scan roots (e.g. into cloud storage), which triggers
                // surprise TCC prompts and conversions of files the user didn't
                // intend to index. If you want cloud storage scanned, add it
                // as an explicit scan root.
                if values?.isSymbolicLink == true {
                    if values?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                // Skip excluded directories and their descendants. Pruning the
                // walk here is what keeps the cost down; the per-file check
                // below is the backstop for paths the walk never gated.
                if values?.isDirectory == true {
                    if ScanRules.hasExclusionMarker(inDirectory: path) {
                        logger.debug("Skipping excluded directory: \(path)")
                        enumerator.skipDescendants()
                    }
                    continue
                }

                // The directory check above prunes whole subtrees, but it only
                // fires for directories the enumerator hands back -- never for
                // a scan root itself. Re-check the file so a marker at the root
                // of an explicit `--root` still excludes it.
                if ScanRules.isPDF(path) && !known.contains(path)
                    && !exclusions.isExcluded(path: path)
                    && !ScanRules.hasSourceFile(forPDF: path) {
                    found.append(path)
                }
            }
        }

        return found
    }

    // MARK: - File info

    private func gatherFileInfo(paths: [String]) throws -> [(filePath: String, fileSize: Int64, mtime: Double)] {
        var entries: [(filePath: String, fileSize: Int64, mtime: Double)] = []
        entries.reserveCapacity(paths.count)

        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize,
                  let date = values.contentModificationDate else {
                logger.debug("Could not stat \(path), skipping")
                continue
            }
            entries.append((filePath: path, fileSize: Int64(size), mtime: date.timeIntervalSince1970))
        }

        return entries
    }
}
