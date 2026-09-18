import Foundation
import UniformTypeIdentifiers

public enum FilenameSanitizer {
    /// Leaves room for `.part` and a ` (n)` collision suffix within a 255-byte filename limit.
    public static let maxBytes = 200

    /// Reduces untrusted text to a single safe path component.
    ///
    /// - Keeps only the last `/`- or `\`-separated component, so `../../etc/passwd` becomes `passwd`.
    /// - Removes control characters and Unicode bidi/zero-width controls (right-to-left-override
    ///   tricks such as `invoice‮fdp.exe`).
    /// - Replaces `:` (Finder shows it as `/`), strips leading dots (no hidden files, no `.`/`..`).
    /// - Normalizes to NFC and caps the length at `maxBytes` UTF-8 bytes, keeping the extension.
    public static func sanitize(_ raw: String, fallback: String = "download") -> String {
        let component = raw
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .last.map(String.init) ?? ""

        var scalars = String.UnicodeScalarView()
        for scalar in component.unicodeScalars where !isStripped(scalar) {
            scalars.append(scalar == ":" ? "-" : scalar)
        }
        var name = String(scalars).precomposedStringWithCanonicalMapping
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        while name.hasSuffix(".") || name.hasSuffix(" ") { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else { return fallback == "download" ? fallback : sanitize(fallback) }
        return truncate(name, toBytes: maxBytes)
    }

    /// Whether `name` is already a single, non-special path component.
    static func isSafeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.unicodeScalars.contains("\0")
            && name.utf8.count <= 255
    }

    private static let strippedFormatScalars: Set<UInt32> = [
        0x200B, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2060,
        0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
    ]

    private static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || strippedFormatScalars.contains(scalar.value)
    }

    private static func truncate(_ name: String, toBytes limit: Int) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let keepExtension = !ext.isEmpty && ext.utf8.count <= 16 && ext.utf8.count < limit - 1
        let suffix = keepExtension ? "." + ext : ""
        var stem = keepExtension ? String(name.dropLast(suffix.count)) : name
        while stem.utf8.count + suffix.utf8.count > limit, !stem.isEmpty { stem.removeLast() }
        return stem.isEmpty ? String(name.prefix(1)) : stem + suffix
    }
}

enum FilenameResolver {
    /// Picks a name in order of trust: `Content-Disposition`, then the URL path after redirects, then
    /// the URL the user gave. Adds an extension from the MIME type when the name has none.
    static func suggest(contentDisposition: String?, finalURL: URL?, originalURL: URL, mimeType: String?) -> String {
        var name = contentDisposition.flatMap(ContentDisposition.filename(from:))
        if name == nil {
            let candidates = [finalURL, originalURL].compactMap { $0 }.compactMap(lastComponent)
            name = candidates.first(where: { $0.contains(".") }) ?? candidates.first
        }
        var result = FilenameSanitizer.sanitize(name ?? "")
        if (result as NSString).pathExtension.isEmpty,
           let mimeType,
           let ext = extensionFor(mimeType: mimeType) {
            result = FilenameSanitizer.sanitize(result + "." + ext)
        }
        return result
    }

    private static func lastComponent(of url: URL) -> String? {
        let path = url.path(percentEncoded: false)
        guard !path.isEmpty, !path.hasSuffix("/") else { return nil }
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }

    private static func extensionFor(mimeType: String) -> String? {
        let base = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !base.isEmpty, base != "application/octet-stream", base != "binary/octet-stream" else { return nil }
        return UTType(mimeType: base)?.preferredFilenameExtension
    }
}
