import CoreGraphics
import Foundation
import Logging
import PDFKit
import Vision

final class VisionEngine: ConversionEngine, Sendable {
    let engine: Engine = .vision
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func convert(pdfPath: String) throws -> String {
        let outputDir = ScanRules.outputDirectory(forPDF: pdfPath)
        let expectedMd = ScanRules.markdownPath(forPDF: pdfPath)

        guard let document = PDFDocument(url: URL(fileURLWithPath: pdfPath)) else {
            throw ConversionError.visionFailed("Could not open PDF: \(pdfPath)")
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ConversionError.visionFailed("PDF has no pages: \(pdfPath)")
        }

        var markdown = ""
        var totalConfidence: Float = 0
        var observationCount = 0

        for i in 0..<pageCount {
            guard let page = document.page(at: i) else { continue }
            let (text, pageConfidence, pageObservations) = try recognizePage(page)
            totalConfidence += pageConfidence
            observationCount += pageObservations
            if !text.isEmpty {
                if !markdown.isEmpty { markdown += "\n\n---\n\n" }
                markdown += text
            }
        }

        // Write markdown output
        let fm = FileManager.default
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        try markdown.write(toFile: expectedMd, atomically: true, encoding: .utf8)

        // Write quality sidecar for the Orchestrator to inspect
        let avgConfidence = observationCount > 0 ? totalConfidence / Float(observationCount) : 0
        let quality = QualityScore(
            confidence: avgConfidence,
            characterCount: markdown.count,
            pageCount: pageCount,
            garbledRatio: QualityScore.detectGarbledRatio(in: markdown)
        )
        let qualityPath = (outputDir as NSString).appendingPathComponent(".vision-quality.json")
        let data = try JSONEncoder().encode(quality)
        try data.write(to: URL(fileURLWithPath: qualityPath))

        logger.info("Vision: \(pageCount) pages, confidence=\(String(format: "%.2f", avgConfidence)), garbled=\(String(format: "%.2f", quality.garbledRatio)), chars=\(markdown.count)")

        return outputDir
    }

    // MARK: - Page recognition

    private func recognizePage(_ page: PDFPage) throws -> (text: String, totalConfidence: Float, count: Int) {
        let cgImage = try renderPage(page)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else {
            return ("", 0, 0)
        }

        var lines: [String] = []
        var totalConf: Float = 0
        for observation in observations {
            if let candidate = observation.topCandidates(1).first {
                lines.append(candidate.string)
                totalConf += candidate.confidence
            }
        }

        return (lines.joined(separator: "\n"), totalConf, observations.count)
    }

    /// Render a PDF page to a CGImage at 2x scale for OCR quality.
    private func renderPage(_ page: PDFPage) throws -> CGImage {
        let mediaBox = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0
        let width = Int(mediaBox.width * scale)
        let height = Int(mediaBox.height * scale)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw ConversionError.visionFailed("Could not create graphics context")
        }

        // White background
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // PDF pages use bottom-left origin, same as CGContext
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else {
            throw ConversionError.visionFailed("Could not render page to image")
        }
        return cgImage
    }
}
