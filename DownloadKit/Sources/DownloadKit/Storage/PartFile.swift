import Foundation

/// The `.part` file. Segments write at absolute offsets with `pwrite`, so any number of connections can
/// write concurrently through one descriptor without locking.
final class PartFile: Sendable {
    let url: URL
    private let fd: Int32

    /// Opens (creating if needed) the file. With `size`, the file is extended to that length; on APFS
    /// the extension is sparse, so no space is consumed until bytes arrive.
    ///
    /// The final path component is never followed if it is a symlink.
    init(url: URL, size: Int64?) throws {
        self.url = url
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw DownloadError.posix("open \(url.lastPathComponent)", errno) }
        if let size {
            var info = stat()
            if fstat(descriptor, &info) == 0, info.st_size != size {
                guard ftruncate(descriptor, off_t(size)) == 0 else {
                    let code = errno
                    close(descriptor)
                    throw DownloadError.posix("allocate \(url.lastPathComponent)", code)
                }
            }
        }
        // Assigned last: once every stored property is set, a throw would run `deinit`, closing twice.
        fd = descriptor
    }

    deinit { close(fd) }

    var size: Int64 {
        var info = stat()
        return fstat(fd, &info) == 0 ? Int64(info.st_size) : 0
    }

    func write(_ data: Data, at offset: Int64) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let n = pwrite(fd, base + written, buffer.count - written, off_t(offset) + off_t(written))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DownloadError.posix("write", errno)
                }
                written += n
            }
        }
    }

    func truncate(to length: Int64) throws {
        guard ftruncate(fd, off_t(length)) == 0 else { throw DownloadError.posix("truncate", errno) }
    }

    func sync() throws {
        guard fsync(fd) == 0 else { throw DownloadError.posix("fsync", errno) }
    }

    /// `fsync` on a background queue, so a slow disk never stalls an actor or the cooperative pool.
    func syncInBackground() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                _ = fsync(self.fd)
                continuation.resume()
            }
        }
    }
}
