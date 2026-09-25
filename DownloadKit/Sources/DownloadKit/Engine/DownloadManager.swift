import Foundation

/// The download queue. Owns every job, enforces the concurrency limit and the global speed limit,
/// persists state, and publishes changes.
public actor DownloadManager {
    private var configuration: EngineConfiguration
    private let store: any JobStore
    private let secrets: any SecretStore
    private let globalLimiter = RateLimiter()

    private var jobs: [DownloadID: DownloadJob] = [:]
    /// The latest snapshot of every download; its `sequence` is the order they were added in.
    private var snapshots: [DownloadID: DownloadSnapshot] = [:]
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

    private let network: (any NetworkMonitoring)?
    private var networkStatus = NetworkStatus.online
    private var networkPolicy = NetworkPolicy()
    /// The user chose to download anyway on an expensive or constrained connection; lasts until the connection changes.
    private var networkOverridden = false
    private var networkTask: Task<Void, Never>?
    private var networkSubscribers: [UUID: AsyncStream<NetworkState>.Continuation] = [:]

    /// `network` is watched once `load()` has run; without one, downloads are never held back for the connection.
    public init(configuration: EngineConfiguration = .init(), store: any JobStore, secrets: any SecretStore, network: (any NetworkMonitoring)? = nil) {
        self.configuration = configuration
        self.store = store
        self.secrets = secrets
        self.network = network
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
            snapshots[record.id] = await job.snapshot()
            broadcast(.snapshot(snapshots[record.id]!))
        }
        // Read the connection before anything starts: downloads that were running at the last quit resume the moment they
        // are queued, and starting them offline just to stop them again would be wasted, noisy work.
        if let network, networkTask == nil {
            networkStatus = await network.currentStatus()
            publishNetworkState()
            networkTask = Task { [weak self] in
                for await status in network.changes() { await self?.networkStatusChanged(status) }
            }
        }
        await scheduleNext()
    }

    /// Stops everything, keeping progress. Running jobs resume on the next launch. The manager starts
    /// nothing afterwards: without that, a job stopped back into the queue would be picked up again as
    /// soon as its slot freed.
    public func shutdown() async {
        isShutDown = true
        networkTask?.cancel()
        networkTask = nil
        for continuation in networkSubscribers.values { continuation.finish() }
        networkSubscribers.removeAll()
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
        for id in allSnapshots().map(\.id) {
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

    // MARK: Queue order

    /// The downloads that still have a place in the queue (everything not finished), in the order they will run.
    private func queue() -> [DownloadSnapshot] {
        snapshots.values.filter { $0.state != .completed }.sorted { $0.queueOrder < $1.queueOrder }
    }

    /// Changes how soon downloads run compared with others: a higher priority always starts first. Running downloads
    /// are not interrupted; the change decides which queued one gets the next free slot.
    public func setPriority(_ priority: DownloadPriority, for ids: [DownloadID]) async {
        for id in ids {
            guard let snapshot = snapshots[id], snapshot.state != .completed, snapshot.priority != priority else { continue }
            await jobs[id]?.setQueueing(priority: priority, rank: snapshot.queueRank)
        }
        await scheduleNext()
    }

    /// Puts `ids` (in the order they already have) in front of `target`, or at the end of the queue when `target` is
    /// `nil` or not in the queue. If `target` is one of `ids` they go in front of the next download that is not (so
    /// dropping a selection on one of its own rows changes nothing). They take the priority of the place they are put
    /// in: dropped among high-priority downloads they become high priority, at the end of the queue they take the
    /// priority of what is last.
    public func move(_ ids: [DownloadID], before target: DownloadID?) async {
        let wanted = Set(ids)
        let queue = queue()
        let moved = queue.filter { wanted.contains($0.id) }
        guard !moved.isEmpty else { return }
        let rest = queue.filter { !wanted.contains($0.id) }

        var anchor = target
        if let target, wanted.contains(target), let index = queue.firstIndex(where: { $0.id == target }) {
            anchor = queue[(index + 1)...].first { !wanted.contains($0.id) }?.id
        }
        let insertAt = anchor.flatMap { anchor in rest.firstIndex { $0.id == anchor } } ?? rest.count
        let priority = rest.indices.contains(insertAt) ? rest[insertAt].priority : (rest.last?.priority ?? moved[0].priority)
        let low = insertAt > 0 && rest[insertAt - 1].priority == priority ? rest[insertAt - 1].queueRank : nil
        let high = rest.indices.contains(insertAt) ? rest[insertAt].queueRank : nil

        guard let ranks = QueueRanks.spread(moved.count, between: low, and: high) else {
            await renumberQueue() // no room between the neighbours any more
            return await move(ids, before: target)
        }
        for (snapshot, rank) in zip(moved, ranks) where snapshot.priority != priority || snapshot.queueRank != rank {
            await jobs[snapshot.id]?.setQueueing(priority: priority, rank: rank)
        }
        await scheduleNext()
    }

    /// Puts `ids` first in the queue.
    public func moveToTop(_ ids: [DownloadID]) async {
        let wanted = Set(ids)
        guard let first = queue().first(where: { !wanted.contains($0.id) }) else { return }
        await move(ids, before: first.id)
    }

    /// Puts `ids` last in the queue.
    public func moveToBottom(_ ids: [DownloadID]) async {
        await move(ids, before: nil)
    }

    /// Gives every queued download a whole-number rank again, keeping the order. Needed only when so many downloads
    /// have been put between the same two that there is no number left between them.
    private func renumberQueue() async {
        for (index, snapshot) in queue().enumerated() where snapshot.queueRank != Double(index) {
            await jobs[snapshot.id]?.setQueueing(priority: snapshot.priority, rank: Double(index))
        }
    }

    // MARK: Network

    /// Which connections downloads may use. Applies at once: running downloads that the new policy forbids wait in the
    /// queue, and queued ones start if it now allows them.
    public func setNetworkPolicy(_ policy: NetworkPolicy) async {
        guard policy != networkPolicy else { return }
        networkPolicy = policy
        networkOverridden = false
        await applyNetworkGate()
    }

    /// Lets downloads use an expensive or constrained connection until the connection changes. Does nothing offline.
    public func overrideNetworkBlock() async {
        guard networkBlock != nil, networkStatus.isConnected else { return }
        networkOverridden = true
        await applyNetworkGate()
    }

    /// The connection and whether it is holding downloads back: the current state first, then each change.
    public func networkStates() -> AsyncStream<NetworkState> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<NetworkState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield(networkState)
        networkSubscribers[token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeNetworkSubscriber(token) }
        }
        return stream
    }

    private func removeNetworkSubscriber(_ token: UUID) { networkSubscribers[token] = nil }

    /// Why downloads may not start now, or `nil`. Being offline blocks whatever the user chose.
    private var networkBlock: NetworkBlock? {
        guard networkStatus.isConnected else { return .offline }
        return networkOverridden ? nil : networkPolicy.block(for: networkStatus)
    }

    private var networkState: NetworkState {
        NetworkState(status: networkStatus, block: networkBlock, isOverridden: networkOverridden && networkStatus.isConnected)
    }

    private func publishNetworkState() {
        let state = networkState
        for continuation in networkSubscribers.values { continuation.yield(state) }
    }

    private func networkStatusChanged(_ status: NetworkStatus) async {
        guard status != networkStatus, !isShutDown else { return }
        networkStatus = status
        networkOverridden = false // a different connection: the choice made for the last one does not carry over
        await applyNetworkGate()
    }

    /// Puts running downloads back in the queue when the connection forbids them (they keep their progress, and the
    /// ones the user paused stay paused), and starts queued ones when it no longer does.
    private func applyNetworkGate() async {
        publishNetworkState()
        if networkBlock != nil {
            for id in Array(runningIDs) { await jobs[id]?.stop(to: .queued) }
        } else {
            await scheduleNext()
        }
    }

    // MARK: Observing

    public func snapshot(_ id: DownloadID) -> DownloadSnapshot? { snapshots[id] }

    public func allSnapshots() -> [DownloadSnapshot] {
        snapshots.values.sorted { $0.sequence < $1.sequence }
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
        while !isShutDown, networkBlock == nil, runningIDs.count < configuration.maxConcurrentDownloads {
            let candidate = snapshots.values
                .filter { $0.state == .queued && !runningIDs.contains($0.id) }
                .min { $0.queueOrder < $1.queueOrder }
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
