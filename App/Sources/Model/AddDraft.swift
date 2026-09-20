import DownloadKit
import Foundation

/// The state of the Add Download sheet, and the rules for turning it into engine requests.
struct AddDraft: Equatable {
    var linksText = "" { didSet { links = LinkParser.urls(in: linksText) } }
    /// The links in `linksText`, parsed once per edit rather than on every read (the sheet reads it several
    /// times per render).
    private(set) var links: [URL] = []
    /// Links that came from outside while the sheet was already open (a `fetchthings://` link, a drop, the Services
    /// menu). The cookies, headers and login typed into the sheet are not sent with them: any web page can propose a
    /// link, and it must not be able to borrow what the user entered for another site.
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

    /// Adds links that are not in the list yet, one per line after what is already there. `fromOutside` marks links
    /// the user did not type or paste into the sheet (see `linksWithoutSecrets`); a link the user adds themselves,
    /// even one that came from outside first, is theirs again.
    mutating func append(_ urls: [URL], fromOutside: Bool = false) {
        if fromOutside {
            var known = Set(links)
            linksWithoutSecrets.formUnion(urls.filter { known.insert($0).inserted })
        } else {
            linksWithoutSecrets.subtract(urls)
        }
        var known = Set(links)
        let fresh = urls.filter { known.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        var text = linksText
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        linksText = text + fresh.map(\.absoluteString).joined(separator: "\n")
    }

    /// Takes one link out. What is left is written back as one link per line (other text in the field goes with it).
    mutating func remove(_ url: URL) {
        linksWithoutSecrets.remove(url)
        linksText = links.filter { $0 != url }.map(\.absoluteString).joined(separator: "\n")
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
        let links = links
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
