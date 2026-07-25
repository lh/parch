import Foundation
import Testing
@testable import parch

@Suite("ScanRules")
struct ScanRulesTests {

    @Test func skipsSystemPaths() {
        #expect(ScanRules.shouldSkip(path: "/System/Library/Frameworks/PDFKit.framework/docs/guide.pdf"))
        #expect(ScanRules.shouldSkip(path: "/Library/Documentation/help.pdf"))
    }

    @Test func skipsAppBundles() {
        #expect(ScanRules.shouldSkip(path: "/Applications/Preview.app/Contents/Resources/help.pdf"))
    }

    @Test func skipsTrash() {
        #expect(ScanRules.shouldSkip(path: "/Users/test/.Trash/old.pdf"))
    }

    @Test func skipsBuildArtifacts() {
        #expect(ScanRules.shouldSkip(path: "/Users/test/project/node_modules/lib/doc.pdf"))
        #expect(ScanRules.shouldSkip(path: "/Users/test/project/__pycache__/something.pdf"))
        #expect(ScanRules.shouldSkip(path: "/Users/test/project/.venv/lib/doc.pdf"))
        #expect(ScanRules.shouldSkip(path: "/Users/test/project/.git/objects/doc.pdf"))
    }

    @Test func skipsTimeMachine() {
        #expect(ScanRules.shouldSkip(path: "/Volumes/com.apple.TimeMachine.localsnapshots/backup/doc.pdf"))
    }

    @Test func allowsUserDocuments() {
        #expect(!ScanRules.shouldSkip(path: "/Users/test/Documents/report.pdf"))
        #expect(!ScanRules.shouldSkip(path: "/Users/test/Downloads/paper.pdf"))
    }

    @Test func allowsCloudStorage() {
        #expect(!ScanRules.shouldSkip(path: "/Users/test/Library/CloudStorage/Dropbox/work/doc.pdf"))
    }

    @Test func allowsExternalVolumes() {
        #expect(!ScanRules.shouldSkip(path: "/Volumes/USB-Drive/scans/form.pdf"))
    }

    @Test func detectsPDF() {
        #expect(ScanRules.isPDF("/path/to/file.pdf"))
        #expect(ScanRules.isPDF("/path/to/file.PDF"))
        #expect(!ScanRules.isPDF("/path/to/file.txt"))
        #expect(!ScanRules.isPDF("/path/to/file.pdf.bak"))
    }

    @Test func outputDirectory() {
        #expect(ScanRules.outputDirectory(forPDF: "/Users/test/Documents/report.pdf") == "/Users/test/Documents/report")
    }

    @Test func markdownPath() {
        #expect(ScanRules.markdownPath(forPDF: "/Users/test/Documents/report.pdf") == "/Users/test/Documents/report/report.md")
    }
}

@Suite("Output presence")
struct OutputPresenceTests {

    /// Runs `body` with a fresh temporary directory that is cleaned up after.
    private func withTempDirectory(_ body: (String) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parch-output-" + UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try body(dir)
    }

    @Test func missingDirectoryHasNoOutput() throws {
        try withTempDirectory { dir in
            #expect(!ScanRules.hasMarkdownOutput(inDirectory: (dir as NSString).appendingPathComponent("gone")))
        }
    }

    @Test func emptyDirectoryHasNoOutput() throws {
        try withTempDirectory { dir in
            #expect(!ScanRules.hasMarkdownOutput(inDirectory: dir))
        }
    }

    @Test func emptyMarkdownFileDoesNotCount() throws {
        try withTempDirectory { dir in
            try "".write(toFile: (dir as NSString).appendingPathComponent("report.md"),
                         atomically: true, encoding: .utf8)
            #expect(!ScanRules.hasMarkdownOutput(inDirectory: dir))
        }
    }

    @Test func nonMarkdownFilesDoNotCount() throws {
        try withTempDirectory { dir in
            try "{}".write(toFile: (dir as NSString).appendingPathComponent(".vision-quality.json"),
                           atomically: true, encoding: .utf8)
            #expect(!ScanRules.hasMarkdownOutput(inDirectory: dir))
        }
    }

    @Test func markdownWithContentCounts() throws {
        try withTempDirectory { dir in
            try "# Report".write(toFile: (dir as NSString).appendingPathComponent("anything.md"),
                                atomically: true, encoding: .utf8)
            #expect(ScanRules.hasMarkdownOutput(inDirectory: dir))
        }
    }

    @Test func fileAtDirectoryPathHasNoOutput() throws {
        try withTempDirectory { dir in
            let path = (dir as NSString).appendingPathComponent("report")
            try "not a directory".write(toFile: path, atomically: true, encoding: .utf8)
            #expect(!ScanRules.hasMarkdownOutput(inDirectory: path))
        }
    }

    @Test func symlinkToConvertedDirectoryCounts() throws {
        try withTempDirectory { dir in
            let target = (dir as NSString).appendingPathComponent("canonical")
            try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
            try "# Report".write(toFile: (target as NSString).appendingPathComponent("canonical.md"),
                                atomically: true, encoding: .utf8)
            let link = (dir as NSString).appendingPathComponent("duplicate")
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)

            #expect(ScanRules.hasMarkdownOutput(inDirectory: link))
        }
    }

    @Test func danglingSymlinkHasNoOutput() throws {
        try withTempDirectory { dir in
            let link = (dir as NSString).appendingPathComponent("duplicate")
            try FileManager.default.createSymbolicLink(
                atPath: link,
                withDestinationPath: (dir as NSString).appendingPathComponent("deleted")
            )

            #expect(!ScanRules.hasMarkdownOutput(inDirectory: link))
            #expect(ScanRules.symlinkDestination(of: link) != nil)
        }
    }
}
