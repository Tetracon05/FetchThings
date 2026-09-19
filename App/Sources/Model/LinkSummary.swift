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
        let last = url.lastPathComponent
        let name = last.removingPercentEncoding ?? last
        self.displayName = name.isEmpty || name == "/" ? host : name
    }
}
