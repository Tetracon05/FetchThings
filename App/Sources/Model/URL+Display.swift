import DownloadKit
import Foundation

extension URL {
    /// The file path as people write it: `~/Downloads`, not `/Users/name/Downloads`.
    var displayPath: String {
        (path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

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
