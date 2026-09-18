import Foundation
import Testing
@testable import DownloadKit

@Suite("Filename sanitizing")
struct FilenameSanitizerTests {
    @Test(arguments: [
        ("report.pdf", "report.pdf"),
        ("../../etc/passwd", "passwd"),
        ("..\\..\\Windows\\system32\\evil.dll", "evil.dll"),
        ("/absolute/path/file.txt", "file.txt"),
        ("a/b/c/", "c"),
        ("..", "download"),
        (".", "download"),
        ("", "download"),
        ("///", "download"),
        (".hidden", "hidden"),
        ("...dots.txt", "dots.txt"),
        ("trailing dots...", "trailing dots"),
        ("  padded name.txt  ", "padded name.txt"),
        ("with:colon.txt", "with-colon.txt"),
        ("tab\tand\nnewline.txt", "tabandnewline.txt"),
        ("nul\0byte.txt", "nulbyte.txt"),
    ])
    func sanitizes(raw: String, expected: String) {
        #expect(FilenameSanitizer.sanitize(raw) == expected)
    }

    @Test func removesBidiOverridesThatDisguiseExtensions() {
        // U+202E flips the rendering of what follows: "invoice‮fdp.exe" displays as "invoiceexe.pdf".
        let sanitized = FilenameSanitizer.sanitize("invoice\u{202E}fdp.exe")
        #expect(sanitized == "invoicefdp.exe")
        #expect(!sanitized.unicodeScalars.contains("\u{202E}"))
    }

    @Test func normalizesUnicodeToNFC() {
        let decomposed = "cafe\u{0301}.txt"
        #expect(FilenameSanitizer.sanitize(decomposed) == "caf\u{00E9}.txt")
    }

    @Test func keepsInternationalNames() {
        #expect(FilenameSanitizer.sanitize("日本語のファイル.zip") == "日本語のファイル.zip")
        #expect(FilenameSanitizer.sanitize("файл 📦.tar.gz") == "файл 📦.tar.gz")
    }

    @Test func truncatesLongNamesButKeepsTheExtension() {
        let name = String(repeating: "a", count: 400) + ".tar.gz"
        let result = FilenameSanitizer.sanitize(name)
        #expect(result.utf8.count <= FilenameSanitizer.maxBytes)
        #expect(result.hasSuffix(".gz"))
    }

    @Test func truncatesMultibyteNamesOnCharacterBoundaries() {
        let result = FilenameSanitizer.sanitize(String(repeating: "日", count: 200) + ".txt")
        #expect(result.utf8.count <= FilenameSanitizer.maxBytes)
        #expect(result.hasSuffix(".txt"))
        #expect(String(decoding: Array(result.utf8), as: UTF8.self) == result, "no split scalar")
    }

    @Test func resultIsAlwaysASafeComponent() {
        let hostile = ["../..", "a/../b", "\u{202E}", "\0", "....//....//x", "~", "$(rm -rf)", "COM1", "-rf"]
        for raw in hostile {
            #expect(FilenameSanitizer.isSafeComponent(FilenameSanitizer.sanitize(raw)), "unsafe result for \(raw.debugDescription)")
        }
    }
}

