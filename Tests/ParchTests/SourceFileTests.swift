import Foundation
import GRDB
import Logging
import Testing
@testable import parch

/// Runs `body` with a fresh temporary directory tree that is cleaned up after.
private func withTempTree(_ body: (String) throws -> Void) throws {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("parch-source-" + UUID().uuidString)
        .resolvingSymlinksInPath().path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try body(dir)
}

private func writeFile(_ path: String, _ contents: String = "x") throws {
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
}

private func join(_ dir: String, _ name: String) -> String {
    (dir as NSString).appendingPathComponent(name)
}

private func parse(_ json: String) throws -> ParchConfig {
    try ParchConfig.parse(Data(json.utf8), path: "/test/config.json")
}

@Suite("Config")
struct ParchConfigTests {

    @Test func missingFileGivesDefaults() throws {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/config.json")
        #expect(try ParchConfig.load(from: url) == .defaults)
    }

    @Test func defaultsIncludeQuarto() {
        #expect(ParchConfig.defaultSourceExtensions.contains("qmd"))
        #expect(!ParchConfig.defaultSourceExtensions.contains("docx"))
    }

    @Test func emptyObjectGivesDefaults() throws {
        #expect(try parse("{}") == .defaults)
    }

    @Test func listReplacesDefaults() throws {
        let config = try parse(#"{"sourceExtensions": ["tex", "docx"]}"#)
        #expect(config.sourceExtensions == ["tex", "docx"])
    }

    /// An empty list is a deliberate choice: it switches the sibling-source
    /// rule off, rather than falling back to the defaults.
    @Test func emptyListDisablesTheRule() throws {
        #expect(try parse(#"{"sourceExtensions": []}"#).sourceExtensions.isEmpty)
    }

    @Test func entriesAreNormalized() throws {
        let config = try parse(#"{"sourceExtensions": [".TEX", " Md ", "..typ", "tex"]}"#)
        #expect(config.sourceExtensions == ["tex", "md", "typ"])
    }

    @Test(arguments: ["pdf", ".PDF", "", ".", "  ", "a/b", "a b", "tar.gz"])
    func rejectsDangerousOrUnusableEntries(_ entry: String) throws {
        let json = String(
            data: try JSONSerialization.data(withJSONObject: ["sourceExtensions": [entry]]),
            encoding: .utf8)!
        #expect(throws: ParchConfigError.self) { try parse(json) }
    }

    /// A misspelt key must not leave the defaults silently in force.
    @Test func rejectsUnknownKeys() throws {
        #expect(throws: ParchConfigError.self) {
            try parse(#"{"sourceExtension": ["tex"]}"#)
        }
    }

    @Test(arguments: [
        #"{"sourceExtensions": "tex"}"#,
        #"{"sourceExtensions": ["tex", 1]}"#,
        #"{"sourceExtensions": null}"#,
        #"["tex"]"#,
        #"{"sourceExtensions": ["tex"]"#,
        "",
    ])
    func rejectsMalformedInput(_ json: String) throws {
        #expect(throws: ParchConfigError.self) { try parse(json) }
    }

    @Test func loadReadsFileFromDisk() throws {
        try withTempTree { dir in
            let path = join(dir, "config.json")
            try writeFile(path, #"{"sourceExtensions": ["org"]}"#)
            let config = try ParchConfig.load(from: URL(fileURLWithPath: path))
            #expect(config.sourceExtensions == ["org"])
        }
    }

    /// What the user sees when `parch run` refuses a broken config: the
    /// message must name the file and the problem.
    @Test func errorMessageNamesFileAndProblem() throws {
        do {
            _ = try parse(#"{"sourceExtensions": ["pdf"]}"#)
            Issue.record("expected an error")
        } catch {
            let message = Parch.message(for: error)
            #expect(message.contains("/test/config.json"))
            #expect(message.contains("pdf"))
        }
    }
}

@Suite("Sibling source detection")
struct SiblingSourceTests {
    private let extensions = ParchConfig.defaultSourceExtensions

    @Test func sameStemSiblingCounts() throws {
        try withTempTree { dir in
            try writeFile(join(dir, "report.qmd"))
            #expect(ScanRules.hasSourceFile(forPDF: join(dir, "report.pdf"), extensions: extensions))
        }
    }

    @Test func differentStemDoesNotCount() throws {
        try withTempTree { dir in
            try writeFile(join(dir, "main.tex"))
            #expect(!ScanRules.hasSourceFile(forPDF: join(dir, "figure.pdf"), extensions: extensions))
        }
    }

    @Test func extensionOutsideTheListDoesNotCount() throws {
        try withTempTree { dir in
            try writeFile(join(dir, "letter.docx"))
            #expect(!ScanRules.hasSourceFile(forPDF: join(dir, "letter.pdf"), extensions: extensions))
        }
    }

    /// Every converted PDF has an output directory named after its stem. No
    /// extension -- not even one that slipped past config validation -- may
    /// make that directory look like a source file.
    @Test func outputDirectoryIsNeverASource() throws {
        try withTempTree { dir in
            let pdf = join(dir, "report.pdf")
            try FileManager.default.createDirectory(
                atPath: ScanRules.outputDirectory(forPDF: pdf), withIntermediateDirectories: true)
            #expect(!ScanRules.hasSourceFile(forPDF: pdf, extensions: ["", "tex"]))
        }
    }

    @Test func directoryWithSourceExtensionDoesNotCount() throws {
        try withTempTree { dir in
            try FileManager.default.createDirectory(
                atPath: join(dir, "report.tex"), withIntermediateDirectories: true)
            #expect(!ScanRules.hasSourceFile(forPDF: join(dir, "report.pdf"), extensions: ["tex"]))
        }
    }
}

@Suite("Scan pruning by source file")
struct SourcePruningTests {
    private func makeLogger() -> Logger {
        var logger = Logger(label: "parch.tests")
        logger.logLevel = .critical
        return logger
    }

    private func makeDB() throws -> ParchDatabase {
        try ParchDatabase(dbQueue: try DatabaseQueue(), logger: makeLogger())
    }

    private func makeScanner(_ db: ParchDatabase, root: String,
                             extensions: Set<String> = ParchConfig.defaultSourceExtensions) -> parch.Scanner {
        Scanner(db: db, scanRoots: [root], sourceExtensions: extensions, logger: makeLogger())
    }

    // Membership assertions throughout: where Spotlight indexes temporary
    // directories, mdfind reports `/private/var/...` for a seeded `/var/...`.

    /// The bug this fixes: a PDF indexed before its source sat beside it (or
    /// before its source extension was on the list) kept its row forever.
    @Test func scanPrunesIndexedPDFWhoseSourceAppearedLater() throws {
        try withTempTree { root in
            let pdf = join(root, "notes.pdf")
            try writeFile(pdf, "%PDF-1.4")
            let db = try makeDB()
            try db.upsertDiscovered(filePath: pdf, fileSize: 8, mtime: 1000)

            try writeFile(join(root, "notes.qmd"))
            let result = try makeScanner(db, root: root).scan()

            #expect(result.pruned == 1)
            #expect(!(try db.allIndexedPaths()).contains { $0.hasSuffix("/notes.pdf") })
        }
    }

    /// A pruned file must not be re-added by discovery, or every scan would
    /// prune and re-index the same row.
    @Test func prunedPDFIsNotRediscovered() throws {
        try withTempTree { root in
            let pdf = join(root, "notes.pdf")
            try writeFile(pdf, "%PDF-1.4")
            try writeFile(join(root, "notes.tex"))
            let db = try makeDB()
            try db.upsertDiscovered(filePath: pdf, fileSize: 8, mtime: 1000)
            let scanner = makeScanner(db, root: root)

            let first = try scanner.scan()
            let second = try scanner.scan()

            #expect(first.pruned == 1)
            #expect(second.pruned == 0)
            #expect(!(try db.allIndexedPaths()).contains { $0.hasSuffix("/notes.pdf") })
        }
    }

    @Test func removingTheSourceLetsThePDFBeRediscovered() throws {
        try withTempTree { root in
            let source = join(root, "notes.md")
            try writeFile(join(root, "notes.pdf"), "%PDF-1.4")
            try writeFile(source)
            let db = try makeDB()
            let scanner = makeScanner(db, root: root)

            _ = try scanner.scan()
            #expect(!(try db.allIndexedPaths()).contains { $0.hasSuffix("/notes.pdf") })

            try FileManager.default.removeItem(atPath: source)
            _ = try scanner.scan()
            #expect(try db.allIndexedPaths().contains { $0.hasSuffix("/notes.pdf") })
        }
    }

    /// A configured list replaces the defaults: with only `tex` listed, a
    /// markdown sibling no longer shadows its PDF.
    @Test func configuredListReplacesDefaults() throws {
        try withTempTree { root in
            try writeFile(join(root, "readme.pdf"), "%PDF-1.4")
            try writeFile(join(root, "readme.md"))
            try writeFile(join(root, "paper.pdf"), "%PDF-1.4")
            try writeFile(join(root, "paper.tex"))
            let db = try makeDB()

            _ = try makeScanner(db, root: root, extensions: ["tex"]).scan()

            let indexed = try db.allIndexedPaths()
            #expect(indexed.contains { $0.hasSuffix("/readme.pdf") })
            #expect(!indexed.contains { $0.hasSuffix("/paper.pdf") })
        }
    }

    /// A converted PDF with no source keeps its row: its own output
    /// directory must not count as a sibling source.
    @Test func convertedPDFWithoutSourceIsKept() throws {
        try withTempTree { root in
            let pdf = join(root, "scan.pdf")
            try writeFile(pdf, "%PDF-1.4")
            let output = ScanRules.outputDirectory(forPDF: pdf)
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            try writeFile(join(output, "scan.md"), "# Scan")
            let db = try makeDB()
            try db.upsertDiscovered(filePath: pdf, fileSize: 8, mtime: 1000)

            let result = try makeScanner(db, root: root).scan()

            #expect(result.pruned == 0)
            #expect(try db.allIndexedPaths().contains { $0.hasSuffix("/scan.pdf") })
        }
    }
}
