import DownloadKit
import Foundation

/// What the Add sheet shows about one link: the file it points at, where it is, and whether the trip is encrypted.
/// Never the user name or password of a `user:pass@host` address.
struct LinkSummary: Equatable, Identifiable {
    let url: URL
    var id: URL { url }
    /// The last part of the path with escapes decoded, or the host when the path names no file (`https://example.com/`).
    let displayName: String
    let host: String
    /// False for plain `http`, whose contents (and any password) can be read on the way.
    let isEncrypted: Bool

    init(_ url: URL) {
        self.url = url
        let host = url.host(percentEncoded: false) ?? ""
        self.host = host
        self.isEncrypted = url.scheme?.lowercased() == "https"
        self.displayName = url.displayFileName
    }
}

extension URL {
    /// The file name this address names, the way the engine will save it: the last part of the path (already
    /// decoded by `URL`, so it must not be decoded again: `a%2541.txt` is `a%41.txt`), with control and
    /// right-to-left characters removed, or the host when the path names no file (`https://example.com/`).
    var displayFileName: String {
        FilenameSanitizer.sanitize(lastPathComponent, fallback: host(percentEncoded: false) ?? absoluteString)
    }

    /// The address without a `user:pass@` part, safe to show in a message.
    var withoutCredentials: URL {
        guard var parts = URLComponents(url: self, resolvingAgainstBaseURL: false), parts.user != nil || parts.password != nil else { return self }
        parts.user = nil
        parts.password = nil
        return parts.url ?? self
    }
}
