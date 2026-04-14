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
    private let primaryEngine: ConversionEngine
    private let fallbackEngine: ConversionEngine?
    private let logger: Logger
    private let maxWorkers: Int

    init(
        db: ParchDatabase,
        primaryEngine: ConversionEngine,
        fallbackEngine: ConversionEngine? = nil,
        logger: Logger,
        maxWorkers: Int = 2
    ) {
        self.db = db
        self.primaryEngine = primaryEngine
        self.fallbackEngine = fallbackEngine
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
                while inFlight < maxWorkers && index < pending.count {
                    let pdf = pending[index]
                    index += 1
                    inFlight += 1
                    group.addTask { [self] in
                        await self.processSingle(pdf)
                    }
                }

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
                logger.info("Dedup: \(path) matches \(canonical.filePath)")
                try Symlinker.link(from: path, to: canonical.canonicalPath!, logger: logger)
                try db.markComplete(path: path, canonicalPath: canonical.canonicalPath!, engine: canonical.engine.flatMap(Engine.init(rawValue:)))
                return .deduplicated
            }
        } catch {
            logger.error("Dedup check failed for \(path): \(error)")
        }

        // Convert with primary engine, potentially falling back
        return await convertWithFallback(path: path)
    }

    private func convertWithFallback(path: String) async -> SingleResult {
        // Try primary engine
        let outputDir: String
        let usedEngine: Engine
        do {
            outputDir = try primaryEngine.convert(pdfPath: path)
            usedEngine = primaryEngine.engine
        } catch {
            let reason = formatError(error)
            logger.error("Failed to convert \(path): \(reason)")
            try? db.markFailed(path: path, reason: reason)
            return .failed
        }

        // If primary was Vision, check output quality
        if primaryEngine.engine == .vision {
            let qualityPath = (outputDir as NSString).appendingPathComponent(".vision-quality.json")
            if let data = try? Data(contentsOf: URL(fileURLWithPath: qualityPath)),
               let quality = try? JSONDecoder().decode(QualityScore.self, from: data) {

                // Pre-check: if Vision found no extractable text at all, this is
                // an image-only PDF (scans, photos). Marker won't help — surya will
                // try raster OCR but typically runs out of MPS memory or produces
                // nothing useful. Skip the fallback, mark failed with a clear reason.
                if quality.characterCount == 0 {
                    logger.info("Image-only PDF (no extractable text): \(path)")
                    try? FileManager.default.removeItem(atPath: outputDir)
                    try? db.markFailed(path: path, reason: "Image-only PDF, no extractable text")
                    return .failed
                }

                if !quality.isAcceptable, let fallback = fallbackEngine {
                    logger.info("Vision quality low for \(path) (confidence=\(String(format: "%.2f", quality.confidence)), garbled=\(String(format: "%.2f", quality.garbledRatio))), retrying with \(fallback.engine)")

                    // Keep Vision's markdown in memory so we can restore it
                    // if the fallback fails. Partial Vision output is still
                    // better than marking the whole file failed.
                    let visionMdPath = ScanRules.markdownPath(forPDF: path)
                    let visionBackup = try? String(contentsOfFile: visionMdPath, encoding: .utf8)

                    do {
                        let fallbackDir = try fallback.convert(pdfPath: path)
                        try db.markComplete(path: path, canonicalPath: fallbackDir, engine: fallback.engine)
                        logger.info("Converted (fallback): \(path)")
                        return .converted
                    } catch {
                        let reason = formatError(error)
                        logger.warning("Fallback failed for \(path): \(reason), keeping Vision output")

                        // Restore Vision's markdown (marker may have overwritten it)
                        if let markdown = visionBackup {
                            try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
                            try? markdown.write(toFile: visionMdPath, atomically: true, encoding: .utf8)
                            try? db.markComplete(path: path, canonicalPath: outputDir, engine: .vision)
                            return .converted
                        } else {
                            try? db.markFailed(path: path, reason: "Vision low quality, fallback failed: \(reason)")
                            return .failed
                        }
                    }
                }
            }
        }

        // Primary succeeded with acceptable quality
        do {
            try db.markComplete(path: path, canonicalPath: outputDir, engine: usedEngine)
            logger.info("Converted: \(path)")
            return .converted
        } catch {
            logger.error("Failed to mark complete \(path): \(error)")
            return .failed
        }
    }

    private func formatError(_ error: Error) -> String {
        if let convError = error as? ConversionError {
            switch convError {
            case .condaNotFound(let p):
                return "conda not found at \(p)"
            case .markerFailed(let code, let stderr):
                return "marker exited \(code): \(stderr)"
            case .outputNotCreated(let p):
                return "output not created at \(p)"
            case .visionFailed(let msg):
                return "vision failed: \(msg)"
            }
        }
        return error.localizedDescription
    }
}
