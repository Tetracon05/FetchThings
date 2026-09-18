import Foundation

/// What a job tells the manager: the current snapshot, plus the record when it should be persisted.
struct JobReport: Sendable {
    var snapshot: DownloadSnapshot
    var record: DownloadRecord?
}

struct JobEnvironment: Sendable {
    var configuration: EngineConfiguration
    var secrets: any SecretStore
    var globalLimiter: RateLimiter
    var reserveName: @Sendable (_ id: DownloadID, _ directory: URL, _ desired: String) async throws -> String
    var report: @Sendable (JobReport) async -> Void
}

/// Smooths instantaneous throughput so the displayed speed and ETA do not jitter.
struct SpeedMeter {
    private var lastBytes: Int64 = 0
    private var lastTime: ContinuousClock.Instant?
    private(set) var bytesPerSecond: Double = 0

    mutating func reset() {
        lastTime = nil
        lastBytes = 0
        bytesPerSecond = 0
    }

    mutating func sample(bytes: Int64, at now: ContinuousClock.Instant = .now) {
        guard let lastTime else {
            self.lastTime = now
            lastBytes = bytes
            return
        }
        let parts = (now - lastTime).components
        let elapsed = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        guard elapsed >= 0.1 else { return }
        let instantaneous = Double(max(0, bytes - lastBytes)) / elapsed
        bytesPerSecond = bytesPerSecond == 0 ? instantaneous : 0.7 * bytesPerSecond + 0.3 * instantaneous
        self.lastTime = now
        lastBytes = bytes
    }
}

