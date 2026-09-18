import Foundation

/// Extracts a filename from a `Content-Disposition` header (RFC 6266 / RFC 5987).
enum ContentDisposition {
    static func filename(from header: String) -> String? {
        let parameters = parseParameters(header)
        if let extended = parameters["filename*"], let decoded = decodeExtendedValue(extended), !decoded.isEmpty {
            return decoded
        }
        if let plain = parameters["filename"], !plain.isEmpty {
            return repairUTF8Mojibake(plain)
        }
        return nil
    }

    /// `name=value` pairs after the disposition type. Values are tokens or quoted strings with
    /// backslash escapes; a `;` inside quotes does not split. The first occurrence of a name wins.
    static func parseParameters(_ header: String) -> [String: String] {
        guard let firstSemicolon = header.firstIndex(of: ";") else { return [:] }
        var result: [String: String] = [:]
        var i = header.index(after: firstSemicolon)
        let end = header.endIndex

        while i < end {
            while i < end, header[i] == ";" || header[i].isWhitespace { i = header.index(after: i) }
            let nameStart = i
            while i < end, header[i] != "=", header[i] != ";" { i = header.index(after: i) }
            let name = header[nameStart..<i].trimmingCharacters(in: .whitespaces).lowercased()
            guard i < end, header[i] == "=" else { continue }
            i = header.index(after: i)
            while i < end, header[i] == " " || header[i] == "\t" { i = header.index(after: i) }

            var value = ""
            if i < end, header[i] == "\"" {
                i = header.index(after: i)
                while i < end, header[i] != "\"" {
                    if header[i] == "\\" {
                        let next = header.index(after: i)
                        if next < end { i = next }
                    }
                    value.append(header[i])
                    i = header.index(after: i)
                }
                if i < end { i = header.index(after: i) }
            } else {
                let valueStart = i
                while i < end, header[i] != ";" { i = header.index(after: i) }
                value = header[valueStart..<i].trimmingCharacters(in: .whitespaces)
            }
            if !name.isEmpty, result[name] == nil { result[name] = value }
        }
        return result
    }

    /// `UTF-8''na%C3%AFve.txt` → `naïve.txt`. Supports UTF-8 and ISO-8859-1.
    private static func decodeExtendedValue(_ value: String) -> String? {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { return nil }
        let encoding: String.Encoding
        switch parts[0].lowercased() {
        case "utf-8", "": encoding = .utf8
        case "iso-8859-1": encoding = .isoLatin1
        default: return nil
        }
        var bytes: [UInt8] = []
        let source = Array(parts[2].utf8)
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "%"), index + 2 < source.count,
               let byte = UInt8(String(decoding: source[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                bytes.append(byte)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return String(bytes: bytes, encoding: encoding)
    }

    /// Servers often put raw UTF-8 in the plain `filename` parameter, which HTTP stacks read as Latin-1.
    private static func repairUTF8Mojibake(_ value: String) -> String {
        guard !value.allSatisfy(\.isASCII),
              let latin1 = value.data(using: .isoLatin1),
              let repaired = String(data: latin1, encoding: .utf8) else { return value }
        return repaired
    }
}
