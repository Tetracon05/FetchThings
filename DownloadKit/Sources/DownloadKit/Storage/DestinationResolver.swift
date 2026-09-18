import Darwin
import Foundation

enum DestinationResolver {
    /// Validates the download directory, creating it if needed, and returns its symlink-resolved form.
    static func prepareDirectory(_ directory: URL) throws -> URL {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw DownloadError.unsafeDestination("destination must be an absolute file path")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.fileSystem("cannot create \(directory.path): \(error.localizedDescription)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DownloadError.unsafeDestination("\(directory.path) is not a directory")
        }
        return canonical(directory)
    }

    /// The directory with symlinks resolved, so two spellings of one folder compare equal.
    static func canonical(_ directory: URL) -> URL {
        directory.resolvingSymlinksInPath().standardizedFileURL
    }

    static func fileSize(of url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// `directory/name`, guaranteed to be a direct child of `directory`.
    ///
    /// `name` must already be a single plain component. This second check exists so that a bug or a
    /// tampered job file can never turn a name into a path that escapes the download folder.
    static func childURL(in directory: URL, named name: String) throws -> URL {
        guard FilenameSanitizer.isSafeComponent(name) else {
            throw DownloadError.unsafeDestination("\"\(name)\" is not a valid file name")
        }
        let base = canonical(directory)
        let child = base.appending(path: name, directoryHint: .notDirectory)
        guard child.deletingLastPathComponent().standardizedFileURL.path == base.path else {
            throw DownloadError.unsafeDestination("\"\(name)\" resolves outside the download folder")
        }
        return child
    }

    static func availableSpace(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Moves the finished file to `directory/name` without ever replacing an existing file. On a name
    /// clash the next free ` (n)` variant is used. Returns the name actually written.
    static func moveIntoPlace(_ source: URL, directory: URL, name: String) throws -> String {
        var candidate = name
        for attempt in 1...1000 {
            let destination = try childURL(in: directory, named: candidate)
            if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            switch errno {
            case EEXIST:
                candidate = NameAllocator.variant(of: name, number: attempt + 1)
            case ENOTSUP, EINVAL:
                // Filesystem without exclusive rename (some network volumes): best-effort check-then-move.
                if FileManager.default.fileExists(atPath: destination.path) {
                    candidate = NameAllocator.variant(of: name, number: attempt + 1)
                    continue
                }
                do { try FileManager.default.moveItem(at: source, to: destination) } catch {
                    throw DownloadError.fileSystem("cannot move into place: \(error.localizedDescription)")
                }
                return candidate
            default:
                throw DownloadError.posix("cannot move into place", errno)
            }
        }
        throw DownloadError.fileSystem("no free file name for \(name)")
    }

    /// What is recorded about where a file came from. Credentials embedded in the URL are dropped.
    static func quarantineProperties(origin: URL, agent: String, date: Date = Date()) -> [String: Any] {
        [
            "LSQuarantineType": "LSQuarantineTypeWebDownload",
            "LSQuarantineAgentName": agent,
            "LSQuarantineDataURL": origin.splittingCredentials().url.absoluteString,
            "LSQuarantineTimeStamp": date,
        ]
    }

    /// Marks the file as downloaded from the internet so Gatekeeper and quarantine-aware apps check it.
    static func applyQuarantine(to file: URL, origin: URL, agent: String) {
        var values = URLResourceValues()
        values.quarantineProperties = quarantineProperties(origin: origin, agent: agent)
        var target = file
        try? target.setResourceValues(values)
    }
}

/// Hands out file names that collide with neither files on disk, `.part` files, nor other downloads
/// in flight.
struct NameAllocator {
    private var reserved: Set<String> = []

    /// Reserves `desired` (or the first free ` (n)` variant) in `directory`.
    mutating func reserve(directory: URL, desired: String) throws -> String {
        var candidate = desired
        for number in 1...10_000 {
            let path = Self.key(directory, candidate)
            let taken = reserved.contains(path)
                || FileManager.default.fileExists(atPath: path)
                || FileManager.default.fileExists(atPath: path + ".part")
            if !taken {
                reserved.insert(path)
                return candidate
            }
            candidate = Self.variant(of: desired, number: number + 1)
        }
        throw DownloadError.fileSystem("no free file name for \(desired)")
    }

    /// Reserves an exact name without checking the disk (used when reloading persisted downloads).
    mutating func adopt(directory: URL, name: String) {
        reserved.insert(Self.key(directory, name))
    }

    mutating func release(directory: URL, name: String) {
        reserved.remove(Self.key(directory, name))
    }

    private static func key(_ directory: URL, _ name: String) -> String {
        DestinationResolver.canonical(directory).appending(path: name, directoryHint: .notDirectory).path
    }

    /// `report.pdf` → `report (2).pdf`.
    static func variant(of name: String, number: Int) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension
        let stem = ext.isEmpty ? name : ns.deletingPathExtension
        return ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
    }
}
