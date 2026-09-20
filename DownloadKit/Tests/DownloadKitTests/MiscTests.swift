import Foundation
import Testing
@testable import DownloadKit

@Suite("Checksums")
struct ChecksumTests {
    // Reference digests of the ASCII string "abc".
    static let sha256abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    static let md5abc = "900150983cd24fb0d6963f7d28e17f72"

    private func file(containing text: String) throws -> (URL, TestEnvironment) {
        let env = try TestEnvironment()
        let url = env.file("data.bin")
        try Data(text.utf8).write(to: url)
        return (url, env)
    }

    @Test func computesKnownDigests() async throws {
        let (url, env) = try file(containing: "abc")
        defer { env.cleanup() }
        #expect(try await ChecksumVerifier.digest(of: url, algorithm: .sha256) == Self.sha256abc)
        #expect(try await ChecksumVerifier.digest(of: url, algorithm: .md5) == Self.md5abc)
    }

    @Test func hashesLargeFilesInChunks() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let content = MockContent.data(seed: 9, length: 5_000_000)
        try content.write(to: env.file("big.bin"))
        let reported = Counter()
        let digest = try await ChecksumVerifier.digest(of: env.file("big.bin"), algorithm: .sha256) { _ in _ = reported.next() }
        #expect(digest == sha256Hex(of: content))
        #expect(reported.current >= 4, "progress should be reported per chunk")
    }

    @Test func parsesTheCommonWrittenForms() {
        #expect(Checksum(parsing: "sha256:\(Self.sha256abc.uppercased())") == Checksum(algorithm: .sha256, hex: Self.sha256abc))
        #expect(Checksum(parsing: "MD5: \(Self.md5abc)")?.algorithm == .md5, "a space after the colon is how digests are usually written")
        #expect(Checksum(parsing: "md5:\(Self.md5abc)")?.algorithm == .md5)
        #expect(Checksum(parsing: Self.sha256abc)?.algorithm == .sha256, "a bare 64-digit digest is SHA-256")
        #expect(Checksum(parsing: "  \(Self.md5abc)\n")?.algorithm == .md5, "a bare 32-digit digest is MD5")
        for bad in ["", "sha256:xyz", "sha1:\(Self.md5abc)", "zzzz", String(repeating: "g", count: 64)] {
            #expect(Checksum(parsing: bad) == nil, "\(bad)")
        }
    }

    @Test func missingFileThrows() async {
        await #expect(throws: (any Error).self) {
            try await ChecksumVerifier.digest(of: URL(filePath: "/nonexistent/file"), algorithm: .sha256)
        }
    }
}

@Suite("Link import")
struct LinkParserTests {
    @Test func extractsPlainListsInOrderWithoutDuplicates() {
        let text = """
        https://example.com/a.zip
        http://example.com/b.zip

        https://example.com/a.zip
        """
        #expect(LinkParser.urls(in: text).map(\.absoluteString) == ["https://example.com/a.zip", "http://example.com/b.zip"])
    }

    @Test func skipsCommentsAndNonHTTPSchemes() {
        let text = """
        # https://example.com/commented.zip
        ftp://example.com/old.zip
        file:///etc/passwd
        mailto:someone@example.com
        example.com/bare-host.zip
        https://example.com/real.zip
        """
        #expect(LinkParser.urls(in: text).map(\.absoluteString) == ["https://example.com/real.zip"])
    }

    @Test func findsLinksInsideProse() {
        let text = "Grab https://example.com/one.iso and (https://example.com/two.iso), then http://example.com/three.iso."
        let urls = LinkParser.urls(in: text).map(\.absoluteString)
        #expect(urls.contains("https://example.com/one.iso"))
        #expect(urls.contains("https://example.com/two.iso"))
        #expect(urls.contains("http://example.com/three.iso"))
    }

    @Test func keepsQueryStringsAndPercentEncoding() {
        let urls = LinkParser.urls(in: "https://example.com/get?id=7&name=a%20b#frag")
        #expect(urls.map(\.absoluteString) == ["https://example.com/get?id=7&name=a%20b#frag"])
    }

    @Test func readsFilesAndEnforcesTheSizeLimit() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        try "https://example.com/x.bin\n".write(to: env.file("links.txt"), atomically: true, encoding: .utf8)
        #expect(try LinkParser.urls(inFileAt: env.file("links.txt")).count == 1)

