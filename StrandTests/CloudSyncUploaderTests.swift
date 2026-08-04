// Tests the CLOUD_SYNC-gated cloud sync uploader (Phase 3.5: zero-touch); compiled only when the flag
// is set (StrandTests shares the app's OuraConfig.xcconfig, so flag + creds arrive together).
#if CLOUD_SYNC
import XCTest
import WhoopStore
@testable import Strand

/// A spy conforming to `CloudIngesting` that records how many times `ingest` was invoked — used by
/// the empty-store guard test to assert the network is never reached, without needing a real
/// `CloudSyncClient`/`OuraURLProtocolStub` at all (mirrors `StubCloudEditFetcher` in
/// `CloudSyncCoordinatorTests.swift`).
private final class SpyCloudIngester: CloudIngesting {
    private(set) var ingestCallCount = 0
    func ingest(fileURL: URL) async throws -> (bytes: Int, latestDay: String?) {
        ingestCallCount += 1
        return (0, nil)
    }
}

final class CloudSyncUploaderTests: XCTestCase {
    override func setUp() { super.setUp(); OuraURLProtocolStub.reset() }

    private let baseURL = URL(string: "https://cloud.example.com")!

    private func makeClient() -> CloudSyncClient {
        CloudSyncClient(baseURL: baseURL, token: "tok-upload", session: OuraURLProtocolStub.session())
    }

    /// A fake exporter that writes canned bytes to `dest` without touching the real on-disk database or
    /// `StorePaths.defaultDatabasePath()` — see `CloudSyncUploader.Exporter`'s doc comment for why the
    /// real `DataBackup.writeBackup` can't run against a `WhoopStore.inMemory()` test store. `capture`
    /// lets a test observe exactly which temp URL the uploader chose (to assert on its location and
    /// that it's gone afterward).
    private func fakeExporter(bytes: Data = Data("fake-noopbak-bytes".utf8),
                               capture: @escaping (URL) -> Void = { _ in }) -> CloudSyncUploader.Exporter {
        { _, dest in
            capture(dest)
            try? bytes.write(to: dest)
            return .exported(dest)
        }
    }

