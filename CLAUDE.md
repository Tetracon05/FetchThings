# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

A native macOS download manager (Free Download Manager–style): multi-connection downloads, SwiftUI app, no browser integration. Decisions made: macOS 15 minimum, direct notarized distribution, App Sandbox off, custom URL scheme `downloader://` (must open a prefilled Add sheet, never start a download silently). Out of scope, but the engine should stay open to them: browser integration, torrents, yt-dlp.

**Current state:** only the engine exists, as the local Swift package `DownloadKit/`. The Xcode app target (SwiftUI main window, menu bar extra, settings) is Phase 2 and has not been started. The planned generator for the `.xcodeproj` is XcodeGen (not installed; needs the user's OK to `brew install`). Phases: (1) engine + tests, (2) main UI, (3) menu bar, scheduling, speed-limit UI, polish. After each phase: build, run tests, then `/code-review` and `/simplify`; run `/security-review` before finishing; report honestly what was and wasn't tested.

## Commands

All engine work happens in `DownloadKit/` (Swift 6 language mode, Xcode 27 / Swift 6.4; `Mutex` needs macOS 15). No linter or formatter is configured.

```bash
cd DownloadKit
swift build --build-tests          # library + tests; the library builds with zero warnings, keep it so
swift test                         # whole suite, ~14 s
swift test --filter DownloadIntegrationTests                 # one suite
swift test --filter resumesFromTheByteWhereAConnectionDropped # one test (matches the function name)
swift test --skip-build --filter <name>                      # re-run without rebuilding
```

Tests use Swift Testing (`@Test`, `#expect`), not XCTest.

## Engine architecture (`DownloadKit/Sources/DownloadKit`)

Data flow: `DownloadManager` (actor: queue, concurrency cap, global limiter, persistence, event stream) owns one `DownloadJob` (actor) per download. A job runs probe → transfer → verify → finalize and reports `JobReport`s back through a closure. The transfer itself runs in non-isolated tasks and is only *sampled* by the job's tick loop (about 4 Hz), never driven per chunk.

- **One connection is the 1-segment case.** `TransferMode.segmented` (server gave a size and honors ranges) uses `SegmentedDownloader` + `SegmentScheduler`; `.single` uses `SingleDownloader` (plain GET, not resumable, restarts from zero). A server that advertises ranges but answers 200 makes the job throw `rangeNotHonored` and fall back to `.single`; a changed ETag/size makes it throw `resourceChanged` and restart (max 2 times).
- **`SegmentTransfer` = one request, one `URLSession`.** A session per transfer is deliberate: over HTTP/2/3, requests sharing a session are multiplexed onto one TCP connection, which would silently defeat multi-connection. Chunks are `pwrite`n from the delegate queue straight into the shared `PartFile` (no actor hop). Speed limiting suspends the `URLSessionDataTask`; URLSession and the kernel buffer roughly the first MB ahead of that, so limits are accurate on large transfers but small files finish faster than the nominal rate.
- **`SegmentScheduler` invariant (the core of resume correctness):** per segment, `received` (committed, on disk, the only value persisted) trails `reserved` (a write cursor). Workers `reserve → pwrite → commit`. Work stealing (an idle slot splits the segment with the most unreserved bytes left) only takes bytes beyond `reserved`, so no byte is written twice. Resume points always come from `received`. `SegmentedDownloader` counts an attempt against the retry budget only if the segment made no progress.
- **Probe (`Prober`):** HEAD first; range support is only believed after `Accept-Ranges: bytes`, otherwise a `Range: bytes=0-0` GET settles it (HEAD is often rejected, and many servers honor ranges without saying so). Requests send `Accept-Encoding: identity`; any `Content-Encoding` disables ranges and drops the size.
- **Manager ordering rules** (`DownloadManager.handle`): update the snapshot, broadcast, and hand the record to the store *before the first suspension*, so a job's reports keep their order. `runningIDs` is mutated synchronously before `await job.start()` so concurrent `scheduleNext()` passes can't exceed the concurrency limit; `start()` returns `false` if the job is no longer queued and the manager then gives the slot back. The manager's snapshot can lag the job, so `pause()` never trusts it: it calls `job.stop(to: .paused)`, which handles running, starting and queued jobs. After `shutdown()` nothing may start (`isShutDown`), otherwise a job stopped back to `.queued` is immediately restarted.
- **Job persistence:** one JSON file per download (`FileJobStore`, dir 0700, files 0600), checkpointed every `checkpointInterval` and on every state change. On `load()`, records left in a running state go back to `.queued` (auto-resume). Removing an unfinished download always deletes its `.part` file.
- **Never trust saved progress blindly.** The `.part` file is preallocated to full size, so its length says nothing about what is in it. A resume only keeps progress if `SegmentPlanner.isValidPlan` accepts the saved segments (a bad list would otherwise trap in `SegmentScheduler.init`) and the part file's size equals the total; otherwise it restarts. Completion is checked by counting received bytes, not file size. Checkpoints snapshot the counts *before* `fsync`ing the part file (`Downloader.flush`), so a checkpoint may lag the disk but never lead it. A `.single` download has nothing to resume (`downloadedBytes` is 0 until completed).
- **Errors:** `DownloadError.isRetryable` decides retry vs fail (408/425/429/5xx except 501/505, and transient `URLError`s retry; other 4xx, disk, checksum, path errors don't). `DownloadError.map` turns `URLError.cancelled` into `CancellationError`, which means "stopped by caller", never "failed".

## Security invariants (keep these when changing code)

- **Secrets never touch the job store.** Cookies, custom headers and Basic-auth credentials live in `SensitiveOptions` behind the `SecretStore` protocol (in-memory in the package; the app is expected to supply a Keychain-backed one). `DownloadRecord` has no field for them. `DownloadManager.add` also moves `user:pass@` out of the URL into `basicAuth` before anything is persisted.
- **Redirects:** URLSession drops `Authorization` on *every* redirect, even same-origin. `RedirectPolicy.sanitize` restores the configured headers when the target origin equals the URL the user named, and strips every non-portable header (credentials, cookies, custom tokens) for any other origin. It also refuses non-http(s) targets. Both the prober and `SegmentTransfer` must go through it.
- **File names:** `FilenameSanitizer.sanitize` (last path component only, strips control/bidi chars, no leading dots, NFC, ≤200 bytes) → `NameAllocator` (avoids existing files, `.part` files and in-flight downloads) → `DestinationResolver.childURL` (re-verifies the result is a direct child of the download folder, also for names read back from a possibly tampered job file) → `PartFile` opens with `O_NOFOLLOW` → finishing uses `renamex_np(RENAME_EXCL)` so an existing file is never overwritten. Only `http`/`https` URLs are accepted (`RequestContext.validate` also rejects header injection and reserved headers).
- Finished files get the quarantine attribute (`applyQuarantine`, credentials stripped from the recorded origin). macOS doesn't expose the recorded data URL back through resource values, so that part is tested on the pure `quarantineProperties` function.

## Testing notes

- `MockHTTPServer` (test target) is a real HTTP/1.1 server on loopback (`NWListener`), so tests exercise the actual URLSession stack. `MockResource` models server behavior (Range, HEAD, ETag/If-Range, throttling, connection drops); handler closures inject faults. Content is deterministic per offset (`MockContent`), so any range can be verified by SHA-256.
- Its `maxConcurrentConnections` counter lags slightly behind the client, so it is fine for "at least N in parallel" checks but not for upper bounds. Assert concurrency caps by replaying `manager.events()` (see `neverRunsMoreDownloadsThanTheLimit`).
- Speed-limit tests must use files well beyond ~1 MB (buffered head start), or they finish instantly.
- `#expect(int64Optional == 8 * 1024 * 1024 - 1)` silently evaluates false: the macro types the arithmetic as `Int`. Bind a typed `Int64` constant first.
- Timing-based tests (limits, work stealing, pause/resume byte bounds) have been stress-run under CPU load; if you add one, do the same (`yes > /dev/null` ×8 in the background) before trusting it. Mutation-check new security/resume tests by breaking the code they guard and confirming they fail.
