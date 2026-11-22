import Foundation

/// User settings read from `~/.parch/config.json`.
///
/// Every key is optional; a missing file or a missing key means "use the
/// default". A value that is present replaces the default outright rather than
/// extending it, so a list can also drop a default the user does not want.
///
/// Malformed input is an error, never a silent fallback. The source-extension
/// list drives retroactive pruning, so a misread config can remove most of the
/// index in one scan -- and once the config is fixed, everything it removed
/// comes back as pending and reconverts.
struct ParchConfig: Equatable {
    /// Extensions of files a PDF may have been generated from. A PDF with a
    /// same-stem sibling carrying one of these is skipped: the source is
    /// already readable, so converting its rendered output is wasted work.
    var sourceExtensions: Set<String>

    static let defaultSourceExtensions: Set<String> = [
        "tex", "md", "markdown", "typ", "rst", "rmd", "qmd",
    ]

    static let defaults = ParchConfig(sourceExtensions: defaultSourceExtensions)

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".parch/config.json")
    }

    private static let knownKeys: Set<String> = ["sourceExtensions"]

    /// Loads the config at `url`, or the defaults if no file exists there.
    static func load(from url: URL = defaultURL) throws -> ParchConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaults
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ParchConfigError(path: url.path, problem: "cannot be read: \(error.localizedDescription)")
        }
        return try parse(data, path: url.path)
    }

    static func parse(_ data: Data, path: String) throws -> ParchConfig {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParchConfigError(path: path, problem: "is not valid JSON")
        }
        guard let dictionary = object as? [String: Any] else {
            throw ParchConfigError(path: path, problem: "must be a JSON object")
        }

        // With replace semantics a misspelt key would quietly leave the
        // defaults in force, which is exactly what the user was trying to
        // change. Reject it instead.
        let unknown = Set(dictionary.keys).subtracting(knownKeys)
        guard unknown.isEmpty else {
            throw ParchConfigError(
                path: path,
                problem: "has unknown keys: \(unknown.sorted().joined(separator: ", ")) "
                    + "(known: \(knownKeys.sorted().joined(separator: ", ")))")
        }

        var config = defaults
        if let raw = dictionary["sourceExtensions"] {
            guard let list = raw as? [String] else {
                throw ParchConfigError(path: path, problem: "sourceExtensions must be an array of strings")
            }
            config.sourceExtensions = try Set(list.map { try normalizeExtension($0, path: path) })
        }
        return config
    }

    /// Canonical form of one configured extension: lowercase, no leading dot.
    ///
    /// The sibling check builds `stem + "." + extension`, so some inputs are
    /// actively dangerous rather than merely useless: `pdf` names the PDF
    /// itself and an empty extension names the bare stem, which is the
    /// conversion output directory. Either would mark every converted PDF as
    /// shadowed and prune it.
    static func normalizeExtension(_ raw: String, path: String) throws -> String {
        var ext = raw.trimmingCharacters(in: .whitespaces).lowercased()
        while ext.hasPrefix(".") {
            ext.removeFirst()
        }
        guard !ext.isEmpty else {
            throw ParchConfigError(path: path, problem: "sourceExtensions contains an empty entry (\"\(raw)\")")
        }
        guard ext != "pdf" else {
            throw ParchConfigError(path: path, problem: "sourceExtensions cannot contain \"pdf\": every PDF would count as its own source")
        }
        let forbidden = CharacterSet(charactersIn: "/.").union(.whitespacesAndNewlines)
        guard ext.rangeOfCharacter(from: forbidden) == nil else {
            throw ParchConfigError(path: path, problem: "sourceExtensions entry \"\(raw)\" is not a plain file extension")
        }
        return ext
    }
}

struct ParchConfigError: Error, CustomStringConvertible {
    let path: String
    let problem: String

    var description: String { "Config file \(path) \(problem)" }
}