@Suite("Content-Disposition")
struct ContentDispositionTests {
    @Test(arguments: [
        (#"attachment; filename="report.pdf""#, "report.pdf"),
        ("attachment; filename=report.pdf", "report.pdf"),
        (#"attachment; filename="a b.txt""#, "a b.txt"),
        (#"attachment; filename="semi;colon.txt""#, "semi;colon.txt"),
        (#"attachment; filename="say \"hi\".txt""#, #"say "hi".txt"#),
        (#"inline; FILENAME="Upper.txt""#, "Upper.txt"),
        (#"attachment;filename="tight.bin";size=3"#, "tight.bin"),
        ("attachment; filename*=UTF-8''na%C3%AFve%20file.txt", "naïve file.txt"),
        ("attachment; filename*=ISO-8859-1''caf%E9.txt", "café.txt"),
    ])
    func extractsFilename(header: String, expected: String) {
        #expect(ContentDisposition.filename(from: header) == expected)
    }

    @Test func extendedFilenameWinsOverPlain() {
        let header = #"attachment; filename="fallback.txt"; filename*=UTF-8''real%20name.txt"#
        #expect(ContentDisposition.filename(from: header) == "real name.txt")
    }

    @Test func repairsUTF8ReadAsLatin1() {
        // "é" as UTF-8 bytes C3 A9, decoded as Latin-1 by the HTTP stack.
        #expect(ContentDisposition.filename(from: "attachment; filename=\"cafÃ©.txt\"") == "café.txt")
    }

    @Test func noFilenameYieldsNil() {
        #expect(ContentDisposition.filename(from: "attachment") == nil)
        #expect(ContentDisposition.filename(from: "inline; size=3") == nil)
        #expect(ContentDisposition.filename(from: "attachment; filename*=bogus") == nil)
    }

    @Test func traversalInHeaderIsNeutralizedBySanitizer() {
        let raw = ContentDisposition.filename(from: #"attachment; filename="../../../.ssh/authorized_keys""#)
        #expect(raw.map { FilenameSanitizer.sanitize($0) } == "authorized_keys")
    }
}

@Suite("Filename resolution and destinations")
struct FilenameResolverTests {
    let origin = URL(string: "https://example.com/dl?id=7")!

    @Test func contentDispositionBeatsTheURL() {
        let name = FilenameResolver.suggest(contentDisposition: #"attachment; filename="real.zip""#, finalURL: URL(string: "https://cdn.example.com/x/other.zip"), originalURL: origin, mimeType: nil)
        #expect(name == "real.zip")
    }

    @Test func prefersTheRedirectedURLWhenTheOriginalHasNoName() {
        let name = FilenameResolver.suggest(contentDisposition: nil, finalURL: URL(string: "https://cdn.example.com/files/movie%20clip.mp4?token=1"), originalURL: origin, mimeType: nil)
        #expect(name == "movie clip.mp4")
    }

    @Test func fallsBackToDownloadWhenNothingUsable() {
        let name = FilenameResolver.suggest(contentDisposition: nil, finalURL: nil, originalURL: URL(string: "https://example.com/")!, mimeType: nil)
        #expect(name == "download")
    }

    @Test func addsAnExtensionFromTheMIMETypeOnlyWhenMissing() {
        #expect(FilenameResolver.suggest(contentDisposition: nil, finalURL: nil, originalURL: URL(string: "https://e.com/photo")!, mimeType: "image/png") == "photo.png")
        #expect(FilenameResolver.suggest(contentDisposition: nil, finalURL: nil, originalURL: URL(string: "https://e.com/photo.jpg")!, mimeType: "image/png") == "photo.jpg")
        #expect(FilenameResolver.suggest(contentDisposition: nil, finalURL: nil, originalURL: URL(string: "https://e.com/blob")!, mimeType: "application/octet-stream") == "blob")
    }

    @Test func childURLRejectsAnythingButASingleComponent() throws {
        let dir = URL(filePath: NSTemporaryDirectory())
        for bad in ["", ".", "..", "a/b", "../x", "/abs", "nul\0"] {
            #expect(throws: DownloadError.self, "\(bad.debugDescription) must be rejected") {
                try DestinationResolver.childURL(in: dir, named: bad)
            }
        }
        let ok = try DestinationResolver.childURL(in: dir, named: "fine.txt")
        #expect(ok.lastPathComponent == "fine.txt")
    }

    @Test func nameVariantsInsertTheCounterBeforeTheExtension() {
        #expect(NameAllocator.variant(of: "report.pdf", number: 2) == "report (2).pdf")
        #expect(NameAllocator.variant(of: "archive.tar.gz", number: 3) == "archive.tar (3).gz")
        #expect(NameAllocator.variant(of: "noext", number: 2) == "noext (2)")
    }

    @Test func allocatorAvoidsDiskFilesPartFilesAndOtherReservations() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        try Data().write(to: env.file("a.txt"))
        try Data().write(to: env.file("b.txt.part"))

        var allocator = NameAllocator()
        #expect(try allocator.reserve(directory: env.downloads, desired: "a.txt") == "a (2).txt")
        #expect(try allocator.reserve(directory: env.downloads, desired: "a.txt") == "a (3).txt")
        #expect(try allocator.reserve(directory: env.downloads, desired: "b.txt") == "b (2).txt")
        #expect(try allocator.reserve(directory: env.downloads, desired: "c.txt") == "c.txt")
        allocator.release(directory: env.downloads, name: "c.txt")
        #expect(try allocator.reserve(directory: env.downloads, desired: "c.txt") == "c.txt")
    }

    @Test func moveIntoPlaceNeverOverwrites() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        try Data("existing".utf8).write(to: env.file("f.txt"))
        let part = env.file("f.txt.part")
        try Data("new".utf8).write(to: part)

        let name = try DestinationResolver.moveIntoPlace(part, directory: env.downloads, name: "f.txt")
        #expect(name == "f (2).txt")
        #expect(try String(contentsOf: env.file("f.txt"), encoding: .utf8) == "existing")
        #expect(try String(contentsOf: env.file("f (2).txt"), encoding: .utf8) == "new")
    }
}
