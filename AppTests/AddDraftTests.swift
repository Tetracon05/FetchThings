import DownloadKit
import Foundation
import Testing
@testable import FetchThings

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
        let line = "x" // the wording is localized: compare with the same call
        #expect(AddDraftError.invalidHeaderLine(line).errorDescription == String(localized: "“\(line)” is not a header. Write each one as Name: value."))
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

    // MARK: List editing from the sheet

    @Test func appendingAddsNewLinksAfterWhatIsThereAndSkipsRepeats() {
        var d = draft("https://example.com/a.zip")
        d.append([URL(string: "https://example.com/b.zip")!, URL(string: "https://example.com/a.zip")!, URL(string: "https://example.com/b.zip")!])
        #expect(d.links.map(\.absoluteString) == ["https://example.com/a.zip", "https://example.com/b.zip"])
        #expect(d.linksText == "https://example.com/a.zip\nhttps://example.com/b.zip")

        var empty = draft("")
        empty.append([URL(string: "https://example.com/c.zip")!])
        #expect(empty.linksText == "https://example.com/c.zip") // no blank line first

        var trailing = draft("https://example.com/a.zip\n")
        trailing.append([URL(string: "https://example.com/d.zip")!])
        #expect(trailing.linksText == "https://example.com/a.zip\nhttps://example.com/d.zip") // no blank line between
    }

    @Test func removingOneLinkKeepsTheOthersInOrder() {
        var d = draft("https://example.com/a.zip\nhttps://example.com/b.zip\nhttps://example.com/c.zip")
        d.remove(URL(string: "https://example.com/b.zip")!)
        #expect(d.links.map(\.absoluteString) == ["https://example.com/a.zip", "https://example.com/c.zip"])
        d.remove(URL(string: "https://example.com/a.zip")!)
        d.remove(URL(string: "https://example.com/c.zip")!)
        #expect(d.links.isEmpty && d.linksText.isEmpty)
    }

    @Test func aLinkIsSummarisedByItsFileAndHostNeverItsPassword() throws {
        let file = LinkSummary(URL(string: "https://files.example.com/some%20folder/My%20Movie.mkv")!)
        #expect(file.displayName == "My Movie.mkv" && file.host == "files.example.com" && file.isEncrypted)

        let plain = LinkSummary(URL(string: "http://example.com/a.zip")!)
        #expect(!plain.isEncrypted)

        // No file in the path: the host stands in for its name.
        #expect(LinkSummary(URL(string: "https://example.com/")!).displayName == "example.com")
        #expect(LinkSummary(URL(string: "https://example.com")!).displayName == "example.com")

        let secret = LinkSummary(URL(string: "https://alice:hunter2@example.com/private.iso")!)
        #expect(secret.host == "example.com")
        #expect(!secret.displayName.contains("hunter2") && !secret.host.contains("hunter2") && !secret.host.contains("alice"))
    }

    // MARK: Links from outside

    @Test func linksFromOutsideAreSentWithoutTheSheetsSecrets() throws {
        var d = draft("https://mine.example/a.zip")
        d.cookies = "session=abc"
        d.headersText = "X-Token: t"
        d.username = "alice"
        d.password = "pw"
        d.append([URL(string: "https://evil.example/x.zip")!], fromOutside: true)

        let requests = try d.makeRequests()
        let mine = try #require(requests.first { $0.url.host() == "mine.example" })
        let theirs = try #require(requests.first { $0.url.host() == "evil.example" })
        #expect(mine.sensitive.cookies == "session=abc" && mine.sensitive.headers["X-Token"] == "t" && mine.sensitive.basicAuth != nil)
        #expect(theirs.sensitive.isEmpty, "a link proposed from outside must not borrow what was typed for another site")
        #expect(d.hasSecrets && d.linksWithoutSecrets.count == 1)
    }

    @Test func aLinkTheUserAddsThemselvesGetsTheirSecretsEvenIfItCameFromOutsideFirst() throws {
        var d = draft("https://mine.example/a.zip")
        d.cookies = "session=abc"
        let link = URL(string: "https://other.example/b.zip")!
        d.append([link], fromOutside: true)
        d.append([link]) // pasted by the user: it is theirs now
        let request = try #require(try d.makeRequests().first { $0.url.host() == "other.example" })
        #expect(request.sensitive.cookies == "session=abc")

        var removed = draft("https://mine.example/a.zip")
        removed.append([link], fromOutside: true)
        removed.remove(link)
        removed.append([link]) // and a link taken out and put back is theirs too
        #expect(removed.linksWithoutSecrets.isEmpty)
    }

    @Test func aLinkAlreadyInTheListStaysTheUsersWhenItComesAgainFromOutside() throws {
        var d = draft("https://mine.example/a.zip")
        d.cookies = "session=abc"
        d.append([URL(string: "https://mine.example/a.zip")!], fromOutside: true)
        #expect(d.linksWithoutSecrets.isEmpty)
        #expect(try d.makeRequests().first?.sensitive.cookies == "session=abc")
    }

    @Test func thePlainHTTPWarningIgnoresLinksThatGetNoLogin() {
        var d = draft("https://mine.example/a.zip")
        d.username = "alice"
        d.append([URL(string: "http://outside.example/x")!], fromOutside: true)
        #expect(!d.sendsCredentialsOverPlainHTTP, "the login is not sent to that link, so there is nothing to warn about")
        d.append([URL(string: "http://outside.example/x")!])
        #expect(d.sendsCredentialsOverPlainHTTP)
    }

    // MARK: Names

    @Test func aLinkNameIsDecodedOnceAndCannotSpoofItsExtension() {
        // `URL` has already decoded the last component: a second decode turned `a%2541.txt` into `aA.txt`.
        #expect(LinkSummary(URL(string: "https://h.example/a%2541.txt")!).displayName == "a%41.txt")
        #expect(LinkSummary(URL(string: "https://h.example/50%2520off.zip")!).displayName == "50%20off.zip")
        #expect(LinkSummary(URL(string: "https://h.example/some%20folder/My%20Movie.mkv")!).displayName == "My Movie.mkv")

        // A right-to-left override would show `invoice<exe.pdf` for the file `invoice.exe`.
        let spoof = LinkSummary(URL(string: "https://evil.example/invoice%E2%80%AEfdp.exe")!).displayName
        #expect(!spoof.unicodeScalars.contains("\u{202E}") && spoof.hasSuffix(".exe"))

        // The table shows the same name before the probe has found one.
        let row = snapshot(url: "https://h.example/a%2541.txt")
        #expect(row.displayName == "a%41.txt")
    }

    @Test func aFailureMessageNeverCarriesAPassword() {
        let secret = URL(string: "https://alice:hunter2@host.example/f.iso")!
        #expect(secret.withoutCredentials.absoluteString == "https://host.example/f.iso")
        let plain = URL(string: "https://host.example/f.iso?x=1")!
        #expect(plain.withoutCredentials == plain)
    }
}