    /// An in-memory store seeded with one `dailyMetric` row, so it clears the empty-store guard added
    /// to `CloudSyncUploader.upload` (see the "Empty store guard" section below, which tests that guard
    /// directly against an UNSEEDED store) and these pre-existing tests keep exercising what they
    /// actually test — network/export behavior beyond that guard — instead of being short-circuited by it.
    private func nonEmptyStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([
            DailyMetric(day: "2026-07-11", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                        strain: nil, exerciseCount: nil),
        ], deviceId: "devA")
        return store
    }

    // MARK: - Happy path

    func testUploadHappyPathSendsBearerAndOctetStreamAndParsesResponse() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200,
            body: #"{"ok":true,"bytes":12345,"latestDay":"2026-07-11"}"#.data(using: .utf8)!)]
        let store = try await nonEmptyStore()
        let client = makeClient()
        var capturedDest: URL?

        let result = try await CloudSyncUploader.upload(store: store, client: client,
                                                          exporter: fakeExporter(capture: { capturedDest = $0 }))

        XCTAssertEqual(result.bytes, 12345)
        XCTAssertEqual(result.latestDay, "2026-07-11")

        let req = try XCTUnwrap(OuraURLProtocolStub.requestedRequests.last)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok-upload")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertTrue(req.url?.absoluteString.contains("/ingest") ?? false)

        // The temp file lived in Caches (never Documents) and was cleaned up afterward.
        let dest = try XCTUnwrap(capturedDest)
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        XCTAssertTrue(dest.path.hasPrefix(cachesDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: - Network failure

    func testUploadNon2xxThrowsBadResponse() async throws {
        OuraURLProtocolStub.queue = [.init(status: 401, body: "nope".data(using: .utf8)!)]
        let store = try await nonEmptyStore()
        let client = makeClient()

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: client, exporter: fakeExporter())
            XCTFail("expected badResponse to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncError, CloudSyncError.badResponse(401, "nope"))
        }
    }

    func testUploadCleansUpTempFileEvenOnNetworkFailure() async throws {
        OuraURLProtocolStub.queue = [.init(status: 500, body: Data())]
        let store = try await nonEmptyStore()
        let client = makeClient()
        var capturedDest: URL?

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: client,
                                                     exporter: fakeExporter(capture: { capturedDest = $0 }))
            XCTFail("expected badResponse to be thrown")
        } catch {
            // expected — asserted below via the cleaned-up temp file
        }
        let dest = try XCTUnwrap(capturedDest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    // MARK: - Export failure (never reaches the network)

    func testUploadExportFailurePropagatesAsTypedErrorAndNeverPosts() async throws {
        let store = try await nonEmptyStore()
        let client = makeClient()
        let failingExporter: CloudSyncUploader.Exporter = { _, _ in .failure("disk full") }

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: client, exporter: failingExporter)
            XCTFail("expected exportFailed to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncUploadError, CloudSyncUploadError.exportFailed("disk full"))
        }
        XCTAssertTrue(OuraURLProtocolStub.requestedRequests.isEmpty)   // never reached the network
    }

    // MARK: - Empty store guard (incident: a test-host's empty DB must never upload)

    /// Reproduces the production incident: an empty store (a fresh `WhoopStore.inMemory()` has zero
    /// `dailyMetric` rows, same shape as the macOS TEST HOST's never-populated database) must be
    /// refused BEFORE export, BEFORE the network — proven here with no real `CloudSyncClient` at all,
    /// just a `SpyCloudIngester` that would record a call if `upload` ever reached it.
    func testUploadRefusesEmptyStoreAndNeverExportsOrIngests() async throws {
        let store = try await WhoopStore.inMemory()
        let ingester = SpyCloudIngester()
        var exporterCallCount = 0
        let countingExporter: CloudSyncUploader.Exporter = { _, dest in
            exporterCallCount += 1
            return .exported(dest)
        }

        do {
            _ = try await CloudSyncUploader.upload(store: store, client: ingester, exporter: countingExporter)
            XCTFail("expected emptyStore to be thrown")
        } catch {
            XCTAssertEqual(error as? CloudSyncUploadError, CloudSyncUploadError.emptyStore)
        }
        XCTAssertEqual(exporterCallCount, 0, "the export step must never run for an empty store")
        XCTAssertEqual(ingester.ingestCallCount, 0, "ingest must never be called for an empty store")
    }

    /// The mirror-image case: once the store has at least one `dailyMetric` row, upload proceeds
    /// exactly as before (happy-path regression guard for the new empty-store check).
    func testUploadProceedsWhenStoreHasData() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200,
            body: #"{"ok":true,"bytes":99,"latestDay":"2026-07-11"}"#.data(using: .utf8)!)]
        let store = try await nonEmptyStore()
        let client = makeClient()

        let result = try await CloudSyncUploader.upload(store: store, client: client, exporter: fakeExporter())
        XCTAssertEqual(result.bytes, 99)
    }
}

/// The 20h auto-sync gate, extracted as a pure `(lastRun, now) -> Bool` function so the threshold is
/// unit-testable without UserDefaults, a store, or a network. Mirrors `BackupSyncTests`' coverage of
/// `FolderBackup`'s pure day-gate helpers.
final class CloudSyncModelAutoSyncGateTests: XCTestCase {
    func testIsAutoSyncDueNeverRunBefore() {
        XCTAssertTrue(CloudSyncModel.isAutoSyncDue(lastRun: 0, now: 1_752_300_000))
    }

