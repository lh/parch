import Foundation
import Testing
@testable import parch

/// Minimal engine stub for policy tests; convert is never called.
private struct InertEngine: ConversionEngine {
    let engine: Engine
    func convert(pdfPath: String) throws -> String { "" }
}

@Suite("Fallback policy")
struct FallbackPolicyTests {
    private let marker = InertEngine(engine: .marker)
    private let ovis = InertEngine(engine: .ovis)

    private func policy(
        marker: ConversionEngine?, ovis: ConversionEngine?, digital: Bool
    ) -> FallbackPolicy {
        var p = FallbackPolicy(marker: marker, ovis: ovis)
        p.isDigital = { @Sendable _ in digital }
        return p
    }

    @Test func scannedPrefersOvis() {
        let chosen = policy(marker: marker, ovis: ovis, digital: false).choose(forPDF: "/x.pdf")
        #expect(chosen?.engine.engine == .ovis)
    }

    @Test func digitalPrefersMarker() {
        let chosen = policy(marker: marker, ovis: ovis, digital: true).choose(forPDF: "/x.pdf")
        #expect(chosen?.engine.engine == .marker)
    }

    @Test func scannedFallsBackToMarkerWithoutOvis() {
        let chosen = policy(marker: marker, ovis: nil, digital: false).choose(forPDF: "/x.pdf")
        #expect(chosen?.engine.engine == .marker)
    }

    @Test func digitalFallsBackToOvisWithoutMarker() {
        let chosen = policy(marker: nil, ovis: ovis, digital: true).choose(forPDF: "/x.pdf")
        #expect(chosen?.engine.engine == .ovis)
    }

    @Test func noEnginesMeansNoFallback() {
        #expect(policy(marker: nil, ovis: nil, digital: false).choose(forPDF: "/x.pdf") == nil)
    }
}