/// One download from probe to finished file. All mutable state lives here; the transfer itself runs
/// in non-isolated tasks and is only sampled.
actor DownloadJob {
    nonisolated let id: DownloadID

    private var record: DownloadRecord
    private let env: JobEnvironment
    private let ownLimiter: RateLimiter
    private var runTask: Task<Void, Never>?
    private var downloader: (any Downloader)?
    private var meter = SpeedMeter()
    /// Set when a server that advertised ranges then ignored them; the job falls back to one connection.
    private var serverIgnoresRanges = false

    init(record: DownloadRecord, env: JobEnvironment) {
        id = record.id
        self.record = record
        self.env = env
        ownLimiter = RateLimiter(bytesPerSecond: record.options.speedLimit)
    }

    // MARK: Control

    var state: DownloadState { record.state }

    /// Starts the transfer. Returns `false` when the job is no longer queued (paused or removed while the
    /// manager was deciding), so the manager can give the slot back.
    func start() -> Bool {
        guard runTask == nil, record.state == .queued else { return false }
        record.failure = nil
        runTask = Task { await self.run() }
        return true
    }

    /// Stops the transfer (if any) and leaves the job in `newState`, with progress checkpointed.
    func stop(to newState: DownloadState) async {
        if let runTask {
            runTask.cancel()
            await runTask.value
            self.runTask = nil
        }
        guard !record.state.isFinished else { return }
        downloader = nil
        record.state = newState
        await publish(persist: true)
    }

    /// Moves a paused or failed job back into the queue.
    func requeue() async {
        guard runTask == nil, record.state == .paused || record.state == .failed else { return }
        record.state = .queued
        record.failure = nil
        await publish(persist: true)
    }

    func setSpeedLimit(_ bytesPerSecond: Int64?) async {
        record.options.speedLimit = bytesPerSecond
        ownLimiter.setRate(bytesPerSecond)
        await publish(persist: true)
    }

    /// Deletes what this job left on disk. Only completed downloads keep their file unless asked.
    func removeArtifacts(deleteFinalFile: Bool) {
        guard let name = record.filename else { return }
        let manager = FileManager.default
        if record.state == .completed {
            if deleteFinalFile, let url = try? DestinationResolver.childURL(in: record.destinationDirectory, named: name) {
                try? manager.removeItem(at: url)
            }
        } else if let part = try? DestinationResolver.childURL(in: record.destinationDirectory, named: name + ".part") {
            try? manager.removeItem(at: part)
        }
    }

    func currentRecord() -> DownloadRecord { record }

    func snapshot() -> DownloadSnapshot {
        let running = record.state == .downloading
        let received = downloader?.receivedBytes ?? record.downloadedBytes
        let speed = running ? meter.bytesPerSecond : 0
        var eta: TimeInterval?
        if running, speed > 1, let total = record.totalBytes, total > received {
            eta = Double(total - received) / speed
        }
        return DownloadSnapshot(
            id: record.id,
            url: record.url,
            filename: record.filename,
            destinationDirectory: record.destinationDirectory,
            state: record.state,
            mode: record.mode,
            totalBytes: record.totalBytes,
            receivedBytes: record.state == .completed ? (record.totalBytes ?? record.receivedBytes) : received,
            bytesPerSecond: speed,
            eta: eta,
            activeConnections: running ? (downloader?.activeConnections ?? 0) : 0,
            segments: downloader?.segmentSnapshots() ?? record.segments.map { SegmentSnapshot($0, isActive: false) },
            failure: record.failure,
            createdAt: record.createdAt,
            completedAt: record.completedAt,
            speedLimit: record.options.speedLimit,
            checksumVerified: record.checksumVerified,
            finalURL: record.state == .completed ? record.finalURL : nil
        )
    }

    // MARK: Run

    private func run() async {
        do {
            try await execute()
        } catch {
            // A cancellation means stop() is in charge of the resulting state.
            guard let failure = DownloadError.map(error) as? DownloadError else { return }
            record.state = .failed
            record.failure = failure.errorDescription ?? "\(failure)"
            downloader = nil
            runTask = nil // before publishing, so an immediate retry is accepted
            await publish(persist: true)
        }
    }

    private func execute() async throws {
        var restartsLeft = 2
        while true {
            do {
                try await attempt()
                return
            } catch DownloadError.resourceChanged where restartsLeft > 0 {
                restartsLeft -= 1
                try discardProgress()
            } catch DownloadError.rangeNotHonored where !serverIgnoresRanges {
                serverIgnoresRanges = true
                try discardProgress()
            }
        }
    }

    private func attempt() async throws {
        try await transition(to: .probing)

        let sensitive = await env.secrets.secrets(for: id) ?? SensitiveOptions()
        try RequestContext.validate(url: record.url, options: record.options, sensitive: sensitive)
        let context = RequestContext(
            url: record.url,
            options: record.options,
            sensitive: sensitive,
            defaultUserAgent: env.configuration.defaultUserAgent,
            timeout: env.configuration.requestTimeout
        )
        let probe = try await Prober(context: context).probe()
        try Task.checkCancellation()

        // Partial data only stays valid if it still describes the same resource.
        if record.mode != nil {
            let sameResource = record.totalBytes == probe.contentLength
                && Validators(etag: record.etag, lastModified: record.lastModified)
                    .matches(etag: probe.etag, lastModified: probe.lastModified)
            if !sameResource { try discardProgress() }
        }
        record.etag = probe.etag
        record.lastModified = probe.lastModified
        record.totalBytes = probe.contentLength

        if record.filename == nil {
            let desired = record.requestedFilename.map { FilenameSanitizer.sanitize($0) } ?? probe.suggestedFilename
            record.filename = try await env.reserveName(id, record.destinationDirectory, desired)
        }
        guard let name = record.filename else { throw DownloadError.unsafeDestination("no file name") }
        let directory = try DestinationResolver.prepareDirectory(record.destinationDirectory)
        let partURL = try DestinationResolver.childURL(in: directory, named: name + ".part")

        let mode: TransferMode = probe.acceptsRanges && (probe.contentLength ?? 0) > 0 && !serverIgnoresRanges
            ? .segmented : .single
        if let previous = record.mode, previous != mode { try discardProgress() }
        record.mode = mode
        if mode == .segmented, !record.segments.isEmpty {
            // Progress is only trusted when the saved segments tile the file and the .part file still has
            // exactly the expected size. A corrupt job file, or a .part file that was deleted, truncated
            // or replaced while the app was closed, would otherwise resume into a corrupt "completed" file.
            let intact = SegmentPlanner.isValidPlan(record.segments, totalSize: probe.contentLength ?? 0)
                && (record.downloadedBytes == 0 || DestinationResolver.fileSize(of: partURL) == probe.contentLength)
            if !intact { try discardProgress() }
        }

        if let total = probe.contentLength, let available = DestinationResolver.availableSpace(at: directory) {
            let needed = total - record.downloadedBytes
            if needed > available { throw DownloadError.insufficientDiskSpace(needed: needed, available: available) }
        }

        let (file, active) = try makeDownloader(mode: mode, partURL: partURL, probe: probe, context: context)
        try await transfer(with: active)

        // The .part file is preallocated to full size, so its length proves nothing: count what arrived.
        if mode == .segmented, let total = probe.contentLength, active.receivedBytes != total {
            throw DownloadError.shortRead
        }
        if let expected = record.options.checksum {
            try await transition(to: .verifying)
            let actual = try await ChecksumVerifier.digest(of: partURL, algorithm: expected.algorithm)
            guard actual == expected.hex else {
                try discardProgress()
                throw DownloadError.checksumMismatch(expected: expected.hex, actual: actual)
            }
            record.checksumVerified = true
        }
        try await finalize(file: file, partURL: partURL, directory: directory, name: name)
    }

    /// Opens the `.part` file and builds the strategy for `mode`. A segmented download with no saved
    /// progress also gets its segments planned here.
    private func makeDownloader(
        mode: TransferMode, partURL: URL, probe: ProbeResult, context: RequestContext
    ) throws -> (file: PartFile, downloader: any Downloader) {
        var retry = env.configuration.retryPolicy
        if let retries = record.options.maxRetries { retry.maxAttempts = retries }
        let transferContext = TransferContext(
            request: context,
            validators: probe.validators,
            limiter: CompositeLimiter([ownLimiter, env.globalLimiter]),
            retry: retry,
            totalBytes: probe.contentLength
        )
        let slots = record.options.segmentCount ?? env.configuration.defaultSegmentCount

        switch mode {
        case .segmented:
            let total = probe.contentLength ?? 0
            let file = try PartFile(url: partURL, size: total)
            if record.segments.isEmpty {
                record.segments = SegmentPlanner.plan(totalSize: total, requested: slots, minSegmentSize: env.configuration.minSegmentSize)
            }
            let scheduler = SegmentScheduler(segments: record.segments, minSplitSize: env.configuration.minSegmentSize)
            return (file, SegmentedDownloader(scheduler: scheduler, file: file, context: transferContext, slots: slots))
        case .single:
            let file = try PartFile(url: partURL, size: nil)
            return (file, SingleDownloader(target: StreamTarget(file: file), context: transferContext))
        }
    }

    private func transfer(with active: any Downloader) async throws {
        downloader = active
        meter.reset()
        try await transition(to: .downloading)

        let ticker = Task { await self.tickLoop() }
        defer { ticker.cancel() }
        do {
            try await active.run()
        } catch {
            await active.flush()
            active.checkpoint(into: &record)
            throw error
        }
        await active.flush()
        active.checkpoint(into: &record)
        try Task.checkCancellation()
    }

    private func tickLoop() async {
        var lastCheckpoint = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: env.configuration.progressInterval)
            guard !Task.isCancelled, let downloader else { return }
            meter.sample(bytes: downloader.receivedBytes)
            let now = ContinuousClock.now
            let due = now - lastCheckpoint >= env.configuration.checkpointInterval
            if due {
                lastCheckpoint = now
                // Counts first, then flush: the checkpoint may lag the disk but must never lead it.
                var checkpoint = record
                downloader.checkpoint(into: &checkpoint)
                await downloader.flush()
                guard !Task.isCancelled, self.downloader != nil else { return }
                record.segments = checkpoint.segments
                record.receivedBytes = checkpoint.receivedBytes
            }
            await publish(persist: due)
        }
    }

    private func finalize(file: PartFile, partURL: URL, directory: URL, name: String) async throws {
        try file.sync()
        let finalName = try DestinationResolver.moveIntoPlace(partURL, directory: directory, name: name)
        let finalURL = try DestinationResolver.childURL(in: directory, named: finalName)
        if env.configuration.applyQuarantine {
            DestinationResolver.applyQuarantine(to: finalURL, origin: record.url, agent: "Downloader")
        }
        let size = DestinationResolver.fileSize(of: finalURL)
        record.filename = finalName
        record.totalBytes = size ?? record.totalBytes
        record.receivedBytes = size ?? record.receivedBytes
        record.segments = []
        record.completedAt = Date()
        record.failure = nil
        downloader = nil
        record.state = .completed
        runTask = nil
        await publish(persist: true)
    }

    /// Forgets partial data: after a change on the server, a mode switch, or a failed checksum.
    private func discardProgress() throws {
        if let name = record.filename,
           let part = try? DestinationResolver.childURL(in: record.destinationDirectory, named: name + ".part") {
            try? FileManager.default.removeItem(at: part)
        }
        record.segments = []
        record.receivedBytes = 0
        record.checksumVerified = nil
        downloader = nil
    }

    private func transition(to state: DownloadState) async throws {
        try Task.checkCancellation()
        record.state = state
        await publish(persist: true)
    }

    private func publish(persist: Bool) async {
        await env.report(JobReport(snapshot: snapshot(), record: persist ? record : nil))
    }
}
