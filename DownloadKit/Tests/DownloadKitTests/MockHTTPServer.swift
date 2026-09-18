import Foundation
import Network
import Synchronization

/// Deterministic pseudo-random content addressable by offset, so any byte range can be checked
/// without holding the file.
enum MockContent {
    static func byte(at index: Int, seed: UInt8) -> UInt8 {
        var z = UInt64(index >> 3) &+ UInt64(seed) &* 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return UInt8(truncatingIfNeeded: z >> UInt64((index & 7) * 8))
    }

    static func data(seed: UInt8, offset: Int = 0, length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        for i in 0..<length { bytes[i] = byte(at: offset + i, seed: seed) }
        return Data(bytes)
    }
}

struct MockRequest: Sendable {
    var method: String
    var path: String
    /// Lowercased names.
    var headers: [String: String]

    /// The parsed `Range: bytes=a-b` header.
    var range: (start: Int, end: Int?)? {
        guard let value = headers["range"], value.hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let start = Int(parts[0]) else { return nil }
        return (start, Int(parts[1]))
    }
}

enum MockBody: Sendable {
    case empty
    case data(Data)
    case generated(seed: UInt8, offset: Int, length: Int)

    var length: Int {
        switch self {
        case .empty: 0
        case .data(let data): data.count
        case .generated(_, _, let length): length
        }
    }
}

struct MockResponse: Sendable {
    var status = 200
    var headers: [(String, String)] = []
    var body: MockBody = .empty
    /// Throttle the body to roughly this many bytes per second.
    var bytesPerSecond: Int?
    /// Abruptly close the connection after this many body bytes.
    var dropAfterBodyBytes: Int?
    /// Delimit the body by closing the connection, like a stream of unknown length.
    var omitContentLength = false

    static func status(_ code: Int, headers: [(String, String)] = []) -> MockResponse {
        MockResponse(status: code, headers: headers)
    }

    func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }
}

/// A file served with the semantics real servers have, with knobs for the awkward ones.
struct MockResource: Sendable {
    var size: Int
    var seed: UInt8 = 1
    /// `false`: Range is ignored and the whole body comes back as 200.
    var honorsRange = true
    /// Whether `Accept-Ranges: bytes` is announced.
    var advertisesRanges = true
    var supportsHEAD = true
    var etag: String? = "\"v1\""
    var lastModified: String? = "Wed, 21 Oct 2015 07:28:00 GMT"
    var contentDisposition: String?
    var bytesPerSecond: Int?

    func response(for request: MockRequest) -> MockResponse {
        var headers: [(String, String)] = []
        if advertisesRanges { headers.append(("Accept-Ranges", "bytes")) }
        if let etag { headers.append(("ETag", etag)) }
        if let lastModified { headers.append(("Last-Modified", lastModified)) }
        if let contentDisposition { headers.append(("Content-Disposition", contentDisposition)) }
        headers.append(("Content-Type", "application/octet-stream"))

        if request.method == "HEAD" {
            guard supportsHEAD else { return .status(405) }
            return MockResponse(status: 200, headers: headers + [("Content-Length", String(size))])
        }

        // If-Range: a mismatching validator means "send everything".
        var rangeApplies = honorsRange
        if let ifRange = request.headers["if-range"], ifRange != etag, ifRange != lastModified { rangeApplies = false }

        if rangeApplies, let range = request.range {
            guard range.start < size else {
                return .status(416, headers: [("Content-Range", "bytes */\(size)")])
            }
            let end = min(range.end ?? size - 1, size - 1)
            let length = end - range.start + 1
            return MockResponse(
                status: 206,
                headers: headers + [("Content-Range", "bytes \(range.start)-\(end)/\(size)")],
                body: .generated(seed: seed, offset: range.start, length: length),
                bytesPerSecond: bytesPerSecond
            )
        }
        return MockResponse(status: 200, headers: headers, body: .generated(seed: seed, offset: 0, length: size), bytesPerSecond: bytesPerSecond)
    }
}

