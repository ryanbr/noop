package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1995: the Effort and Rest hero rings open their own vital detail, so the ring and the metric card
 * below it can never lead to different screens.
 *
 * The keys are pinned because `VitalDetailScreen` resolves them through a `when` that ends in
 * `else -> null`. An unrecognised key does not crash and does not log: it renders an empty detail. So a
 * rename would leave the ring tappable, animating, and landing on a blank screen with nothing to notice.
 *
 * Rest is the one that bites. Its DETAIL key is "rest" while the series underneath it is
 * "sleep_performance", which is what the iOS side routes on. Using the iOS key here would compile, run,
 * and silently show nothing.
 *
 * LIMIT, stated rather than implied: [supportedDetailKeys] below is a MIRROR of the `when` in
 * VitalDetailScreen, maintained by hand. It catches a change to the hero constants, which is the likely
 * edit, but it cannot catch someone renaming a branch of that `when`. Making it real would mean driving
 * the screen's own resolution from a shared set, which is a bigger change than this one.
 */
class HeroRingMetricKeyTest {

    /** The keys `VitalDetailScreen`'s `when` accepts, as of this test. */
    private val supportedDetailKeys = setOf(
        "recovery", "strain", "resp", "spo2", "rhr", "hrv", "skin", "rest",
        "fitness_age", "vitality", "vo2max_est", "steps_est", "active_kcal",
    )

    @Test fun chargeOpensTheRecoveryDetail() {
        assertEquals("recovery", HERO_CHARGE_METRIC_KEY)
        assertTrue("the Charge trend link's key must be one VitalDetailScreen resolves",
            HERO_CHARGE_METRIC_KEY in supportedDetailKeys)
    }

    @Test fun effortRingOpensTheEffortDetail() {
        assertEquals("strain", HERO_EFFORT_METRIC_KEY)
        assertTrue("the Effort ring's key must be one VitalDetailScreen resolves",
            HERO_EFFORT_METRIC_KEY in supportedDetailKeys)
    }

    @Test fun restRingOpensTheRestDetail() {
        assertEquals("rest", HERO_REST_METRIC_KEY)
        assertTrue("the Rest ring's key must be one VitalDetailScreen resolves",
            HERO_REST_METRIC_KEY in supportedDetailKeys)
    }

    /**
     * The trap, stated as an assertion: "sleep_performance" is the SERIES key, not a detail key. Routing
     * the Rest ring there would render an empty screen.
     */
    @Test fun theRestSeriesKeyIsNotADetailKey() {
        assertTrue("sleep_performance is a metricSeries key; the detail resolves 'rest' instead",
            "sleep_performance" !in supportedDetailKeys)
    }
}
