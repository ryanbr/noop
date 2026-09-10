import XCTest
@testable import Strand

/// #1995: a hero ring taps through to its metric dossier, so the ring and the Key-Metrics tile for the
/// same score reach the identical screen.
///
/// Charge is the exception and it is deliberate: a ring opens the richest explanation its shell has, so
/// Charge keeps its breakdown sheet on the classic Today and on Android and only takes a route on the
/// Liquid Today, which has no breakdown. Its key is still pinned here because the Liquid hero and both
/// shells' tiles resolve it.
///
/// `TabRoute.metric(key)` resolves through `MetricCatalog.all` and, when a key does not match, falls back
/// to the Health screen rather than failing. That fallback is the reason these assertions exist: rename a
/// catalog key and the ring would keep working, keep animating, and quietly land on the wrong screen. No
/// crash, no log, nothing to notice. Pinning the three keys here turns that into a build failure.
///
/// The Liquid Key-Metrics tiles below the rings resolve their own destination through the same catalog
/// on the same three keys, so this guards the pair from drifting apart. They read the constants rather
/// than their own copies, which is what makes that true rather than merely intended: a private list here
/// would have kept passing while either shell was renamed out from under it.
final class HeroRingDetailRouteTests: XCTestCase {

    /// Charge, Effort and Rest, in the order the hero row renders them.
    ///
    /// Read from the production constants rather than restated here. A private copy would have kept
    /// passing while a shell was renamed out from under it, which is the one failure this file exists to
    /// catch; the literals below pin that the constants themselves still say what the catalog expects.
    private let heroKeys = HeroRingMetric.all

    /// The constants' VALUES, pinned separately from their resolution. Reading the production list is
    /// what ties the test to the shells; this is what stops the list itself drifting silently, and it is
    /// where the Apple/Android divergence is recorded: Rest routes on `sleep_performance` here and on
    /// `rest` there, because the two platforms' detail screens resolve different key spaces.
    func testHeroRingKeysAreTheExpectedThree() {
        XCTAssertEqual(HeroRingMetric.charge, "recovery")
        XCTAssertEqual(HeroRingMetric.effort, "strain")
        XCTAssertEqual(HeroRingMetric.rest, "sleep_performance")
        XCTAssertEqual(HeroRingMetric.all, ["recovery", "strain", "sleep_performance"])
    }

    func testEveryHeroRingKeyResolvesToACatalogMetric() {
        for key in heroKeys {
            XCTAssertNotNil(MetricCatalog.all.first(where: { $0.key == key }),
                            "hero ring key '\(key)' is not in MetricCatalog, so its ring would silently "
                             + "fall back to the Health screen instead of the metric")
        }
    }

    /// Each key must name exactly one metric: two entries and the ring's destination depends on ordering.
    func testEveryHeroRingKeyIsUnambiguous() {
        for key in heroKeys {
            XCTAssertEqual(MetricCatalog.all.filter { $0.key == key }.count, 1,
                           "hero ring key '\(key)' must match exactly one catalog entry")
        }
    }
}
