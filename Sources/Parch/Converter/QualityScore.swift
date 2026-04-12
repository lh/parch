import Foundation

/// Quality metrics for Vision engine output, used to decide whether to fall back to marker.
struct QualityScore: Codable, Sendable {
    let confidence: Float
    let characterCount: Int
    let pageCount: Int
    let garbledRatio: Float

    /// Whether the output quality is acceptable for use.
    var isAcceptable: Bool {
        if confidence < 0.5 { return false }
        if garbledRatio > 0.30 { return false }
        if pageCount > 1 && characterCount / pageCount < 100 { return false }
        return true
    }

    /// Compute the ratio of single-character tokens to total tokens.
    /// High ratios indicate Vision read graphics text character-by-character.
    static func detectGarbledRatio(in text: String) -> Float {
        let commonSingleChars: Set<String> = ["a", "i", "-", "&", "/"]
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        guard !words.isEmpty else { return 0 }
        let garbled = words.filter { word in
            word.count == 1 && !commonSingleChars.contains(word.lowercased())
        }
        return Float(garbled.count) / Float(words.count)
    }
}
