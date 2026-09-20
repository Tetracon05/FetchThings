import Foundation
import Testing
@testable import FetchThings

@Suite("Paste detection")
struct PasteDetectionTests {
    @Test func findsWhatWasInserted() {
        #expect(PasteDetection.insertion(from: "", to: "abc") == "abc")
        #expect(PasteDetection.insertion(from: "https://", to: "https://ex") == "ex")
        #expect(PasteDetection.insertion(from: "ac", to: "abc") == "b")
        #expect(PasteDetection.insertion(from: "abc", to: "abc") == "")
        #expect(PasteDetection.insertion(from: "abc", to: "ab") == "", "text that was removed is not an insertion")
        #expect(PasteDetection.insertion(from: "aa", to: "aaaa") == "aa")
    }

    @Test func aPastedAddressIsAPasteWhereverItLands() {
        #expect(PasteDetection.looksLikePaste(from: "", to: "https://example.com/a.zip"))
        #expect(PasteDetection.looksLikePaste(from: "see ", to: "see https://example.com/a.zip"))
        #expect(PasteDetection.looksLikePaste(from: "ab", to: "ahttps://x.example/fb"), "pasted into the middle of what was typed")
        #expect(PasteDetection.looksLikePaste(from: "", to: "http://a"), "the shortest address")
    }

    @Test func aLineBreakIsAPaste() {
        #expect(PasteDetection.looksLikePaste(from: "https://example.com/a", to: "https://example.com/a\n"))
        #expect(PasteDetection.looksLikePaste(from: "", to: "https://a.example/1\nhttps://a.example/2"))
    }

    @Test func typingAndAutocorrectAreNot() {
        // One character at a time, and two or three arriving together on a busy main thread.
        #expect(!PasteDetection.looksLikePaste(from: "https://exa", to: "https://exam"))
        #expect(!PasteDetection.looksLikePaste(from: "https://", to: "https://ex"), "a half-typed link must not become a card")
        #expect(!PasteDetection.looksLikePaste(from: "https", to: "https://"), "the scheme typed in one lump is still short")
        #expect(!PasteDetection.looksLikePaste(from: "https://example.com/a.z", to: "https://example.com/a.zip"))
        // An autocorrect that replaces a word rather than adding an address.
        #expect(!PasteDetection.looksLikePaste(from: "teh", to: "the"))
    }
}