    func testIsAutoSyncDueRespectsTwentyHourThreshold() {
        let now: TimeInterval = 1_752_300_000
        XCTAssertFalse(CloudSyncModel.isAutoSyncDue(lastRun: now - 19 * 3600, now: now))  // too soon
        XCTAssertTrue(CloudSyncModel.isAutoSyncDue(lastRun: now - 20 * 3600, now: now))   // exactly due (>=)
        XCTAssertTrue(CloudSyncModel.isAutoSyncDue(lastRun: now - 21 * 3600, now: now))   // overdue
    }

    /// Incident guard: `autoSyncIfDue` must never fire inside an XCTest runner (the macOS TEST HOST
    /// runs `StrandTests` inside the full `Staging.app` via `TEST_HOST`, so `RootView`'s launch `.task`
    /// executes for real — see `CloudSyncModel.isRunningUnderXCTest`'s doc comment). This is
    /// inherently env-dependent and can only be pinned from the TRUE side: every `StrandTests` run,
    /// including this one, IS an XCTest run, so the helper reading true here is exactly what "detects
    /// the test runner" means. There is no way to assert the false branch from inside XCTest itself.
    func testIsRunningUnderXCTestIsTrueInThisTestRunner() {
        XCTAssertTrue(CloudSyncModel.isRunningUnderXCTest)
    }
}

/// The push-telemetry hook on the upload path. This is the instrument for the page-replication
/// trial, so the properties that matter are the ones that keep the *measurement* honest: a record
/// per delivered sync, none for a sync that delivered nothing, and a WAL size that was sampled at a
/// moment when it means something.
final class CloudSyncUploaderTelemetryTests: XCTestCase {
    override func setUp() { super.setUp(); OuraURLProtocolStub.reset() }

    private func makeClient() -> CloudSyncClient {
        CloudSyncClient(baseURL: URL(string: "https://cloud.example.com")!, token: "tok",
                        session: OuraURLProtocolStub.session())
    }

    private func makeTelemetry() -> SyncPushTelemetry {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("push-telemetry-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return SyncPushTelemetry(url: url)
    }

    private func nonEmptyStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([
            DailyMetric(day: "2026-07-11", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                        lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                        strain: nil, exerciseCount: nil),
        ], deviceId: "devA")
        return store
    }

    private func fakeExporter() -> CloudSyncUploader.Exporter {
        { _, dest in try? Data("bytes".utf8).write(to: dest); return .exported(dest) }
    }

    /// One record per successful upload, carrying the server's own byte count. `snapshotted` is true
    /// with reason `full-ingest` because `/ingest` genuinely ships the whole database — this is the
    /// baseline the replicator is measured against, and labelling it as anything else would make the
    /// eventual comparison meaningless.
    func testRecordsOneSnapshotObservationPerSuccessfulUpload() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200,
            body: #"{"ok":true,"bytes":153400000,"latestDay":"2026-07-11"}"#.data(using: .utf8)!)]
        let telemetry = makeTelemetry()

        _ = try await CloudSyncUploader.upload(store: try await nonEmptyStore(), client: makeClient(),
                                               exporter: fakeExporter(), telemetry: telemetry)

