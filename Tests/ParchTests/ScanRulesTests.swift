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
