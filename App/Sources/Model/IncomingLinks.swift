import DownloadKit
import Foundation
import UniformTypeIdentifiers

/// Turns what the system hands the app (`downloader://` links, dropped or opened text files, plain web
/// links) into download links. Nothing here adds a download.
enum IncomingLinks {
    /// What was found, plus a message for each item that could not be read.
    struct Resolution: Equatable, Sendable {
        var links: [URL] = []
        var problems: [String] = []
    }

    static func resolve(_ urls: [URL]) async -> Resolution {
        var resolution = Resolution()
        for url in urls {
            if url.isFileURL {
                guard isTextFile(url) else { continue }
                do {
                    // Reading and scanning a file happens off the main actor.
                    resolution.links += try await Task.detached { try LinkParser.urls(inFileAt: url) }.value
                } catch {
                    resolution.problems.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            } else if let links = SchemeLink.urls(from: url) {
                resolution.links += links
            } else if let link = LinkParser.httpURL(url.absoluteString) {
                resolution.links.append(link)
            }
        }
        var seen = Set<String>()
        resolution.links = resolution.links.filter { seen.insert($0.absoluteString).inserted }
        return resolution
    }

    private static func isTextFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .plainText)
    }
}