        let stats = telemetry.stats
        XCTAssertEqual(stats.pushes, 1)
        XCTAssertEqual(stats.snapshots, 1)
        XCTAssertEqual(stats.bytesUploaded, 153_400_000)
        XCTAssertEqual(stats.snapshotRate, 1.0, accuracy: 0.0001,
                       "today every /ingest IS a full snapshot; the baseline must say so")
        XCTAssertEqual(stats.reasonCounts["full-ingest"], 1)
    }

    /// A failed POST delivered no bytes. Counting it would understate cost-per-delivered-sync and
    /// would make the trial's byte comparison against the replicator wrong in the replicator's favour.
    func testDoesNotRecordWhenTheUploadFails() async throws {
        OuraURLProtocolStub.queue = [.init(status: 507, body: Data())]
        let telemetry = makeTelemetry()

        do {
            _ = try await CloudSyncUploader.upload(store: try await nonEmptyStore(), client: makeClient(),
                                                   exporter: fakeExporter(), telemetry: telemetry)
            XCTFail("a 507 must propagate")
        } catch {}

        XCTAssertEqual(telemetry.stats.pushes, 0)
    }

    /// The empty-store guard refuses before export or network. Nothing was pushed, so nothing is
    /// recorded — otherwise a device that never syncs would still accumulate a push history.
    func testDoesNotRecordWhenTheEmptyStoreGuardRefuses() async throws {
        let telemetry = makeTelemetry()

        do {
            _ = try await CloudSyncUploader.upload(store: try await WhoopStore.inMemory(),
                                                   client: makeClient(),
                                                   exporter: fakeExporter(), telemetry: telemetry)
            XCTFail("an empty store must be refused")
        } catch {}

        XCTAssertEqual(telemetry.stats.pushes, 0)
    }

    /// Repeated uploads accumulate, and the gap between them is derived rather than passed in — the
    /// push cadence is half the trial's answer (a snapshot every launch is fine at 1/day and fatal at
    /// 8/day), and a caller that had to remember to supply it would eventually not.
    func testAccumulatesAcrossPushesAndDerivesTheInterval() async throws {
        OuraURLProtocolStub.queue = [
            .init(status: 200, body: #"{"ok":true,"bytes":10,"latestDay":"2026-07-11"}"#.data(using: .utf8)!),
            .init(status: 200, body: #"{"ok":true,"bytes":20,"latestDay":"2026-07-12"}"#.data(using: .utf8)!),
        ]
        let telemetry = makeTelemetry()
        let store = try await nonEmptyStore()

        _ = try await CloudSyncUploader.upload(store: store, client: makeClient(),
                                               exporter: fakeExporter(), telemetry: telemetry)
        _ = try await CloudSyncUploader.upload(store: store, client: makeClient(),
                                               exporter: fakeExporter(), telemetry: telemetry)

        XCTAssertEqual(telemetry.stats.pushes, 2)
        XCTAssertEqual(telemetry.stats.bytesUploaded, 30)
        XCTAssertNil(telemetry.recentRecords.first?.secondsSinceLastPush)
        XCTAssertNotNil(telemetry.recentRecords.last?.secondsSinceLastPush,
                        "the second push must carry a measured interval")
    }

    /// Telemetry is an instrument, not a dependency. A caller that passes none still uploads.
    func testUploadSucceedsWithNoTelemetry() async throws {
        OuraURLProtocolStub.queue = [.init(status: 200,
            body: #"{"ok":true,"bytes":7,"latestDay":"2026-07-11"}"#.data(using: .utf8)!)]

        let result = try await CloudSyncUploader.upload(store: try await nonEmptyStore(),
                                                        client: makeClient(),
                                                        exporter: fakeExporter(), telemetry: nil)

        XCTAssertEqual(result.bytes, 7)
    }
}

// MARK: - Liters fallback policy (pure)

/// The 2026-08-03 fix: `uploaded == 0` is four states with opposite correct responses, and the
/// escalation to `/ingest` is a counted decision, not a reflex. These tests pin the classifier and
/// the escalation policy — pure functions over scalars, no replicator, no network, no LITERS
/// xcframework required.
final class LitersFallbackPolicyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CloudSyncUploader.resetLitersRetryStreak()
    }

    override func tearDown() {
        CloudSyncUploader.resetLitersRetryStreak()
        super.tearDown()
    }

    // MARK: classification

    func testShippedBytesClassifyAsPushed() {
        XCTAssertEqual(
            CloudSyncUploader.classifyLitersPush(uploaded: 1, synced: true,
                                                 txid: 5, remoteTxid: 5, bytesUploaded: 65_789),
            .pushed(bytes: 65_789))
    }

    /// The healthy no-op: lineage has content and the remote matches it exactly. The old code
    /// answered this with a ~208 MB `/ingest` that then reset the lineage (observed 2026-08-03).
    func testVerifiedInSyncIsSuccessNotFallback() {
        XCTAssertEqual(
            CloudSyncUploader.classifyLitersPush(uploaded: 0, synced: true,
                                                 txid: 27, remoteTxid: 27, bytesUploaded: 0),
            .inSync)
    }

    /// The vacuous case observed 2026-08-03 17:16, minutes after a server-side lineage reset:
    /// `synced=true` at `txid=0` means both sides agree on NOTHING — no content is verifiably on
    /// the server, so this must NOT be blessed as success (that would stamp `lastUploadToken` and
    /// make the next sync skip the upload entirely). It must not trigger `/ingest` either — the
    /// next liters push re-baselines.
    func testVacuousSyncAtTxidZeroIsRetryable() {
        let outcome = CloudSyncUploader.classifyLitersPush(uploaded: 0, synced: true,
                                                           txid: 0, remoteTxid: 0, bytesUploaded: 0)
        guard case .retryable = outcome else {
            return XCTFail("txid=0 vacuous sync must be retryable, got \(outcome)")
        }
    }

    func testCapturedButUnshippedIsRetryable() {
        let outcome = CloudSyncUploader.classifyLitersPush(uploaded: 0, synced: false,
                                                           txid: 9, remoteTxid: 8, bytesUploaded: 0)
        guard case .retryable = outcome else {
            return XCTFail("captured-but-unshipped must be retryable, got \(outcome)")
        }
    }

    func testSyncedButRemoteBehindIsRetryable() {
        // synced flag claiming true while remoteTxid lags txid is contradictory — never trust it
        // as delivered.
        let outcome = CloudSyncUploader.classifyLitersPush(uploaded: 0, synced: true,
                                                           txid: 9, remoteTxid: 7, bytesUploaded: 0)
        guard case .retryable = outcome else {
            return XCTFail("remote behind local must be retryable, got \(outcome)")
        }
    }

    // MARK: escalation

    /// Two retryable syncs throw-and-retry; the third runs `/ingest` anyway. Below-threshold
    /// withholding protects the lineage from transient failures; the threshold itself keeps a
    /// genuinely dead liters path flowing through the proven upload.
    func testEscalationOpensAtThreshold() {
        XCTAssertFalse(CloudSyncUploader.ingestEscalationAllowed(retryStreak: 1))
        XCTAssertFalse(CloudSyncUploader.ingestEscalationAllowed(retryStreak: 2))
        XCTAssertTrue(CloudSyncUploader.ingestEscalationAllowed(retryStreak: 3))
        XCTAssertTrue(CloudSyncUploader.ingestEscalationAllowed(retryStreak: 4),
                      "past-threshold streaks keep /ingest open — the streak only resets on a "
                      + "liters success, so a dead liters path ships every sync, not every third")
    }

    func testStreakPersistsAndResets() {
        XCTAssertEqual(CloudSyncUploader.litersRetryStreak(), 0)
        XCTAssertEqual(CloudSyncUploader.bumpLitersRetryStreak(), 1)
        XCTAssertEqual(CloudSyncUploader.bumpLitersRetryStreak(), 2)
        XCTAssertEqual(CloudSyncUploader.litersRetryStreak(), 2,
                       "streak reads back from UserDefaults — it must survive a process relaunch, "
                       + "because background syncs are usually fresh processes")
        CloudSyncUploader.resetLitersRetryStreak()
        XCTAssertEqual(CloudSyncUploader.litersRetryStreak(), 0)
    }

    func testRetryPendingErrorNamesTheAttemptAndTheReason() {
        let error = CloudSyncUploadError.litersRetryPending(streak: 2, reason: "push threw: 503")
        let text = error.errorDescription ?? ""
        XCTAssertTrue(text.contains("attempt 2"), "user-facing text must carry the attempt count")
        XCTAssertTrue(text.contains("retry"), "must say it will retry, not read as a dead end")
    }
}
#endif // CLOUD_SYNC
