import Foundation
import PDFKit

/// Probes whether a PDF carries a usable embedded text layer.
enum PDFTextLayer {
    /// Pages sampled from the front of the document.
    static let sampledPages = 5

    /// Below this many text-layer characters per sampled page the document
    /// is treated as scanned. From the 2026-08-24 Devon corpus probe:
    /// scanned documents measured 0 chars/page, the sparsest digital one 47.
    static let charsPerPageThreshold = 25

    @Sendable
    static func hasSubstantialText(atPath path: String) -> Bool {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)),
              doc.pageCount > 0 else {
            return false
        }
        let pages = min(doc.pageCount, sampledPages)
        var chars = 0
        for i in 0..<pages {
            chars += doc.page(at: i)?.string?.count ?? 0
        }
        return chars / pages >= charsPerPageThreshold
    }
}
