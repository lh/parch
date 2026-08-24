import Foundation

/// Chooses which engine retries a PDF whose Vision output was poor.
///
/// Scanned documents (no usable text layer) OCR best through ovis — on the
/// Devon canary it kept label-value pairs and symbols intact where Vision
/// scattered them, at a third of marker's OCR wall time. Digital documents
/// keep marker, which reads the text layer exactly where ovis can drop the
/// odd character. Either engine covers for the other when only one is
/// installed.
///
/// This policy is only consulted for poor-but-nonempty Vision output.
/// Documents where Vision finds no text at all never reach it: they have
/// nothing to transcribe, and the canary showed ovis fabricates text for
/// pure-image pages rather than failing.
struct FallbackPolicy: Sendable {
    let marker: ConversionEngine?
    let ovis: ConversionEngine?

    /// Injectable for tests; defaults to the PDFKit text-layer probe.
    var isDigital: @Sendable (String) -> Bool = PDFTextLayer.hasSubstantialText(atPath:)

    /// The engine to retry with and the reason it was chosen, or nil when
    /// no fallback engine is installed.
    func choose(forPDF path: String) -> (engine: ConversionEngine, reason: String)? {
        if isDigital(path) {
            if let marker { return (marker, "digital: text layer present") }
            if let ovis { return (ovis, "digital, but marker not installed") }
        } else {
            if let ovis { return (ovis, "scanned: no text layer") }
            if let marker { return (marker, "scanned, but ovis not installed") }
        }
        return nil
    }
}
