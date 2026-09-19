import Foundation
import Testing
@testable import DownloadKit

@Suite("fetchthings:// links")
struct SchemeLinkTests {
    @Test func extractsEncodedLinksInOrder() {
        let link = URL(string: "fetchthings://add?url=https%3A%2F%2Fexample.com%2Fa.zip%3Fx%3D1&url=http%3A%2F%2Fexample.org%2Fb.iso")!
        #expect(SchemeLink.urls(from: link)?.map(\.absoluteString) == ["https://example.com/a.zip?x=1", "http://example.org/b.iso"])
    }

    @Test func dropsDuplicatesAndAnythingButHTTP() {
        let link = URL(string: "fetchthings://add?url=https://example.com/a&url=https://example.com/a&url=file:///etc/passwd&url=ftp://example.com/x&url=javascript:alert(1)&url=notaurl")!
        #expect(SchemeLink.urls(from: link)?.map(\.absoluteString) == ["https://example.com/a"])
    }

    @Test func ignoresOtherParametersAndActions() {
        #expect(SchemeLink.urls(from: URL(string: "fetchthings://add?foo=https://example.com/a")!) == [])
        #expect(SchemeLink.urls(from: URL(string: "fetchthings://remove?url=https://example.com/a")!) == nil)
        #expect(SchemeLink.urls(from: URL(string: "https://add?url=https://example.com/a")!) == nil)
        #expect(SchemeLink.urls(from: URL(string: "fetchthings://add")!) == nil, "no query at all")
    }

    @Test func schemeAndActionAreCaseInsensitive() {
        #expect(SchemeLink.urls(from: URL(string: "FETCHTHINGS://ADD?url=https://example.com/a")!)?.count == 1)
    }

    @Test func capsTheNumberOfLinks() {
        let query = (0..<(LinkParser.maxLinks + 20)).map { "url=https://example.com/\($0)" }.joined(separator: "&")
        #expect(SchemeLink.urls(from: URL(string: "fetchthings://add?\(query)")!)?.count == LinkParser.maxLinks)
    }

    @Test func roundTripsThroughAddLink() {
        let urls = [URL(string: "https://example.com/a b.zip?x=1&y=2#f")!, URL(string: "http://example.org/é")!]
        let link = SchemeLink.addLink(for: urls)
        #expect(link.scheme == "fetchthings")
        #expect(SchemeLink.urls(from: link) == urls)
    }
}
