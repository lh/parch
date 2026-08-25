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
    private let fallbackPolicy: FallbackPolicy?
    private let logger: Logger
    private let maxWorkers: Int

    init(
        db: ParchDatabase,
        primaryEngine: ConversionEngine,
        fallbackPolicy: FallbackPolicy? = nil,
        logger: Logger,
        maxWorkers: Int = 2
    ) {
        self.db = db
        self.primaryEngine = primaryEngine
        self.fallbackPolicy = fallbackPolicy
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

    /// Force-convert a single PDF, bypassing the pending queue.
    /// Re-hashes and converts even if already complete, and deliberately skips
    /// dedup: the caller asked for this file to be converted, not linked to
    /// somebody else's output.
    func convertSingle(_ pdf: IndexedPDF) async -> ConvertResult {
        var result = ConvertResult()
        let single = await processSingle(pdf, force: true)
        switch single {
        case .converted:    result.converted += 1
        case .deduplicated: result.deduplicated += 1
        case .failed:       result.failed += 1
        case .skipped:      result.skipped += 1
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

    private func processSingle(_ pdf: IndexedPDF, force: Bool = false) async -> SingleResult {
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

        // Link to an existing conversion of the same content, unless the caller
        // forced this file to be converted on its own.
        if !force, let deduped = deduplicate(path: path, hash: hash) {
            return deduped
        }

        // Convert with primary engine, potentially falling back
        return await convertWithFallback(path: path)
    }

    /// Link `path` to an existing conversion of byte-identical content.
    /// Returns nil when no usable conversion exists and the file must be
    /// converted itself.
    private func deduplicate(path: String, hash: String) -> SingleResult? {
        let candidates: [IndexedPDF]
        do {
            candidates = try db.fetchByHash(hash)
        } catch {
            logger.error("Dedup check failed for \(path): \(error)")
            return nil
        }

        for canonical in candidates
        where canonical.filePath != path && canonical.conversionStatus == .complete {
            guard let canonicalDir = canonical.canonicalPath else { continue }

            // A `complete` row is only worth linking to while its markdown is
            // still there. Linking to a deleted conversion would leave a
            // dangling symlink and a row that claims complete forever, since
            // nothing rescans a file whose size and mtime never changed.
            guard ScanRules.hasMarkdownOutput(inDirectory: canonicalDir) else {
                logger.warning("Stale conversion for \(canonical.filePath): no markdown at \(canonicalDir), requeueing it")
                try? db.markPending(path: canonical.filePath)
                continue
            }

            do {
                try Symlinker.link(from: path, to: canonicalDir, logger: logger)
                try db.markComplete(
                    path: path,
                    canonicalPath: canonicalDir,
                    engine: canonical.engine.flatMap(Engine.init(rawValue:))
                )
            } catch {
                logger.error("Dedup failed for \(path): \(error)")
                return nil
            }

            logger.info("Dedup: \(path) matches \(canonical.filePath)")
            return .deduplicated
        }

        return nil
    }

    private func convertWithFallback(path: String) async -> SingleResult {
        // An earlier dedup may have left this file's output directory as a
        // symlink into another file's conversion. Engines write into that
        // directory, so converting through the link would overwrite the
        // canonical output with this file's content.
        guard clearSymlinkedOutput(forPDF: path) else {
            let reason = "Could not remove dedup symlink at \(ScanRules.outputDirectory(forPDF: path))"
            logger.error("\(reason), refusing to convert \(path)")
            try? db.markFailed(path: path, reason: reason)
            return .failed
        }

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

                // Pre-check: if Vision found no extractable text at all, this
                // is an image-only PDF (plots, photos, imaging exports). There
                // is nothing to transcribe, so no fallback can help: marker's
                // OCR produces nothing useful, and ovis fabricates plausible
                // text rather than failing (Devon canary, 2026-08-24). Mark
                // failed with a clear reason.
                if quality.characterCount == 0 {
                    logger.info("Image-only PDF (no extractable text): \(path)")
                    try? FileManager.default.removeItem(atPath: outputDir)
                    try? db.markFailed(path: path, reason: "Image-only PDF, no extractable text")
                    return .failed
                }

                if !quality.isAcceptable, let (fallback, reason) = fallbackPolicy?.choose(forPDF: path) {
                    logger.info("Vision quality low for \(path) (confidence=\(String(format: "%.2f", quality.confidence)), garbled=\(String(format: "%.2f", quality.garbledRatio))), retrying with \(fallback.engine) (\(reason))")

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

    /// Remove this PDF's output directory if it is a dedup symlink, so the
    /// conversion lands in its own directory. Returns false only if a symlink
    /// is present and could not be removed.
    private func clearSymlinkedOutput(forPDF path: String) -> Bool {
        let outputDir = ScanRules.outputDirectory(forPDF: path)
        guard let destination = ScanRules.symlinkDestination(of: outputDir) else { return true }
        do {
            try FileManager.default.removeItem(atPath: outputDir)
            logger.info("Removed dedup symlink \(outputDir) -> \(destination) before converting")
            return true
        } catch {
            logger.error("Could not remove dedup symlink \(outputDir): \(error)")
            return false
        }
    }

    private func formatError(_ error: Error) -> String {
        if let convError = error as? ConversionError {
            switch convError {
            case .condaNotFound(let p):
                return "conda not found at \(p)"
            case .markerFailed(let code, let stderr):
                return "marker exited \(code): \(stderr)"
            case .ovisFailed(let code, let stderr):
                return "ovis exited \(code): \(stderr)"
            case .outputNotCreated(let p):
                return "output not created at \(p)"
            case .visionFailed(let msg):
                return "vision failed: \(msg)"
            }
        }
        return error.localizedDescription
    }
}