        let huge = Data(count: LinkParser.maxFileSize + 1)
        try huge.write(to: env.file("huge.txt"))
        #expect(throws: LinkParserError.fileTooLarge(limitMB: 5)) { try LinkParser.urls(inFileAt: env.file("huge.txt")) }
    }

    @Test func capsTheNumberOfLinks() {
        let text = (0..<(LinkParser.maxLinks + 50)).map { "https://example.com/\($0)" }.joined(separator: "\n")
        #expect(LinkParser.urls(in: text).count == LinkParser.maxLinks)
    }
}

@Suite("Storage")
struct StorageTests {
    @Test func partFileIsSparseAndWritableAtAnyOffset() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let size: Int64 = 256 * 1024 * 1024
        let file = try PartFile(url: env.file("big.part"), size: size)
        #expect(file.size == size)

        try file.write(Data("tail".utf8), at: size - 4)
        try file.write(Data("head".utf8), at: 0)

        let values = try env.file("big.part").resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey])
        #expect(values.fileSize == Int(size))
        #expect((values.fileAllocatedSize ?? Int.max) < 1024 * 1024, "preallocation must be sparse, not 256 MiB of real blocks")

        let handle = try FileHandle(forReadingFrom: env.file("big.part"))
        try handle.seek(toOffset: UInt64(size - 4))
        #expect(try handle.read(upToCount: 4) == Data("tail".utf8))
    }

    @Test func partFileRefusesToFollowASymlink() throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let victim = env.file("victim.txt")
        try Data("do not touch".utf8).write(to: victim)
        let link = env.file("link.part")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

        #expect(throws: DownloadError.self) { try PartFile(url: link, size: 10) }
        #expect(try Data(contentsOf: victim) == Data("do not touch".utf8))
    }

    @Test func snapshotsCarryTheOrderDownloadsWereAddedIn() async throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let manager = env.makeManager()
        var ids: [DownloadID] = []
        for n in 1...5 {
            ids.append(try await manager.add(env.newDownload(URL(string: "http://127.0.0.1:9/\(n).bin")!) { $0.startPaused = true }))
        }
        let sequences = await ids.asyncMap { await manager.snapshot($0)?.sequence }
        #expect(sequences.compactMap { $0 } == sequences.compactMap { $0 }.sorted(), "counts up in the order they were added")
        #expect(Set(sequences.compactMap { $0 }).count == 5, "and never repeats, unlike createdAt, which job files keep only to the millisecond")
    }

    @Test func fileStoreRoundTripsAndKeepsQueueOrder() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let store = FileJobStore(directory: env.jobs)

        var second = DownloadRecord(url: URL(string: "https://example.com/2")!, destinationDirectory: env.downloads, sequence: 2)
        second.segments = [Segment(index: 0, start: 0, end: 99, received: 42)]
        second.etag = "\"tag\""
        second.mode = .segmented
        let first = DownloadRecord(url: URL(string: "https://example.com/1")!, destinationDirectory: env.downloads, sequence: 1)
        try await store.save(second)
        try await store.save(first)

        let loaded = try await store.loadAll()
        #expect(loaded.map(\.sequence) == [1, 2])
        #expect(loaded[1].segments == second.segments)
        #expect(loaded[1].etag == "\"tag\"")

        try await store.delete(id: first.id)
        #expect(try await store.loadAll().count == 1)
    }

    @Test func fileStoreKeepsFractionsOfASecondSoABatchKeepsItsOrder() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let store = FileJobStore(directory: env.jobs)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        var records: [DownloadRecord] = []
        for index in 0..<3 {
            var record = DownloadRecord(url: URL(string: "https://example.com/\(index)")!, destinationDirectory: env.downloads)
            record.createdAt = base.addingTimeInterval(Double(index) * 0.004)
            records.append(record)
            try await store.save(record)
        }
        let loaded = try await store.loadAll().sorted { $0.createdAt < $1.createdAt }
        #expect(loaded.map(\.id) == records.map(\.id), "added a few milliseconds apart, they must still be told apart")
        for (saved, original) in zip(loaded, records) {
            #expect(abs(saved.createdAt.timeIntervalSince(original.createdAt)) < 0.0015, "millisecond precision is what the format keeps")
        }
    }

    @Test func fileStoreStillReadsJobFilesWrittenWithWholeSeconds() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        var record = DownloadRecord(url: URL(string: "https://example.com/old")!, destinationDirectory: env.downloads)
        record.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        // The format the app wrote before fractional seconds were kept.
        let legacy = JSONEncoder()
        legacy.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: env.jobs, withIntermediateDirectories: true)
        try legacy.encode(record).write(to: env.jobs.appending(path: "\(record.id.uuidString).json"))

        let loaded = try #require(try await FileJobStore(directory: env.jobs).loadAll().first)
        #expect(loaded.id == record.id)
        #expect(loaded.createdAt == record.createdAt)
    }

    @Test func fileStoreIsPrivateAndSkipsCorruptFiles() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let store = FileJobStore(directory: env.jobs)
        let record = DownloadRecord(url: URL(string: "https://example.com/x")!, destinationDirectory: env.downloads)
        try await store.save(record)
        try Data("{ not json".utf8).write(to: env.jobs.appending(path: "garbage.json"))

        let directoryMode = try FileManager.default.attributesOfItem(atPath: env.jobs.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: env.jobs.appending(path: "\(record.id.uuidString).json").path)[.posixPermissions] as? Int
        #expect(directoryMode == 0o700)
        #expect(fileMode == 0o600)
        #expect(try await store.loadAll().map(\.id) == [record.id])
    }

    @Test func recordsNeverContainSecrets() throws {
        // DownloadRecord has no field for cookies, headers or credentials: they live in the SecretStore.
        let record = DownloadRecord(url: URL(string: "https://example.com/x")!, destinationDirectory: URL(filePath: "/tmp"))
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self).lowercased()
        for word in ["cookie", "password", "authorization", "header"] { #expect(!json.contains(word)) }
    }
}

