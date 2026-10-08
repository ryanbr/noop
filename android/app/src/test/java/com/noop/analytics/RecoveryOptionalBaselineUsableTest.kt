package com.noop.analytics

import org.junit.Assert.*
import org.junit.Test

/** Swift twin: RecoveryOptionalBaselineUsableTests. */
class RecoveryOptionalBaselineUsableTest {
    private fun optionalBaselineFixture(mean: Double, spread: Double,
        status: BaselineStatus = BaselineStatus.TRUSTED) = BaselineState(
        baseline = mean, spread = spread,
        nValid = if (status == BaselineStatus.CALIBRATING) 0 else if (status == BaselineStatus.PROVISIONAL) 6 else 14,
        nightsSinceUpdate = if (status == BaselineStatus.STALE) 20 else 0, status = status,
    )

    private val hrv = optionalBaselineFixture(50.0, 8.0)
    private val rhr = optionalBaselineFixture(60.0, 4.0)
    private val statuses = listOf(BaselineStatus.CALIBRATING, BaselineStatus.PROVISIONAL,
        BaselineStatus.TRUSTED, BaselineStatus.STALE)
    private val respiratoryValues = listOf(null, 10.0, 14.0, 18.0, 22.0)
    private val effortValues = listOf(null, 0.0, 30.0, 60.0, 100.0)

    private fun optionalChargeFixture(respBase: BaselineState?, effortBase: BaselineState? = null,
        resp: Double? = 14.0, effort: Double? = 60.0) = RecoveryScorer.recovery(
        hrv = 55.0, rhr = 58.0, resp = resp,
        hrvBaseline = hrv, rhrBaseline = rhr, respBaseline = respBase,
        sleepPerf = 0.85, skinTempDev = 0.2, recoveryIndexSlope = -0.5,
        effortBaseline = effortBase, priorDayEffort = effort,
    )

    @Test fun unusableRespirationScoresExactlyLikeAbsent() {
        val states = listOf(Baselines.foldHistory(emptyList(), Baselines.respCfg),
            Baselines.foldHistory(listOf(0.0, 100.0), Baselines.respCfg),
            optionalBaselineFixture(16.0, 2.0, BaselineStatus.STALE))
        for (base in states) {
            assertFalse(base.usable)
            for (value in respiratoryValues) {
                assertEquals(optionalChargeFixture(null, resp = value)?.toRawBits(),
                    optionalChargeFixture(base, resp = value)?.toRawBits())
            }
        }
    }

    @Test fun unusableEffortScoresExactlyLikeAbsent() {
        val states = listOf(Baselines.foldHistory(emptyList(), Baselines.strainCfg),
            Baselines.foldHistory(listOf(-1.0, 101.0), Baselines.strainCfg),
            optionalBaselineFixture(45.0, 10.0, BaselineStatus.STALE))
        for (base in states) {
            assertFalse(base.usable)
            for (value in effortValues) {
                assertEquals(optionalChargeFixture(null, effort = value)?.toRawBits(),
                    optionalChargeFixture(null, base, effort = value)?.toRawBits())
            }
        }
    }

    @Test fun allOptionalStateAndValuePairsMatchEligibleDriverContract() {
        val respStates = listOf(null) + statuses.map { optionalBaselineFixture(16.0, 2.0, it) }
        val effortStates = listOf(null) + statuses.map { optionalBaselineFixture(45.0, 10.0, it) }
        var cases = 0
        for (respBase in respStates) for (effortBase in effortStates) {
            for (resp in respiratoryValues) for (effort in effortValues) {
                val expected = RecoveryScorer.recovery(
                    hrv = 55.0, rhr = 58.0, resp = resp,
                    hrvBaseline = RecoveryScorer.DriverBaseline(hrv),
                    rhrBaseline = RecoveryScorer.DriverBaseline(rhr),
                    respBaseline = respBase?.takeIf { it.usable }?.let { RecoveryScorer.DriverBaseline(it) },
                    sleepPerf = 0.85, skinTempDev = 0.2, recoveryIndexSlope = -0.5,
                    effortBaseline = effortBase?.takeIf { it.usable }?.let { RecoveryScorer.DriverBaseline(it) },
                    priorDayEffort = effort,
                )
                assertEquals(expected?.toRawBits(), optionalChargeFixture(respBase, effortBase, resp, effort)?.toRawBits())
                cases++
            }
        }
        assertEquals(625, cases)
        assertNotEquals(optionalChargeFixture(null)?.toRawBits(),
            optionalChargeFixture(optionalBaselineFixture(16.0, 2.0))?.toRawBits())
        assertNotEquals(optionalChargeFixture(null)?.toRawBits(),
            optionalChargeFixture(null, optionalBaselineFixture(45.0, 10.0))?.toRawBits())
    }

