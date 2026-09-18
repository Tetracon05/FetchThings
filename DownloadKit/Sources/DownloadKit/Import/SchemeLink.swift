import Foundation

/// The app's own URL scheme: `downloader://add?url=<link>&url=<link>`.
///
/// Opening such a link must only ever *propose* downloads (the app shows them in the Add sheet for the
/// user to confirm). Any web page can produce a link like this, so it must never start a transfer.
public enum SchemeLink {
    public static let scheme = "downloader"

    /// The links carried by an `add` action, or `nil` if `link` is not one. Only `http(s)` URLs survive,
    /// in order, without duplicates and capped at `LinkParser.maxLinks`.
    public static func urls(from link: URL) -> [URL]? {
        guard link.scheme?.lowercased() == scheme, link.host(percentEncoded: false)?.lowercased() == "add",
              let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var seen = Set<String>()
        var result: [URL] = []
        for item in items where item.name == "url" {
            guard let value = item.value, let url = LinkParser.httpURL(value), seen.insert(url.absoluteString).inserted else { continue }
            result.append(url)
            if result.count >= LinkParser.maxLinks { break }
        }
        return result
    }

    /// A link that asks the app to add `urls`.
    public static func addLink(for urls: [URL]) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "add"
        components.queryItems = urls.map { URLQueryItem(name: "url", value: $0.absoluteString) }
        return components.url!
    }
}
