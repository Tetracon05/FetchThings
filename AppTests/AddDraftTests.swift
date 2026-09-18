import DownloadKit
import Foundation
import Testing
@testable import Downloader

@Suite("Add sheet draft")
struct AddDraftTests {
    private func draft(_ text: String = "https://example.com/a.zip") -> AddDraft {
        var d = AddDraft(folder: URL(filePath: "/tmp/dl", directoryHint: .isDirectory), segmentCount: 6)
        d.linksText = text
        return d
    }

    @Test func buildsOneRequestPerLink() throws {
        let requests = try draft("""
        https://example.com/a.zip
        # a comment
        https://example.com/b.zip
        not a link
        """).makeRequests()
        #expect(requests.map(\.url.absoluteString) == ["https://example.com/a.zip", "https://example.com/b.zip"])
        #expect(requests.allSatisfy { $0.destinationDirectory.path == "/tmp/dl" && $0.options.segmentCount == 6 && !$0.startPaused })
    }

    @Test func linksAreFoundInPastedProse() throws {
        let requests = try draft("Please grab https://example.com/one.iso and (https://example.org/two.iso).").makeRequests()
        #expect(requests.count == 2)
    }

    @Test func nothingToDownloadIsAnError() {
        #expect(throws: AddDraftError.noLinks) { try draft("").makeRequests() }
        #expect(throws: AddDraftError.noLinks) { try draft("ftp://example.com/x\nfile:///etc/passwd\nexample.com/bare").makeRequests() }
    }

    @Test func aFileNameNeedsExactlyOneLink() throws {
        var single = draft()
        single.filename = "  renamed.zip "
        #expect(try single.makeRequests().first?.filename == "renamed.zip")

        var several = draft("https://example.com/a\nhttps://example.com/b")
        several.filename = "renamed.zip"
        #expect(throws: AddDraftError.filenameNeedsSingleLink) { try several.makeRequests() }
    }

    @Test func optionsAreMappedAndTrimmed() throws {
        var d = draft()
        d.startPaused = true
        d.referer = " https://ref.example/page "
        d.userAgent = " Agent/2 "
        d.speedLimitKBps = 300
        d.checksumText = " sha256:\(String(repeating: "a", count: 64)) "
        let request = try #require(try d.makeRequests().first)
        #expect(request.startPaused)
        #expect(request.options.referer?.absoluteString == "https://ref.example/page")
        #expect(request.options.userAgent == "Agent/2")
        #expect(request.options.speedLimit == 300_000)
        #expect(request.options.checksum == Checksum(algorithm: .sha256, hex: String(repeating: "a", count: 64)))
    }

    @Test func emptyOptionalFieldsStayUnset() throws {
        let request = try #require(try draft().makeRequests().first)
        #expect(request.options.referer == nil && request.options.userAgent == nil)
        #expect(request.options.speedLimit == nil && request.options.checksum == nil)
        #expect(request.sensitive.isEmpty)
        #expect(request.filename == nil)
    }

    @Test func invalidOptionsAreRejectedWithAClearError() {
        var badReferer = draft(); badReferer.referer = "javascript:alert(1)"
        #expect(throws: AddDraftError.invalidReferer) { try badReferer.makeRequests() }
        var badChecksum = draft(); badChecksum.checksumText = "sha256:nothex"
        #expect(throws: AddDraftError.invalidChecksum) { try badChecksum.makeRequests() }
        var badHeader = draft(); badHeader.headersText = "no colon here"
        #expect(throws: AddDraftError.invalidHeaderLine("no colon here")) { try badHeader.makeRequests() }
        #expect(AddDraftError.invalidHeaderLine("x").errorDescription?.contains("Name: value") == true)
    }

    @Test func secretsGoIntoTheSensitiveOptions() throws {
        var d = draft()
        d.cookies = " session=abc; theme=dark "
        d.headersText = "X-Token: t0k\nAuthorization: Bearer a:b:c"
        d.username = "ann"
        d.password = "s3cret"
        let sensitive = try #require(try d.makeRequests().first).sensitive
        #expect(sensitive.cookies == "session=abc; theme=dark")
        #expect(sensitive.headers == ["X-Token": "t0k", "Authorization": "Bearer a:b:c"])
        #expect(sensitive.basicAuth == BasicAuth(username: "ann", password: "s3cret"))
    }

    @Test func aUserNameWithoutAPasswordIsAllowed() throws {
        var d = draft()
        d.username = "token"
        #expect(try d.makeRequests().first?.sensitive.basicAuth == BasicAuth(username: "token", password: ""))
    }

    @Test func parsesHeaderLines() throws {
        #expect(try AddDraft.parseHeaders("A: 1\n\n  B :  two words  \nA: 3") == ["A": "3", "B": "two words"])
        #expect(try AddDraft.parseHeaders("").isEmpty)
        #expect(throws: AddDraftError.invalidHeaderLine(": value")) { try AddDraft.parseHeaders(": value") }
    }

    @Test func warnsAboutPasswordsOverPlainHTTP() {
        var d = draft("http://example.com/a")
        #expect(!d.sendsCredentialsOverPlainHTTP)
        d.username = "ann"
        #expect(d.sendsCredentialsOverPlainHTTP)
        d.linksText = "https://example.com/a"
        #expect(!d.sendsCredentialsOverPlainHTTP)
    }

    @Test func requestsAreAcceptedByTheEngineValidation() async throws {
        // The draft's output must satisfy the engine's own rules, or every add would fail at the last step.
        var d = draft()
        d.headersText = "X-A: 1"
        d.cookies = "a=b"
        d.username = "ann"
        d.password = "pw"
        d.startPaused = true // validated and stored, but nothing is downloaded
        let scratch = URL(filePath: NSTemporaryDirectory()).appending(path: "draft-engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        d.folder = scratch.appending(path: "dl", directoryHint: .isDirectory)
        let manager = DownloadManager(store: FileJobStore(directory: scratch.appending(path: "jobs")), secrets: InMemorySecretStore())

        for request in try d.makeRequests() {
            let id = try await manager.add(request)
            #expect(await manager.snapshot(id)?.state == .paused)
        }
    }
}
