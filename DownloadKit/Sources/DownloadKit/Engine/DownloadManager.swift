import Foundation

/// The download queue. Owns every job, enforces the concurrency limit and the global speed limit,
/// persists state, and publishes changes.
public actor DownloadManager {
    private var configuration: EngineConfiguration
    private let store: any JobStore
    private let secrets: any SecretStore
    private let globalLimiter = RateLimiter()

    private var jobs: [DownloadID: DownloadJob] = [:]
    private var snapshots: [DownloadID: DownloadSnapshot] = [:]
    private var sequences: [DownloadID: Int] = [:]
    /// Jobs handed a slot and not yet back in a resting state. Counted synchronously so concurrent
    /// scheduling passes cannot overshoot the limit.
    private var runningIDs: Set<DownloadID> = []
    private var names = NameAllocator()
    /// What each download reserved, so it is released under the same key even if the finished file ended up
    /// with a different name.
    private var reservations: [DownloadID: (directory: URL, name: String)] = [:]
    private var nextSequence = 0
    private var subscribers: [UUID: AsyncStream<DownloadEvent>.Continuation] = [:]
    private var activity: NSObjectProtocol?
    private var isShutDown = false

    public init(configuration: EngineConfiguration = .init(), store: any JobStore, secrets: any SecretStore) {
        self.configuration = configuration
        self.store = store
        self.secrets = secrets
    }

    // MARK: Lifecycle

    /// Restores persisted downloads. Jobs that were running when the app last quit go back in the queue
    /// (if `autoResumeOnLoad`); paused, failed and completed ones keep their state.
    public func load() async throws {
        let records = try await store.loadAll()
        for var record in records where jobs[record.id] == nil {
            if record.state.isRunning { record.state = configuration.autoResumeOnLoad ? .queued : .paused }
            nextSequence = max(nextSequence, record.sequence + 1)
            if let name = record.filename, record.state != .completed {
                names.adopt(directory: record.destinationDirectory, name: name)
                reservations[record.id] = (record.destinationDirectory, name)
            }
            let job = DownloadJob(record: record, env: makeEnvironment())
            jobs[record.id] = job
            sequences[record.id] = record.sequence
            snapshots[record.id] = await job.snapshot()
            broadcast(.snapshot(snapshots[record.id]!))
        }
        await scheduleNext()
    }

    /// Stops everything, keeping progress. Running jobs resume on the next launch. The manager starts
    /// nothing afterwards: without that, a job stopped back into the queue would be picked up again as
    /// soon as its slot freed.
    public func shutdown() async {
        isShutDown = true
        for id in Array(runningIDs) {
            await jobs[id]?.stop(to: .queued)
        }
        runningIDs.removeAll()
        updateActivity()
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
        // Subscribers hear about a change before the store has written it, so wait for those writes:
        // otherwise a download that finished a moment ago is on disk as "running" and starts over.
        await store.flush()
    }

    // MARK: Adding and removing

    @discardableResult
    public func add(_ request: NewDownload) async throws -> DownloadID {
        // `https://user:pass@host/...`: move the credentials out of the URL, which gets persisted.
        let (url, embedded) = request.url.splittingCredentials()
        var sensitive = request.sensitive
        if sensitive.basicAuth == nil { sensitive.basicAuth = embedded }
        try RequestContext.validate(url: url, options: request.options, sensitive: sensitive)
        let directory = try DestinationResolver.prepareDirectory(request.destinationDirectory)

        var record = DownloadRecord(
            url: url,
            destinationDirectory: directory,
            requestedFilename: request.filename,
            options: request.options,
            state: request.startPaused ? .paused : .queued,
            sequence: nextSequence
        )
        nextSequence += 1
        if !sensitive.isEmpty {
            try await secrets.setSecrets(sensitive, for: record.id)
            record.hasSecrets = true
        }
        try await store.save(record)

        let job = DownloadJob(record: record, env: makeEnvironment())
        jobs[record.id] = job
        sequences[record.id] = record.sequence
        let snapshot = await job.snapshot()
        snapshots[record.id] = snapshot
        broadcast(.snapshot(snapshot))
        await scheduleNext()
        return record.id
    }

    /// Removes a download. Unfinished downloads always lose their `.part` file; a finished file is
    /// only deleted when `deleteFiles` is set.
    public func remove(_ id: DownloadID, deleteFiles: Bool = false) async {
        guard let job = jobs[id] else { return }
        await job.stop(to: .paused)
        jobs[id] = nil
        snapshots[id] = nil
        sequences[id] = nil
        runningIDs.remove(id)
        releaseReservation(id)
        await job.removeArtifacts(deleteFinalFile: deleteFiles)
        try? await store.delete(id: id)
        await secrets.removeSecrets(for: id)
        broadcast(.removed(id))
        await scheduleNext()
    }

    // MARK: Control

    public func pause(_ id: DownloadID) async {
        // The snapshot can lag the job (a job just started still reads `.queued` here), so let the job
        // decide: `stop(to:)` handles running, starting and queued jobs alike.
        guard let job = jobs[id], let state = snapshots[id]?.state, state.isRunning || state == .queued else { return }
        await job.stop(to: .paused)
    }

    /// Resumes a paused download, or retries a failed one.
    public func resume(_ id: DownloadID) async {
        await jobs[id]?.requeue()
        await scheduleNext()
    }

    public func pauseAll() async {
        for id in snapshots.keys.sorted(by: { (sequences[$0] ?? 0) < (sequences[$1] ?? 0) }) {
            await pause(id)
        }
    }

    public func resumeAll() async {
        for (id, snapshot) in snapshots where snapshot.state == .paused {
            await jobs[id]?.requeue()
        }
        await scheduleNext()
    }

    public func setMaxConcurrentDownloads(_ count: Int) async {
        configuration.maxConcurrentDownloads = max(1, count)
        await scheduleNext()
    }

    /// Bytes per second across all downloads; `nil` removes the limit.
    public func setGlobalSpeedLimit(_ bytesPerSecond: Int64?) {
        globalLimiter.setRate(bytesPerSecond)
    }

    public func setSpeedLimit(_ bytesPerSecond: Int64?, for id: DownloadID) async {
        await jobs[id]?.setSpeedLimit(bytesPerSecond)
    }

    // MARK: Observing

    public func snapshot(_ id: DownloadID) -> DownloadSnapshot? { snapshots[id] }

    public func allSnapshots() -> [DownloadSnapshot] {
        snapshots.values.sorted { (sequences[$0.id] ?? 0) < (sequences[$1.id] ?? 0) }
    }

    /// A stream of changes. It starts with the current state of every download, then follows updates
    /// (progress about four times a second, state changes immediately).
    public func events() -> AsyncStream<DownloadEvent> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<DownloadEvent>.makeStream(bufferingPolicy: .unbounded)
        for snapshot in allSnapshots() { continuation.yield(.snapshot(snapshot)) }
        subscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(token) }
        }
        return stream
    }

    private func removeSubscriber(_ token: UUID) {
        subscribers[token] = nil
    }

    private func broadcast(_ event: DownloadEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    // MARK: Scheduling

    private func makeEnvironment() -> JobEnvironment {
        JobEnvironment(
            configuration: configuration,
            secrets: secrets,
            globalLimiter: globalLimiter,
            reserveName: { [weak self] id, directory, desired in
                guard let self else { throw CancellationError() }
                return try await self.reserveName(for: id, directory: directory, desired: desired)
            },
            report: { [weak self] report in await self?.handle(report) }
        )
    }

    private func reserveName(for id: DownloadID, directory: URL, desired: String) throws -> String {
        let name = try names.reserve(directory: directory, desired: desired)
        reservations[id] = (directory, name)
        return name
    }

    private func releaseReservation(_ id: DownloadID) {
        guard let held = reservations.removeValue(forKey: id) else { return }
        names.release(directory: held.directory, name: held.name)
    }

    /// Reports arrive in the order a job produced them. Everything that must stay ordered (updating the
    /// snapshot, publishing, and handing the record to the store) happens before the first suspension.
    private func handle(_ report: JobReport) async {
        let snapshot = report.snapshot
        guard jobs[snapshot.id] != nil else { return }
        snapshots[snapshot.id] = snapshot
        broadcast(.snapshot(snapshot))

        // Progress reports arrive constantly; only a change in who is running matters below.
        let runningChanged = snapshot.state.isRunning
            ? runningIDs.insert(snapshot.id).inserted
            : runningIDs.remove(snapshot.id) != nil
        if snapshot.state == .completed { releaseReservation(snapshot.id) }
        if runningChanged { updateActivity() }

        if let record = report.record { try? await store.save(record) }
        if runningChanged, !snapshot.state.isRunning { await scheduleNext() }
    }

    private func scheduleNext() async {
        while !isShutDown, runningIDs.count < configuration.maxConcurrentDownloads {
            let candidate = snapshots.values
                .filter { $0.state == .queued && !runningIDs.contains($0.id) }
                .min { (sequences[$0.id] ?? 0) < (sequences[$1.id] ?? 0) }
            guard let candidate, let job = jobs[candidate.id] else { break }
            runningIDs.insert(candidate.id)
            if await !job.start() {
                runningIDs.remove(candidate.id)
                let fresh = await job.snapshot()
                snapshots[candidate.id] = fresh
                broadcast(.snapshot(fresh))
            }
        }
        updateActivity()
    }

    /// Keeps macOS from napping the app (and optionally from sleeping) while downloads run.
    private func updateActivity() {
        if runningIDs.isEmpty {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        } else if activity == nil {
            let options: ProcessInfo.ActivityOptions = configuration.keepSystemAwake
                ? .userInitiated : .userInitiatedAllowingIdleSystemSleep
            activity = ProcessInfo.processInfo.beginActivity(options: options, reason: "Downloading files")
        }
    }
}
