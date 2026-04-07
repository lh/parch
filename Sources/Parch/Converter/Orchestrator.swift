import Foundation
import Logging

struct ConvertResult: Sendable {
    var converted: Int = 0
    var deduplicated: Int = 0
    var failed: Int = 0
    var skipped: Int = 0
}

final class Orchestrator: Sendable {
    private let db: ParchDatabase
    private let converter: Converter
    private let logger: Logger
    private let maxWorkers: Int

    init(db: ParchDatabase, converter: Converter, logger: Logger, maxWorkers: Int = 2) {
        self.db = db
        self.converter = converter
        self.logger = logger
        self.maxWorkers = maxWorkers
    }

    func convertPending(limit: Int = 100, pathPrefix: String? = nil) async -> ConvertResult {
        var result = ConvertResult()

        let pending: [IndexedPDF]
        do {
            pending = try db.fetchPending(limit: limit, pathPrefix: pathPrefix)
        } catch {
            logger.error("Failed to fetch pending PDFs: \(error)")
            return result
        }

        if pending.isEmpty {
            logger.info("No pending conversions")
            return result
        }

        logger.info("Processing \(pending.count) pending PDFs with \(maxWorkers) workers")

        await withTaskGroup(of: SingleResult.self) { group in
            var inFlight = 0
            var index = 0

            while index < pending.count || inFlight > 0 {
                // Launch workers up to max
                while inFlight < maxWorkers && index < pending.count {
                    let pdf = pending[index]
                    index += 1
                    inFlight += 1
                    group.addTask { [self] in
                        await self.processSingle(pdf)
                    }
                }

                // Wait for one to complete
                if let single = await group.next() {
                    inFlight -= 1
                    switch single {
                    case .converted:
                        result.converted += 1
                    case .deduplicated:
                        result.deduplicated += 1
                    case .failed:
                        result.failed += 1
                    case .skipped:
                        result.skipped += 1
                    }
                }
            }
        }

        return result
    }

    // MARK: - Single PDF processing

    private enum SingleResult: Sendable {
        case converted
        case deduplicated
        case failed
        case skipped
    }

    private func processSingle(_ pdf: IndexedPDF) async -> SingleResult {
        let path = pdf.filePath

        // Check file still exists
        guard FileManager.default.fileExists(atPath: path) else {
            logger.info("PDF no longer exists: \(path)")
            do { try db.removePath(path) } catch {}
            return .skipped
        }

        // Check thermal state - back off if throttled
        if ProcessInfo.processInfo.thermalState == .critical ||
           ProcessInfo.processInfo.thermalState == .serious {
            logger.warning("Thermal pressure high, skipping \(path)")
            return .skipped
        }

        // Hash the file
        let hash: String
        do {
            hash = try FileHasher.sha256(of: URL(fileURLWithPath: path))
            try db.setHash(hash, forPath: path)
        } catch {
            logger.error("Failed to hash \(path): \(error)")
            try? db.markFailed(path: path, reason: "Hash failed: \(error.localizedDescription)")
            return .failed
        }

        // Check for existing conversion with same hash (dedup)
        do {
            let existing = try db.fetchByHash(hash)
            if let canonical = existing.first(where: {
                $0.conversionStatus == .complete && $0.canonicalPath != nil
            }) {
                // Duplicate - symlink to existing output
                logger.info("Dedup: \(path) matches \(canonical.filePath)")
                try converter.symlink(from: path, to: canonical.canonicalPath!)
                try db.markComplete(path: path, canonicalPath: canonical.canonicalPath!)
                return .deduplicated
            }
        } catch {
            logger.error("Dedup check failed for \(path): \(error)")
        }

        // Convert
        do {
            let outputDir = try converter.convert(pdfPath: path)
            try db.markComplete(path: path, canonicalPath: outputDir)
            logger.info("Converted: \(path)")
            return .converted
        } catch {
            let reason: String
            if let convError = error as? ConversionError {
                switch convError {
                case .condaNotFound(let p):
                    reason = "conda not found at \(p)"
                case .markerFailed(let code, let stderr):
                    reason = "marker exited \(code): \(stderr)"
                case .outputNotCreated(let p):
                    reason = "output not created at \(p)"
                }
            } else {
                reason = error.localizedDescription
            }
            logger.error("Failed to convert \(path): \(reason)")
            try? db.markFailed(path: path, reason: reason)
            return .failed
        }
    }
}
