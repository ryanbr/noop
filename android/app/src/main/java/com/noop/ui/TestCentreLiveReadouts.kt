package com.noop.ui

import com.noop.analytics.BatteryEstimator
import com.noop.analytics.ConnectionReadout
import com.noop.analytics.DisplayReadout
import com.noop.analytics.ImportReadout
import com.noop.analytics.SleepReadout
import com.noop.analytics.StepsReadout
import com.noop.analytics.TestReadout
import com.noop.analytics.WorkoutsReadout
import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.testcentre.TestDomain
import com.noop.testcentre.TestMode
import java.util.Locale
import kotlin.math.roundToInt

/** Inputs shared by the Test Centre row and its report: the exported tagged log, plus the small set of
 * live values that are not log-derived. Repository-backed samples are loaded only while their row is on. */
internal data class TestCentreLiveSnapshot(
    /** #1468 follow-up: the log as LINES. Every consumer here filters by domain tag, so the joined
     *  string this replaced was built only to be split again. */
    val logLines: List<String> = emptyList(),
    val nowUnix: Long = System.currentTimeMillis() / 1_000,
    val connected: Boolean = false,
    val batteryPct: Double? = null,
    val batteryEstimate: BatteryEstimator.Estimate? = null,
    val hrSamples: List<HrSample> = emptyList(),
    val gravitySamples: List<GravitySample> = emptyList(),
)

internal data class LiveReadoutRow(val id: String, val label: String, val value: String)

/** Observable inputs an active row subscribes to. Null/false means no collector or clock exists. */
internal data class LiveReadoutRefreshSources(
    val observeLogRevision: Boolean = false,
    val observeSleepSampleRevision: Boolean = false,
    val observeBatteryRevision: Boolean = false,
    val connectionClockEveryMs: Long? = null,
)

internal object TestCentreLiveRefreshPolicy {
    fun sources(mode: TestMode, active: Boolean): LiveReadoutRefreshSources {
        if (!active) return LiveReadoutRefreshSources()
        return LiveReadoutRefreshSources(
            observeLogRevision = mode.liveReadout.isNotEmpty(),
            observeSleepSampleRevision = mode.domain == TestDomain.SLEEP,
            observeBatteryRevision = mode.domain == TestDomain.BATTERY,
            connectionClockEveryMs = 1_000L.takeIf { mode.domain == TestDomain.CONNECTION },
        )
    }
}

/** Exhaustive presentation mapping for every declarative [TestMode.liveReadout] id. Unknown active ids
 * fail loudly instead of silently disappearing; inactive modes return before parsing or formatting. */
internal object TestCentreLiveReadouts {
    val mappedIds: Set<String> = setOf(
        "hrDensityNow", "gravityCoverageNow", "lastNightGateFired",
        "connectionUptime", "reconnectCount", "lastOffloadResult",
        "lastSessionSummary", "deviceMetricsNow", "lastImportSummary",
        "stepsToday", "calibrationState",
        "currentSoc", "estimateDaysLeft", "slopeSource",
        "lastChargeBreakdown", "lastHrvComputation",
    )

    fun rows(mode: TestMode, active: Boolean, snapshot: TestCentreLiveSnapshot): List<LiveReadoutRow> {
        if (!active) return emptyList()
        val tail by lazy { taggedTail(snapshot.logLines, mode.id) }
        return mode.liveReadout.map { id ->
            require(id in mappedIds) { "Unmapped Test Centre liveReadout id: $id" }
            when (id) {
                "hrDensityNow" -> LiveReadoutRow(
                    id, "HR density (per min)",
                    if (snapshot.hrSamples.isEmpty()) "no live HR yet"
                    else String.format(Locale.US, "%.1f", SleepReadout.hrDensityPerMinute(snapshot.hrSamples)),
                )
                "gravityCoverageNow" -> LiveReadoutRow(
                    id, "Gravity coverage",
                    if (snapshot.gravitySamples.isEmpty()) "no live gravity yet"
                    else String.format(
                        Locale.US, "%.0f%%",
                        SleepReadout.gravityCoverageFraction(snapshot.gravitySamples, snapshot.hrSamples) * 100,
                    ),
                )
                "lastNightGateFired" -> LiveReadoutRow(
                    id, "Last gate fired", SleepReadout.lastGateFired(tail) ?: "no night yet",
                )
                "connectionUptime" -> LiveReadoutRow(
                    id, "Connection uptime",
                    if (snapshot.connected) ConnectionReadout.uptimeLabel(tail, snapshot.nowUnix)
                    else "not connected",
                )
                "reconnectCount" -> LiveReadoutRow(
                    id, "Reconnects this run", ConnectionReadout.reconnectCount(tail).toString(),
                )
                "lastOffloadResult" -> LiveReadoutRow(
                    id, "Last offload result", ConnectionReadout.lastOffloadResult(tail) ?: "no offload yet",
                )
                "lastSessionSummary" -> LiveReadoutRow(
                    id, "Last session", WorkoutsReadout.lastSessionSummary(tail) ?: "no session yet",
                )
                "deviceMetricsNow" -> LiveReadoutRow(
                    id, "Device metrics", DisplayReadout.deviceMetricsNow(tail) ?: "reading...",
                )
                "lastImportSummary" -> LiveReadoutRow(
                    id, "Last import", ImportReadout.lastImportSummary(tail) ?: "no import yet",
                )
                "stepsToday" -> LiveReadoutRow(
                    id, "Steps today", StepsReadout.stepsToday(tail)?.toString() ?: "no estimate yet",
                )
                "calibrationState" -> LiveReadoutRow(
                    id, "Calibration", StepsReadout.calibrationState(tail) ?: "no calibration yet",
                )
                "currentSoc" -> LiveReadoutRow(
                    id, "Current charge", snapshot.batteryPct?.let { "${it.roundToInt()}%" } ?: "--",
                )
                "estimateDaysLeft" -> LiveReadoutRow(
                    id, "Estimated runtime left",
                    snapshot.batteryEstimate?.let { BatteryEstimator.label(it.remainingHours) } ?: "--",
                )
                "slopeSource" -> LiveReadoutRow(
                    id, "Slope source",
                    snapshot.batteryEstimate?.source?.name?.lowercase(Locale.US) ?: "--",
                )
                "lastChargeBreakdown" -> LiveReadoutRow(
                    id, "Last Charge breakdown",
                    TestReadout.lastChargeBreakdown(tail) ?: "no night scored yet",
                )
                "lastHrvComputation" -> LiveReadoutRow(
                    id, "Last HRV reading", TestReadout.lastHrvComputation(tail) ?: "no reading yet",
                )
                else -> error("mapped id has no renderer: $id")
            }
        }
    }

    private fun taggedTail(logLines: List<String>, domainId: String): List<String> {
        return logLines.filter { line ->
            firstDomainTag.find(line)?.groupValues?.get(1) == domainId
        }
    }

    // Match only a real leading TestDomain marker: raw test lines start with it; exported production lines
    // put it immediately after their time/date stamp. Arbitrary payload text before `[recovery]` is not a
    // stamp and cannot turn an otherwise untagged line into Recovery data.
    private val firstDomainTag = Regex(
        "^(?:(?:\\d{4}-\\d{2}-\\d{2}[ T])?\\d{2}:\\d{2}:\\d{2}(?:\\.\\d+)?\\s+)?" +
            "\\[(${TestDomain.entries.joinToString("|") { Regex.escape(it.id) }})]\\s",
    )
}
