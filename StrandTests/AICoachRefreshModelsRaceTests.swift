import XCTest
@testable import Strand

/// Guards the `refreshModels()` re-entrancy race (#873). The engine is `@MainActor` and the only
/// suspension point in `refreshModels()` is the live model fetch. The provider Picker in CoachView
/// is not disabled while a refresh is in flight, so the user can switch providers mid-fetch. Without
/// a snapshot guard, the resumed code would merge the OLD provider's fetched ids into a list written
/// for the NEW provider, leaving a stale/mixed picker for the wrong endpoint.
///
/// The fix snapshots the provider before the await and bails (writing nothing) if it changed on
/// resume, so the end state is exactly the NEW provider's options, never the stale ids. These tests
/// inject a fetch the test can release on demand (no network, no Keychain) to reproduce the timing.
@MainActor
final class AICoachRefreshModelsRaceTests: XCTestCase {

    /// A one-shot gate: the override parks on `wait()`, the test calls `open()` once it has switched
    /// the provider, so the fetch resumes into a world where `provider` no longer matches the snapshot.
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            if opened { return }
            await withCheckedContinuation { self.continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    /// Build an engine whose key gate is already satisfied without the Keychain: the Custom provider
    /// resolves to an empty (but non-nil) key, so `refreshModels()` reaches its await.
    private func makeEngine(deviceId: String) -> AICoachEngine {
        let engine = AICoachEngine(repo: Repository(deviceId: deviceId))
        engine.provider = .custom
        return engine
    }

    /// A switch mid-fetch must leave `availableModels` equal to the NEW provider's options ONLY, with
    /// none of the OLD provider's freshly-fetched ids leaking in.
    func testProviderSwitchMidFetchDropsStaleOldProviderIds() async {
        let engine = makeEngine(deviceId: "test-aicoach-race")
        let gate = Gate()
        let staleIds = ["stale-old-provider-model-a", "stale-old-provider-model-b"]
        let fetchReachedAwait = expectation(description: "fetch entered (await hit)")

        engine.fetchModelsOverride = { _, _ in
            fetchReachedAwait.fulfill()
            await gate.wait()
            return staleIds
        }

        // Kick off the refresh for the CUSTOM (old) provider, then wait until it is parked on the await.
        let refresh = Task { await engine.refreshModels() }
        await fulfillment(of: [fetchReachedAwait], timeout: 2)

        // User switches to a DIFFERENT provider mid-flight. Its didSet resets availableModels to the
        // new provider's built-in options.
        engine.provider = .anthropic
        XCTAssertEqual(engine.availableModels, AIProvider.anthropic.modelOptions)

        // Now let the old-provider fetch resume; its ids must be discarded by the snapshot guard.
        await gate.open()
        await refresh.value

        XCTAssertEqual(engine.availableModels, AIProvider.anthropic.modelOptions,
                       "availableModels must be the NEW provider's options only, no stale old-provider ids")
        for stale in staleIds {
            XCTAssertFalse(engine.availableModels.contains(stale),
                           "stale id \(stale) from the old provider leaked into the new provider's list")
        }
    }

    /// Sanity: with NO mid-flight switch, the fetched ids ARE merged (the guard only fires on a real
    /// switch), so the happy path is unchanged.
    func testNoSwitchStillMergesFetchedIds() async {
        let engine = makeEngine(deviceId: "test-aicoach-merge")
        let fetched = ["served-model-1", "served-model-2"]
        engine.fetchModelsOverride = { _, _ in fetched }

        await engine.refreshModels()

        // Custom has no built-in options, so the merged list is the discovered ids (plus the current
        // model if not otherwise present). The point is simply that they are NOT dropped.
        for id in fetched {
            XCTAssertTrue(engine.availableModels.contains(id),
                          "fetched id \(id) should be merged when the provider does not change")
        }
    }

    /// A custom gateway's live model list is authoritative: do not keep sending a retired alias
    /// when the server exposes the replacement model (e.g. private-local → noop-coach).
    func testCustomRefreshReplacesModelNotServedByGateway() async {
        let engine = makeEngine(deviceId: "test-aicoach-stale-custom-model")
        engine.model = "private-local"
        engine.fetchModelsOverride = { _, _ in ["noop-coach"] }

        await engine.refreshModels()

        XCTAssertEqual(engine.availableModels, ["noop-coach"])
        XCTAssertEqual(engine.model, "noop-coach")
    }
}
