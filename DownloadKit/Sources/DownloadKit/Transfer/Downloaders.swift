import Foundation

/// Inputs shared by both transfer strategies.
struct TransferContext: Sendable {
    var request: RequestContext
    var validators: Validators
    var limiter: any RateLimiting
    var retry: RetryPolicy
    var totalBytes: Int64?
}

/// A transfer strategy: runs to completion and reports live progress.
protocol Downloader: Sendable {
    var receivedBytes: Int64 { get }
    var activeConnections: Int { get }
    func segmentSnapshots() -> [SegmentSnapshot]
    /// Copies resumable state into the record that gets persisted.
    func checkpoint(into record: inout DownloadRecord)
    /// Makes everything written so far durable. A checkpoint must never describe bytes that a power
    /// loss could still take away, so callers snapshot the counts first, then flush, then persist.
    func flush() async
    func run() async throws
}

/// N connection slots pulling segments from a scheduler. One connection is simply `slots == 1`.
final class SegmentedDownloader: Downloader, Sendable {
    let scheduler: SegmentScheduler
    private let file: PartFile
    private let context: TransferContext
    private let slots: Int

    init(scheduler: SegmentScheduler, file: PartFile, context: TransferContext, slots: Int) {
        self.scheduler = scheduler
        self.file = file
        self.context = context
        self.slots = max(1, slots)
    }

    var receivedBytes: Int64 { scheduler.receivedBytes }
    var activeConnections: Int { scheduler.runningCount }
    func segmentSnapshots() -> [SegmentSnapshot] { scheduler.snapshots() }

    func checkpoint(into record: inout DownloadRecord) {
        record.segments = scheduler.segments()
        record.receivedBytes = scheduler.receivedBytes
    }

    func flush() async { await file.syncInBackground() }

    func run() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<slots {
                group.addTask { try await self.slotLoop() }
            }
            try await group.waitForAll()
        }
    }

    private func slotLoop() async throws {
        while let index = scheduler.claim() {
            defer { scheduler.release(index) }
            try await download(segment: index)
        }
    }

    /// Fetches one segment, resuming from what is on disk after every failed attempt. Attempts that
    /// moved the segment forward do not count against the retry budget.
    private func download(segment index: Int) async throws {
        var fruitlessAttempts = 0
        while true {
            try Task.checkCancellation()
            guard let attempt = scheduler.prepareAttempt(index) else { return }
            let before = scheduler.received(index)

            var failure: DownloadError?
            do {
                let transfer = SegmentTransfer(
                    request: context.request.urlRequest(range: (attempt.offset, attempt.end), ifRange: context.validators.ifRange),
                    expectation: .range(start: attempt.offset, end: attempt.end, total: context.totalBytes),
                    validators: context.validators,
                    target: RangeTarget(scheduler: scheduler, index: index, file: file),
                    limiter: context.limiter,
                    timeout: context.request.timeout
                )
                try await transfer.run()
            } catch let error as DownloadError {
                failure = error // anything else, including cancellation, propagates
            }

            if scheduler.isComplete(index) { return }
            let error = failure ?? .shortRead
            guard error.isRetryable else { throw error }

            if scheduler.received(index) > before {
                fruitlessAttempts = 0
            } else {
                fruitlessAttempts += 1
                guard fruitlessAttempts <= context.retry.maxAttempts else { throw error }
                let delay = context.retry.delay(forAttempt: fruitlessAttempts, retryAfter: error.retryAfter)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }
}

/// One plain GET: for servers without range support, or with an unknown size. Not resumable.
final class SingleDownloader: Downloader, Sendable {
    let target: StreamTarget
    private let context: TransferContext

    init(target: StreamTarget, context: TransferContext) {
        self.target = target
        self.context = context
    }

    var receivedBytes: Int64 { target.receivedBytes }
    var activeConnections: Int { 1 }
    func segmentSnapshots() -> [SegmentSnapshot] { [] }

    func checkpoint(into record: inout DownloadRecord) {
        record.receivedBytes = target.receivedBytes
    }

    func flush() async {} // not resumable: nothing is ever trusted after a stop

    func run() async throws {
        var failures = 0
        while true {
            try Task.checkCancellation()
            try target.reset()
            do {
                let transfer = SegmentTransfer(
                    request: context.request.urlRequest(),
                    expectation: .whole,
                    validators: context.validators,
                    target: target,
                    limiter: context.limiter,
                    timeout: context.request.timeout
                )
                try await transfer.run()
                return
            } catch let error as DownloadError where error.isRetryable {
                failures += 1
                guard failures <= context.retry.maxAttempts else { throw error }
                try await Task.sleep(for: .seconds(context.retry.delay(forAttempt: failures, retryAfter: error.retryAfter)))
            }
        }
    }
}
