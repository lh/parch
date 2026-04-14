import Foundation
import Logging

struct ScanResult: Sendable {
    var discovered: Int = 0
    var new: Int = 0
    var updated: Int = 0
    var skipped: Int = 0
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

        // Phase 1: mdfind scoped to scan roots
        let mdfindPaths = try runMdfind()
        logger.info("mdfind returned \(mdfindPaths.count) PDFs")

        // Phase 2: filesystem walk for anything mdfind missed
        let walkPaths = try walkScanRoots(excluding: Set(mdfindPaths))
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

    // MARK: - mdfind

    private func runMdfind() throws -> [String] {
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

        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { !ScanRules.shouldSkip(path: $0) }
            .filter { !isInsideNomarkerDirectory($0) }
            .filter { !ScanRules.hasSourceFile(forPDF: $0) }
    }

    // MARK: - Filesystem walk

    private func walkScanRoots(excluding known: Set<String>) throws -> [String] {
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

                // Skip .nomarker directories and their descendants
                if values?.isDirectory == true {
                    let nomarkerPath = fileURL.appendingPathComponent(".nomarker").path
                    if fm.fileExists(atPath: nomarkerPath) {
                        logger.debug("Skipping .nomarker directory: \(path)")
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if ScanRules.isPDF(path) && !known.contains(path)
                    && !ScanRules.hasSourceFile(forPDF: path) {
                    found.append(path)
                }
            }
        }

        return found
    }

    // MARK: - .nomarker check

    /// Check if any ancestor directory contains a .nomarker file.
    /// Used for mdfind results where we don't walk the tree ourselves.
    private func isInsideNomarkerDirectory(_ path: String) -> Bool {
        let fm = FileManager.default
        var dir = (path as NSString).deletingLastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Walk up to home or root, checking each directory
        while dir.count > 1 && dir.hasPrefix(home) {
            let marker = (dir as NSString).appendingPathComponent(".nomarker")
            if fm.fileExists(atPath: marker) {
                return true
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return false
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
