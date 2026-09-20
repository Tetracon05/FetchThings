import DownloadKit
import Foundation

/// The state of the Add Download sheet, and the rules for turning it into engine requests.
struct AddDraft: Equatable {
    /// The links to add, in the order they were entered, without repeats and at most `LinkParser.maxLinks`.
    private(set) var links: [URL] = []
    /// Links that came from outside while the sheet was already open (a `fetchthings://` link, a drop, the Services
    /// menu). The cookies, headers and login typed into the sheet are not sent with them: any web page can propose a
    /// link, and it must not be able to borrow what the user entered for another site. Always a subset of `links`.
    private(set) var linksWithoutSecrets: Set<URL> = []
    var folder: URL
    var segmentCount: Int
    var startPaused = false
    /// Only honored for a single link.
    var filename = ""
    var referer = ""
    var userAgent = ""
    var cookies = ""
    /// One `Name: value` per line.
    var headersText = ""
    var username = ""
    var password = ""
    /// `sha256:<hex>`, `md5:<hex>`, or a bare digest.
    var checksumText = ""
    /// Kilobytes per second for this download; 0 is unlimited.
    var speedLimitKBps = 0

    init(folder: URL, segmentCount: Int, userAgent: String = "") {
        self.folder = folder
        self.segmentCount = segmentCount
        self.userAgent = userAgent
    }

    /// Adds the http(s) links that are not in the list yet. `fromOutside` marks links the user did not type or paste
    /// into the sheet (see `linksWithoutSecrets`); a link the user adds themselves, even one that came from outside
    /// first, is theirs again.
    mutating func append(_ urls: [URL], fromOutside: Bool = false) {
        var known = Set(links)
        let fresh = urls
            .filter { LinkParser.httpURL($0.absoluteString) != nil && known.insert($0).inserted }
            .prefix(max(0, LinkParser.maxLinks - links.count))
        if fromOutside { linksWithoutSecrets.formUnion(fresh) } else { linksWithoutSecrets.subtract(urls) }
        links += fresh
    }

    /// Takes one link out.
    mutating func remove(_ url: URL) {
        links.removeAll { $0 == url }
        linksWithoutSecrets.remove(url)
    }

    /// After an add that partly failed: keeps only the links that did not go through, so adding again cannot repeat
    /// what did.
    mutating func keepOnly(_ urls: [URL]) {
        let keep = Set(urls)
        links.removeAll { !keep.contains($0) }
        linksWithoutSecrets.formIntersection(links)
    }

    /// Whether the sheet holds cookies, headers or a login that would be sent with the links.
    var hasSecrets: Bool {
        ![cookies, headersText, username].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Basic-auth credentials would go over the wire in clear text.
    var sendsCredentialsOverPlainHTTP: Bool {
        !username.isEmpty && links.contains { !linksWithoutSecrets.contains($0) && $0.scheme?.lowercased() == "http" }
    }

    func makeRequests() throws -> [NewDownload] {
        guard !links.isEmpty else { throw AddDraftError.noLinks }

        let trimmedName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty, links.count > 1 { throw AddDraftError.filenameNeedsSingleLink }

        var options = DownloadOptions(segmentCount: segmentCount)
        let trimmedReferer = referer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReferer.isEmpty {
            guard let url = LinkParser.httpURL(trimmedReferer) else { throw AddDraftError.invalidReferer }
            options.referer = url
        }
        let agent = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !agent.isEmpty { options.userAgent = agent }
        options.speedLimit = SpeedLimit.bytesPerSecond(kbps: speedLimitKBps)
        let trimmedChecksum = checksumText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedChecksum.isEmpty {
            guard let checksum = Checksum(parsing: trimmedChecksum) else { throw AddDraftError.invalidChecksum }
            options.checksum = checksum
        }

        var sensitive = SensitiveOptions()
        let trimmedCookies = cookies.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCookies.isEmpty { sensitive.cookies = trimmedCookies }
        sensitive.headers = try Self.parseHeaders(headersText)
        if !username.isEmpty { sensitive.basicAuth = BasicAuth(username: username, password: password) }

        return links.map { link in
            NewDownload(
                url: link,
                destinationDirectory: folder,
                filename: trimmedName.isEmpty ? nil : trimmedName,
                options: options,
                sensitive: linksWithoutSecrets.contains(link) ? SensitiveOptions() : sensitive,
                startPaused: startPaused
            )
        }
    }

    /// `Name: value` lines. Blank lines are skipped; the last of a repeated name wins.
    static func parseHeaders(_ text: String) throws -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { throw AddDraftError.invalidHeaderLine(trimmed) }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw AddDraftError.invalidHeaderLine(trimmed) }
            headers[name] = value
        }
        return headers
    }
}

enum AddDraftError: LocalizedError, Equatable {
    case noLinks
    case filenameNeedsSingleLink
    case invalidReferer
    case invalidChecksum
    case invalidHeaderLine(String)

    var errorDescription: String? {
        switch self {
        case .noLinks: String(localized: "Enter at least one http or https link.")
        case .filenameNeedsSingleLink: String(localized: "A file name can only be set when adding a single link.")
        case .invalidReferer: String(localized: "The Referer must be an http or https address.")
        case .invalidChecksum: String(localized: "The checksum must be a SHA-256 or MD5 digest, for example sha256:9f86d0…")
        case .invalidHeaderLine(let line): String(localized: "“\(line)” is not a header. Write each one as Name: value.")
        }
    }
}