final class Counter: Sendable {
    private let value = Mutex(0)
    /// Increments and returns the new value (1 for the first call).
    func next() -> Int { value.withLock { $0 += 1; return $0 } }
    var current: Int { value.withLock { $0 } }
}

/// A minimal HTTP/1.1 server on loopback. Every response closes its connection, so the number of
/// simultaneously open connections equals the number of requests in flight.
final class MockHTTPServer: Sendable {
    typealias Handler = @Sendable (MockRequest) -> MockResponse

    private struct Stats {
        var requests: [MockRequest] = []
        var open = 0
        var maxOpen = 0
        var bodyBytesSent = 0
    }

    private let listener: NWListener
    private let handler: Handler
    private let stats = Mutex(Stats())
    private let queue = DispatchQueue(label: "MockHTTPServer")
    let port: UInt16

    static func start(_ handler: @escaping Handler) async throws -> MockHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "MockHTTPServer.listener")

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.withLock({ let was = $0; $0 = true; return !was }), let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        let server = MockHTTPServer(listener: listener, handler: handler, port: port)
        listener.newConnectionHandler = { [server] connection in server.accept(connection) }
        return server
    }

    private init(listener: NWListener, handler: @escaping Handler, port: UInt16) {
        self.listener = listener
        self.handler = handler
        self.port = port
    }

    func url(_ path: String = "/file.bin") -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func stop() { listener.cancel() }

    var requests: [MockRequest] { stats.withLock { $0.requests } }
    var maxConcurrentConnections: Int { stats.withLock { $0.maxOpen } }
    var bodyBytesSent: Int { stats.withLock { $0.bodyBytesSent } }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        stats.withLock { $0.open += 1; $0.maxOpen = max($0.maxOpen, $0.open) }
        connection.start(queue: queue)
        Task {
            await self.serve(connection)
            connection.cancel()
            self.stats.withLock { $0.open -= 1 }
        }
    }

    private func serve(_ connection: NWConnection) async {
        guard let request = await readRequest(connection) else { return }
        stats.withLock { $0.requests.append(request) }
        let response = handler(request)
        do { try await write(response, for: request, to: connection) } catch { /* client went away */ }
    }

    private func readRequest(_ connection: NWConnection) async -> MockRequest? {
        var buffer = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while buffer.range(of: terminator) == nil {
            guard buffer.count < 65536, let chunk = await receive(connection) else { return nil }
            buffer.append(chunk)
        }
        let head = String(decoding: buffer[..<buffer.range(of: terminator)!.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return MockRequest(method: requestLine[0], path: requestLine[1], headers: headers)
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                continuation.resume(returning: error == nil && !(data == nil && isComplete) ? data : nil)
            }
        }
    }

    private func write(_ response: MockResponse, for request: MockRequest, to connection: NWConnection) async throws {
        var head = "HTTP/1.1 \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))\r\n"
        for (name, value) in response.headers { head += "\(name): \(value)\r\n" }
        if response.header("Content-Length") == nil, !response.omitContentLength { head += "Content-Length: \(response.body.length)\r\n" }
        head += "Connection: close\r\n\r\n"
        try await send(connection, Data(head.utf8))
        guard request.method != "HEAD" else { return }

        let chunkSize = 16 * 1024
        var sent = 0
        let total = response.body.length
        while sent < total {
            var count = min(chunkSize, total - sent)
            if let drop = response.dropAfterBodyBytes {
                if sent >= drop { return } // close abruptly with bytes still owed
                count = min(count, drop - sent)
            }
            let chunk: Data
            switch response.body {
            case .empty: chunk = Data()
            case .data(let data): chunk = data.subdata(in: sent..<(sent + count))
            case .generated(let seed, let offset, _): chunk = MockContent.data(seed: seed, offset: offset + sent, length: count)
            }
            try await send(connection, chunk)
            sent += count
            stats.withLock { $0.bodyBytesSent += count }
            if let rate = response.bytesPerSecond {
                try await Task.sleep(for: .seconds(Double(count) / Double(rate)))
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