    @Test fun respirationRowsUseExactlyTheEligibleBaseline() {
        for (status in statuses) {
            val base = optionalBaselineFixture(16.0, 2.0, status)
            for (value in respiratoryValues) {
                val actual = RecoveryDrivers.chargeDrivers(hrv = 55.0, rhr = 58.0, resp = value,
                    hrvBaseline = hrv, rhrBaseline = rhr, respBaseline = base,
                    sleepPerf = 0.85, skinTempDev = 0.2)
                val expected = RecoveryDrivers.chargeDrivers(hrv = 55.0, rhr = 58.0, resp = value,
                    hrvBaseline = hrv, rhrBaseline = rhr, respBaseline = base.takeIf { it.usable },
                    sleepPerf = 0.85, skinTempDev = 0.2)
                assertEquals(expected, actual)
                assertEquals(base.usable && value != null,
                    actual.any { it.label == ChargeDriverLabel.RESPIRATORY_RATE })
                assertTrue(actual.any { it.label == ChargeDriverLabel.HEART_RATE_VARIABILITY })
            }
        }
    }

    @Test fun respirationTraceUsesExactlyTheScoredTerms() {
        for (status in statuses) {
            val base = optionalBaselineFixture(16.0, 2.0, status)
            for (value in respiratoryValues) {
                val actual = RecoveryScorerTrace.recoveryTrace(hrv = 55.0, rhr = 58.0, resp = value,
                    hrvBaseline = hrv, rhrBaseline = rhr, respBaseline = base,
                    sleepPerf = 0.85, skinTempDev = 0.2)
                val expected = RecoveryScorerTrace.recoveryTrace(hrv = 55.0, rhr = 58.0, resp = value,
                    hrvBaseline = hrv, rhrBaseline = rhr, respBaseline = base.takeIf { it.usable },
                    sleepPerf = 0.85, skinTempDev = 0.2)
                assertEquals(expected.first?.toRawBits(), actual.first?.toRawBits())
                assertEquals(expected.second, actual.second)
                assertEquals(base.usable && value != null, actual.second.any { it.startsWith("charge term resp ") })
                assertEquals(base.usable, actual.second.any { it.startsWith("charge baseline resp ") })
                assertEquals(!base.usable || value == null,
                    actual.second.any { it.startsWith("charge nilTerm dropped=") && it.contains("resp") })
            }
        }
    }

    @Test fun dominantHrvColdStartStillRefusesEveryOptionalState() {
        for (status in listOf(BaselineStatus.CALIBRATING, BaselineStatus.STALE)) {
            val coldHrv = optionalBaselineFixture(50.0, 8.0, status)
            for (optionalStatus in statuses) {
                val base = optionalBaselineFixture(16.0, 2.0, optionalStatus)
                assertNull(RecoveryScorer.recovery(hrv = 55.0, rhr = 58.0, resp = 14.0,
                    hrvBaseline = coldHrv, rhrBaseline = rhr, respBaseline = base, sleepPerf = 0.85,
                    effortBaseline = optionalBaselineFixture(45.0, 10.0, optionalStatus), priorDayEffort = 60.0))
                assertTrue(RecoveryDrivers.chargeDrivers(hrv = 55.0, rhr = 58.0, resp = 14.0,
                    hrvBaseline = coldHrv, rhrBaseline = rhr, respBaseline = base, sleepPerf = 0.85).isEmpty())
                val trace = RecoveryScorerTrace.recoveryTrace(hrv = 55.0, rhr = 58.0, resp = 14.0,
                    hrvBaseline = coldHrv, rhrBaseline = rhr, respBaseline = base, sleepPerf = 0.85)
                assertNull(trace.first)
                assertEquals(1, trace.second.size)
                assertTrue(trace.second.firstOrNull()?.contains("hrvBaselineNotUsable") == true)
            }
        }
    }
}
