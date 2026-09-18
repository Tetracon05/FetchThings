import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Sidebar categories, derived from the file name's extension.
enum FileCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case documents, archives, video, audio, images, applications, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .documents: "Documents"
        case .archives: "Archives"
        case .video: "Video"
        case .audio: "Audio"
        case .images: "Images"
        case .applications: "Applications"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .documents: "doc.text"
        case .archives: "archivebox"
        case .video: "film"
        case .audio: "music.note"
        case .images: "photo"
        case .applications: "app.dashed"
        case .other: "questionmark.folder"
        }
    }

    // Explicit lists win over UTType conformance. The system only declares types it ships support for, so
    // common formats such as Matroska, WebM or Opus have no type to conform to on a stock Mac, and installers
    // and disk images do not conform to anything useful.
    private static let applicationExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "exe", "msi", "deb", "rpm", "apk", "ipa", "appimage"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "lz", "lzma", "cab"]
    private static let documentExtensions: Set<String> = ["doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "odt", "ods", "odp", "epub", "mobi", "md", "csv"]
    /// Generic binary blobs. The system maps `bin` to MacBinary (an archive format), but a downloaded `.bin`
    /// is almost always a raw firmware or disk image.
    private static let genericExtensions: Set<String> = ["bin", "dat", "img"]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "ogv", "3gp", "m2ts", "vob"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "ogg", "oga", "opus", "wma", "mka", "wav", "aif", "aiff"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "heif", "tif", "tiff", "bmp", "svg", "raw", "cr2", "nef", "dng"]

    /// The sidebar counts classify every download several times per refresh, and the fallback asks the
    /// system for a type each time, so results are remembered per extension. The cap keeps a stream of
    /// unusual extensions from growing it without bound.
    private static let cache = Mutex<[String: FileCategory]>([:])
    private static let cacheLimit = 1024

    static func classify(filename: String?) -> FileCategory {
        guard let filename else { return .other }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        if let known = cache.withLock({ $0[ext] }) { return known }
        let category = classify(extension: ext)
        cache.withLock { if $0.count < cacheLimit { $0[ext] = category } }
        return category
    }

    private static func classify(extension ext: String) -> FileCategory {
        if genericExtensions.contains(ext) { return .other }
        if applicationExtensions.contains(ext) { return .applications }
        if archiveExtensions.contains(ext) { return .archives }
        if documentExtensions.contains(ext) { return .documents }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if imageExtensions.contains(ext) { return .images }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .archive) { return .archives }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation) || type.conforms(to: .spreadsheet) {
            return .documents
        }
        return .other
    }
}
