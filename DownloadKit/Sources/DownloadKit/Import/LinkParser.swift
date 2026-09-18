import Foundation

public enum LinkParserError: LocalizedError, Equatable {
    case fileTooLarge(limitMB: Int)

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let limit): "The file is larger than \(limit) MB, which is far more than a list of links."
        }
    }
}

/// Finds downloadable links in pasted text or a `.txt` file.
public enum LinkParser {
    public static let maxLinks = 10_000
    public static let maxFileSize = 5 * 1024 * 1024
    /// `NSDataDetector` slows down badly on very long lines (a 5 MB single line took about 28 s), so
    /// longer ones are tokenized on whitespace instead, which is linear.
    static let maxDetectorLineLength = 4096

    /// Extracts explicit `http(s)://` URLs, in order, without duplicates. Blank lines and `#` comment
    /// lines are skipped. Bare hosts such as `example.com/a.zip` are not guessed at.
    public static func urls(in text: String) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            for url in candidates(in: trimmed, detector: detector) where seen.insert(url.absoluteString).inserted {
                result.append(url)
                if result.count >= maxLinks { return result }
            }
        }
        return result
    }

    /// Reads a text file of links. Refuses files larger than `maxFileSize`.
    public static func urls(inFileAt file: URL) throws -> [URL] {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxFileSize else { throw LinkParserError.fileTooLarge(limitMB: maxFileSize / 1024 / 1024) }
        let data = try Data(contentsOf: file)
        return urls(in: String(decoding: data, as: UTF8.self))
    }

    private static func candidates(in line: String, detector: NSDataDetector?) -> [URL] {
        // Common case: the whole line is one URL.
        if !line.contains(where: \.isWhitespace), let url = downloadable(line) { return [url] }
        if line.utf8.count > maxDetectorLineLength { return tokenized(line) }

        guard let detector else { return [] }
        let range = NSRange(line.startIndex..., in: line)
        return detector.matches(in: line, options: [], range: range).compactMap { match in
            guard let matched = Range(match.range, in: line) else { return nil }
            return downloadable(String(line[matched]))
        }
    }

    private static func tokenized(_ line: String) -> [URL] {
        let punctuation = CharacterSet(charactersIn: "()[]{},.;:!?")
        var urls: [URL] = []
        for token in line.split(whereSeparator: { $0.isWhitespace || "<>\"'".contains($0) }) {
            guard let url = downloadable(String(token).trimmingCharacters(in: punctuation)) else { continue }
            urls.append(url)
            if urls.count >= maxLinks { break }
        }
        return urls
    }

    /// `text` as a URL, if it is an absolute `http(s)` link with a host.
    public static func httpURL(_ text: String) -> URL? { downloadable(text) }

    private static func downloadable(_ text: String) -> URL? {
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
              let url = URL(string: text),
              url.host(percentEncoded: false)?.isEmpty == false else { return nil }
        return url
    }
}
