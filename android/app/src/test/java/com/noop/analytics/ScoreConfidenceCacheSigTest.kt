package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * #1005 (backfill storm): the analyzeRecent per-day cache signature folds the HRV baseline's CONFIDENCE
 * TIER (`ScoreConfidence.forCharge`), NOT baselines1's raw value, so a value-only drift during a history
 * backfill no longer drops the whole cache each offload chunk. `chargeConfidence` is the only cached,
 * non-pass-2-recomputed field that depends on baselines1, and it reads ONLY the HRV baseline's
 * usable/nValid/trusted STATUS. This pins the property the fix relies on: the charge tier is invariant to
 * the baseline's VALUE (baseline/spread) and changes only on a genuine STATUS/tier transition. If a future
 * edit makes forCharge depend on the baseline value, this fails — flagging that the cache sig would churn
 * again. Twin of the Swift ScoreConfidenceCacheSigTests.
 */
class ScoreConfidenceCacheSigTest {
    private fun hrv(baseline: Double, spread: Double, nValid: Int, status: BaselineStatus) =
        BaselineState(baseline, spread, nValid, 0, status)

    @Test
    fun forCharge_tierInvariantToBaselineValueDrift() {
        // Same status (trusted), different value — exactly how a rolling baseline moves as a backfill folds
        // in nights. The tier (and thus the cache signature contribution) must NOT change.
        val a = hrv(baseline = 45.0, spread = 6.0, nValid = 30, status = BaselineStatus.TRUSTED)
        val b = hrv(baseline = 52.0, spread = 9.0, nValid = 41, status = BaselineStatus.TRUSTED)
        assertEquals(ScoreConfidence.SOLID, ScoreConfidence.forCharge(1.0, a))
        assertEquals(
            "a value-only baseline drift must not change the charge tier (it would drop the #1005 cache)",
            ScoreConfidence.forCharge(1.0, a), ScoreConfidence.forCharge(1.0, b),
        )
    }

    @Test
    fun forCharge_tierChangesOnStatusTransition() {
        // A real status transition MUST change the tier, so the cache correctly drops and chargeConfidence
        // is re-derived. (usable=false → CALIBRATING; usable & !trusted → BUILDING; trusted → SOLID.)
        val trusted = hrv(45.0, 6.0, 30, BaselineStatus.TRUSTED)
        val provisional = hrv(45.0, 6.0, 6, BaselineStatus.PROVISIONAL)
        val calibrating = hrv(45.0, 6.0, 2, BaselineStatus.CALIBRATING)
        assertEquals(ScoreConfidence.SOLID, ScoreConfidence.forCharge(1.0, trusted))
        assertEquals(ScoreConfidence.BUILDING, ScoreConfidence.forCharge(1.0, provisional))
        assertEquals(ScoreConfidence.CALIBRATING, ScoreConfidence.forCharge(1.0, calibrating))
        assertNotEquals(ScoreConfidence.forCharge(1.0, trusted), ScoreConfidence.forCharge(1.0, provisional))
    }
}
