import XCTest
@testable import Strand

/// #1995: the three hero rings tap through to their metric dossier, so the ring and the Key-Metrics tile
/// for the same score reach the identical screen.
///
/// `TabRoute.metric(key)` resolves through `MetricCatalog.all` and, when a key does not match, falls back
/// to the Health screen rather than failing. That fallback is the reason these assertions exist: rename a
/// catalog key and the ring would keep working, keep animating, and quietly land on the wrong screen. No
/// crash, no log, nothing to notice. Pinning the three keys here turns that into a build failure.
///
/// The Key-Metrics tiles below the rings pass these same three keys, so this also guards the pair from
/// drifting apart.
final class HeroRingDetailRouteTests: XCTestCase {

    /// Charge, Effort and Rest, in the order the hero row renders them.
    private let heroKeys = ["recovery", "strain", "sleep_performance"]

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
