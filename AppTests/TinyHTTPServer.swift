import Foundation
import Network
import Synchronization

/// A minimal loopback HTTP server for the app's integration tests. It ignores Range, so the engine
/// downloads over a single connection, and it can pace the body so a download stays in flight.
final class TinyHTTPServer: Sendable {
    private let listener: NWListener
    private let body: Data
    private let chunkSize: Int
    private let delay: Duration
    private let requestLog = Mutex<[String]>([])
    let port: UInt16

    static func start(body: Data, chunkSize: Int = 16 * 1024, delay: Duration = .zero) async throws -> TinyHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let done = Mutex(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if done.withLock({ let was = $0; $0 = true; return !was }), let port = listener.port?.rawValue { continuation.resume(returning: port) }
                case .failed(let error):
                    if done.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: DispatchQueue(label: "TinyHTTPServer.listener"))
        }
        let server = TinyHTTPServer(listener: listener, body: body, chunkSize: chunkSize, delay: delay, port: port)
        listener.newConnectionHandler = { [server] connection in server.accept(connection) }
        return server
    }

    private init(listener: NWListener, body: Data, chunkSize: Int, delay: Duration, port: UInt16) {
        self.listener = listener
        self.body = body
        self.chunkSize = chunkSize
        self.delay = delay
        self.port = port
    }

    func url(_ path: String = "/file.bin") -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }
    func stop() { listener.cancel() }
    var requests: [String] { requestLog.withLock { $0 } }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "TinyHTTPServer.connection"))
        Task {
            await serve(connection)
            connection.cancel()
        }
    }

    private func serve(_ connection: NWConnection) async {
        var buffer = Data()
        let end = Data("\r\n\r\n".utf8)
        while buffer.range(of: end) == nil {
            guard buffer.count < 65536, let chunk = await receive(connection) else { return }
            buffer.append(chunk)
        }
        let head = String(decoding: buffer, as: UTF8.self)
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        requestLog.withLock { $0.append(requestLine) }
        let isHead = requestLine.hasPrefix("HEAD")

        let header = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nContent-Type: application/octet-stream\r\nConnection: close\r\n\r\n"
        guard await send(connection, Data(header.utf8)), !isHead else { return }
        var offset = 0
        while offset < body.count {
            let next = min(offset + chunkSize, body.count)
            guard await send(connection, body.subdata(in: offset..<next)) else { return }
            offset = next
            if delay > .zero { try? await Task.sleep(for: delay) }
        }
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                continuation.resume(returning: error == nil && !(data == nil && isComplete) ? data : nil)
            }
        }
    }

    private func send(_ connection: NWConnection, _ data: Data) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { continuation.resume(returning: $0 == nil) })
        }
    }
}