@Suite("Shared helpers")
struct HelperTests {
    @Test func splitsCredentialsOutOfAURL() {
        let (url, credentials) = URL(string: "https://ann:p%40ss%3Aw@example.com:8443/a/b.zip?x=1#f")!.splittingCredentials()
        #expect(url.absoluteString == "https://example.com:8443/a/b.zip?x=1#f")
        #expect(credentials == BasicAuth(username: "ann", password: "p@ss:w"), "the password is percent-decoded")
    }

    @Test func aUserWithoutAPasswordGetsAnEmptyOne() {
        let (url, credentials) = URL(string: "https://ann@example.com/f")!.splittingCredentials()
        #expect(url.absoluteString == "https://example.com/f")
        #expect(credentials == BasicAuth(username: "ann", password: ""))
    }

    @Test func aURLWithoutCredentialsIsReturnedUnchanged() {
        let original = URL(string: "https://example.com/a%20b?q=1")!
        let (url, credentials) = original.splittingCredentials()
        #expect(url == original)
        #expect(credentials == nil)
    }

    @Test func posixErrorsCarryTheSystemMessage() {
        #expect(DownloadError.posix("open x", ENOENT) == .fileSystem("open x: No such file or directory"))
        #expect(DownloadError.posix("write", ENOSPC) == .fileSystem("write: No space left on device"))
    }

    @Test func canonicalDirectoriesCompareEqualAcrossSpellingsAndSymlinks() throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        let link = env.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: env.downloads)
        // Compared by path, as the resolver does: URLs differing only by a trailing slash are unequal as values.
        let plain = DestinationResolver.canonical(env.downloads).path
        #expect(DestinationResolver.canonical(link).path == plain)
        #expect(DestinationResolver.canonical(env.downloads.appending(path: "sub/..")).path == plain)
    }

    @Test func fileSizeIsNilForMissingFiles() throws {
        let env = try TestEnvironment(); defer { env.cleanup() }
        try Data(count: 1234).write(to: env.file("a.bin"))
        #expect(DestinationResolver.fileSize(of: env.file("a.bin")) == 1234)
        #expect(DestinationResolver.fileSize(of: env.file("missing.bin")) == nil)
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var result: [T] = []
        for element in self { result.append(await transform(element)) }
        return result
    }
}
