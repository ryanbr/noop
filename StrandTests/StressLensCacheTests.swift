import XCTest
@testable import Strand
@testable import StrandAnalytics

/// The personal daytime-stress lens is resolved once per local day, not once per surface.
///
/// The drain (#2535, reported on Android and fixed on both): with the lens on, Today showed 09:30 at 22:20
/// while Stress detail showed the current curve fifteen seconds after opening. Both are the same latency.
/// The resolver folds the thirty days BEFORE today, and every surface paid that fold independently, while the
/// card holds its previous curve during a pass, so the morning's curve stayed on screen looking current.
///
/// The span ends YESTERDAY, which is what makes the memo sound: today's heart rate arrives all day and cannot
/// move the key.
///
/// Twin of Kotlin `StressLensCacheTest`.
@MainActor
final class StressLensCacheTests: XCTestCase {

    override func setUp() async throws {
        StressLensCache.shared.clear()
    }

    func testAWarmKeyIsReusedWithoutFolding() async {
        var folds = 0
        let fold: () async -> DaytimeStress.ScoringMode = { folds += 1; return .dayRelative }

        _ = await StressLensCache.shared.resolve("same", fold: fold)
        XCTAssertEqual(folds, 1, "the first resolve must fold")

        _ = await StressLensCache.shared.resolve("same", fold: fold)
        XCTAssertEqual(folds, 1, "an unchanged key must not fold again")
    }

    /// Two callers arriving together fold ONCE.
    ///
    /// On this platform that is not just an optimisation: a MainActor method that awaits is REENTRANT, so the
    /// second caller genuinely does arrive mid-fold, which is the reported sequence (Today's pass running when
    /// detail is opened). Sharing the task is what makes it await the first answer instead of starting a fold.
    func testConcurrentCallersFoldOnceAndTheWaiterReuses() async {
        var folds = 0
        let fold: () async -> DaytimeStress.ScoringMode = {
            folds += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .dayRelative
        }
        async let first = StressLensCache.shared.resolve("same", fold: fold)
        async let second = StressLensCache.shared.resolve("same", fold: fold)
        _ = await (first, second)
        XCTAssertEqual(folds, 1, "the waiter must reuse the in-flight fold rather than start its own")
    }

    func testADifferentKeyStillFolds() async {
        var folds = 0
        let fold: () async -> DaytimeStress.ScoringMode = { folds += 1; return .dayRelative }
        _ = await StressLensCache.shared.resolve("a", fold: fold)
        _ = await StressLensCache.shared.resolve("b", fold: fold)
        XCTAssertEqual(folds, 2, "a moved fingerprint or a new day must re-fold")
    }

    func testClearForcesTheNextResolveToFoldAgain() async {
        var folds = 0
        let fold: () async -> DaytimeStress.ScoringMode = { folds += 1; return .dayRelative }
        _ = await StressLensCache.shared.resolve("same", fold: fold)
        StressLensCache.shared.clear()
        _ = await StressLensCache.shared.resolve("same", fold: fold)
        XCTAssertEqual(folds, 2)
    }

    /// The resolved value is handed back unchanged, not merely cached.
    func testTheResolvedModeIsReturnedToEveryCaller() async {
        let expected = DaytimeStress.ScoringMode.dayRelative
        let a = await StressLensCache.shared.resolve("same") { expected }
        let b = await StressLensCache.shared.resolve("same") { .dayRelative }
        XCTAssertEqual(a, expected)
        XCTAssertEqual(b, expected)
    }
}
