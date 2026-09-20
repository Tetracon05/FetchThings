import Foundation
import Synchronization

/// One HTTP request whose body is streamed into a `TransferTarget`.
///
/// Each transfer owns its own `URLSession`, which is what makes N segments N real connections: over
/// HTTP/2 or HTTP/3, requests sharing a session would be multiplexed onto one connection. Chunks are
/// written from the delegate queue directly, with no actor hop per chunk.
final class SegmentTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Expectation: Sendable {
        /// A ranged request for `start...end`; `total` is the full resource size when known.
        case range(start: Int64, end: Int64, total: Int64?)
        /// A plain GET of the whole body.
        case whole
    }

    private struct State {
        var task: URLSessionDataTask?
        var continuation: CheckedContinuation<Void, Error>?
        var stoppedExternally = false
        var failure: DownloadError?
        var targetFull = false
        var expectedBody: Int64?
        var received: Int64 = 0
        var suspended = false
    }

    private let request: URLRequest
    private let expectation: Expectation
    private let validators: Validators
    private let target: any TransferTarget
    private let limiter: any RateLimiting
    private let configuration: URLSessionConfiguration
    private let state = Mutex(State())
    private let queue: OperationQueue

    init(
        request: URLRequest,
        expectation: Expectation,
        validators: Validators,
        target: any TransferTarget,
        limiter: any RateLimiting,
        timeout: TimeInterval
    ) {
        self.request = request
        self.expectation = expectation
        self.validators = validators
        self.target = target
        self.limiter = limiter
        self.configuration = RequestContext.sessionConfiguration(timeout: timeout)
        self.queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "DownloadKit.SegmentTransfer"
        super.init()
    }

    /// Runs the request to completion. Throws `CancellationError` when the calling task is cancelled.
    func run() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                let alreadyStopped = state.withLock { state -> Bool in
                    if state.stoppedExternally { return true }
                    state.continuation = continuation
                    state.task = task
                    return false
                }
                if alreadyStopped {
                    session.invalidateAndCancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                task.resume()
                // The session retains its delegate until invalidated; this releases it once the task ends.
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            stop()
        }
    }

    private func stop() {
        let task = state.withLock { state -> URLSessionDataTask? in
            state.stoppedExternally = true
            state.suspended = false
            return state.task
        }
        task?.cancel()
        task?.resume() // a suspended (throttled) task must be resumed to deliver its cancellation
    }

    private func fail(_ error: Error, cancelling task: URLSessionTask) {
        let failure = error as? DownloadError ?? .fileSystem(error.localizedDescription)
        state.withLock { if $0.failure == nil { $0.failure = failure } }
        task.cancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            let expected = try validate(response)
            state.withLock { $0.expectedBody = expected }
            completionHandler(.allow)
        } catch {
            fail(error, cancelling: dataTask)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            let taken = try target.consume(data)
            state.withLock { $0.received += Int64(taken) }
            if taken < data.count || target.isFull {
                state.withLock { $0.targetFull = true }
                dataTask.cancel()
                return
            }
            let delay = limiter.reserve(taken)
            if delay > 0 { throttle(dataTask, for: delay) }
        } catch {
            fail(error, cancelling: dataTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(RedirectPolicy.sanitize(request, trusting: self.request))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        enum Outcome { case success, failure(Error) }

        let (continuation, outcome): (CheckedContinuation<Void, Error>?, Outcome) = state.withLock { state in
            let continuation = state.continuation
            state.continuation = nil
            if let failure = state.failure { return (continuation, .failure(failure)) }
            if state.stoppedExternally { return (continuation, .failure(CancellationError())) }
            if state.targetFull { return (continuation, .success) }
            if let error { return (continuation, .failure(DownloadError.map(error))) }
            if let expected = state.expectedBody, state.received < expected {
                return (continuation, .failure(DownloadError.shortRead))
            }
            return (continuation, .success)
        }
        switch outcome {
        case .success: continuation?.resume()
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }

    // MARK: Validation

    /// Returns the number of body bytes the response promises, when known.
    private func validate(_ response: URLResponse) throws -> Int64? {
        guard let http = response as? HTTPURLResponse else {
            throw DownloadError.invalidRangeResponse("not an HTTP response")
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        let modified = http.value(forHTTPHeaderField: "Last-Modified")
        let length = http.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }

        switch expectation {
        case .whole:
            guard http.statusCode == 200 else { throw HTTPHeaders.statusError(http) }
            guard validators.matches(etag: etag, lastModified: modified) else { throw DownloadError.resourceChanged }
            return HTTPHeaders.hasContentEncoding(http) ? nil : length

        case .range(let start, let end, let total):
            switch http.statusCode {
            case 206:
                if HTTPHeaders.hasContentEncoding(http) { throw DownloadError.rangeNotHonored }
                guard let range = http.value(forHTTPHeaderField: "Content-Range").flatMap(HTTPHeaders.parseContentRange),
                      let first = range.start, let last = range.end else {
                    throw DownloadError.invalidRangeResponse("missing or malformed Content-Range")
                }
                guard first == start, last <= end else {
                    throw DownloadError.invalidRangeResponse("asked for \(start)-\(end), got \(first)-\(last)")
                }
                if let total, let served = range.total, served != total { throw DownloadError.resourceChanged }
                guard validators.matches(etag: etag, lastModified: modified) else { throw DownloadError.resourceChanged }
                return last - first + 1
            case 200:
                // Either the server ignores Range, or `If-Range` failed because the file changed.
                return try { throw validators.matches(etag: etag, lastModified: modified) ? DownloadError.rangeNotHonored : DownloadError.resourceChanged }()
            case 416:
                throw DownloadError.resourceChanged
            default:
                throw HTTPHeaders.statusError(http)
            }
        }
    }

    // MARK: Throttling

    /// Stalls the connection by suspending the task; unread data backs up in the socket and TCP flow
    /// control slows the server down.
    private func throttle(_ task: URLSessionDataTask, for delay: TimeInterval) {
        let shouldSuspend = state.withLock { state -> Bool in
            guard !state.suspended, !state.stoppedExternally else { return false }
            state.suspended = true
            return true
        }
        guard shouldSuspend else { return }
        task.suspend()
        scheduleResume(task, after: delay)
    }

    /// How often a stalled connection looks at the limiter again, so that a limit that is raised or removed while
    /// it waits lets it go on within this time and not after the whole old debt.
    private static let recheckInterval: TimeInterval = 0.25

    private func scheduleResume(_ task: URLSessionDataTask, after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + min(delay, Self.recheckInterval)) { [self] in
            let owed = limiter.pendingDelay()
            if owed > 0.001 {
                scheduleResume(task, after: owed)
                return
            }
            let shouldResume = state.withLock { state -> Bool in
                defer { state.suspended = false }
                return state.suspended
            }
            if shouldResume { task.resume() }
        }
    }
}
