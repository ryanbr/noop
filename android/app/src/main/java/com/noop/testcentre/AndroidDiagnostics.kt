package com.noop.testcentre

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager

/**
 * The Android environment-header block (spec section 3.4), bringing Android to the same shape as the iOS
 * IOSDiagnostics. macOS and Android emit almost nothing today; this carries the variables that quietly
 * break a background BLE health app: Doze / battery-optimisation exemption, OEM-kill heuristics, the
 * permission-grant state, the charging state, and the Build identity.
 *
 * TOTAL and best-effort: every probe is guarded so a header build never throws into the export. Degrades
 * gracefully, never fabricates a value it can't read.
 */
object AndroidDiagnostics {

    /** Aux rows read for one night's SpO2-candidate line (#112). Twin of the Swift
     *  `DebugDataDiagnostics.spo2CandidateAuxLimit`. */
    private const val SPO2_CANDIDATE_AUX_LIMIT = 200_000

    fun summaryLines(context: Context): List<String> = buildList {
        add("Device: ${Build.MANUFACTURER} ${Build.MODEL}")
        add("Android: ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})")
        add("Battery optimisation: ${batteryOptimisationText(context)}")
        add("OEM background kill: ${oemKillHeuristic(Build.MANUFACTURER)}")
        add("Charging: ${chargingText(context)}")
        add("Permissions: ${permissionsText(context)}")
    }

    /**
     * Strap identity + data-state lines for the debug export. Offline-safe: reads persisted prefs and the
     * canonical "my-whoop" daily spine, so it works from the scheduled background export too. Model,
     * last-known firmware, last-sync, timezone, days of history, and the most recent sleep + recovery day.
     * Best-effort: guarded so it never throws into the export.
     */
    suspend fun strapAndDataLines(context: Context): List<String> = buildList {
        add("─".repeat(40))
        add("Strap & data")
        runCatching {
            val dev = com.noop.ui.NoopPrefs.lastDevice(context)
            add("Model:       ${dev?.second?.displayName ?: "unknown (never paired)"}")
            add("Firmware:    ${com.noop.ui.NoopPrefs.lastFirmware(context) ?: "unknown (connect to record)"}")
            val syncSec = com.noop.ui.NoopPrefs.lastSyncAt(context)
            add("Last sync:   ${if (syncSec > 0L) relTime(System.currentTimeMillis() - syncSec * 1000L) else "never"}")
            // #57: write-health. "Last sync" fires even on an empty/failed offload, so distinguish "rows
            // actually landed" from "an offload STALLED on a persist failure" (history won't persist —
            // usually a backup restored without an app restart, the closed-DB class).
            val p = com.noop.ui.NoopPrefs.of(context)
            val okAt = p.getLong("sync.lastWriteOkAt", 0L)
            val stalledAt = p.getLong("sync.lastWriteStalledAt", 0L)
            val restoreAt = p.getLong("backup.lastRestoreAt", 0L)
            val now = System.currentTimeMillis()
            add("Data write:  ${if (okAt > 0L) "rows last landed ${relTime(now - okAt * 1000L)}" else "no rows ever persisted"}")
            if (stalledAt > 0L && stalledAt >= okAt) {
                add("             ⚠ history NOT persisting — last offload STALLED ${relTime(now - stalledAt * 1000L)} " +
                    "(if you restored a backup, fully restart the app — #57)")
            }
            if (restoreAt > 0L) add("Last restore: ${relTime(now - restoreAt * 1000L)}")
            add("Timezone:    ${tzLine()}")
            val repo = com.noop.data.WhoopRepository.from(context)
            val days = repo.days("my-whoop")
            add("History:     ${days.size} day rows (my-whoop spine)")
            // Last sleep/recov read the MERGED view (imported ∪ computed), not the import spine alone: a
            // strap-only user's freshest scored day lives under the "-noop" computed sibling, so reading the
            // spine showed a stale value (could be a month old) while the app displayed today's. Twin of
            // Swift DebugDataDiagnostics, which already reads the merged `repo.days`.
            val merged = repo.daysMerged("my-whoop")
            add("Last sleep:  ${merged.lastOrNull { (it.totalSleepMin ?: 0.0) > 0.0 }?.let { "${it.day} · ${it.totalSleepMin?.toInt()} min" } ?: "none"}")
            add("Last recov.: ${merged.lastOrNull { it.recovery != null }?.let { "${it.day} · ${it.recovery?.toInt()}%" } ?: "none"}")
        }.onFailure { add("(strap/data state unavailable: ${it.message})") }
    }

    /**
     * Analytics-funnel lines: recompute the REM + skin-temp funnels for the most recent night so a "0% REM"
     * / "skin temp absent" report arrives with the funnel breakdown. BEST-EFFORT and self-reporting — it
     * prints the sample counts it read and says plainly when it can't compute (e.g. a freshly re-added strap
     * whose raw samples aren't yet under the canonical id), so it never fabricates a misleading verdict.
     */
    suspend fun funnelLines(context: Context): List<String> = buildList {
        add("─".repeat(40))
        add("Analytics funnels (latest night, best-effort)")
        runCatching {
            val repo = com.noop.data.WhoopRepository.from(context)
            // #1150: resolve the ACTIVE strap id (mirrors Swift's `did = repo.deviceId`). A single-WHOOP
            // install resolves to "my-whoop" ⇒ every read below collapses to the canonical id and is
            // byte-identical to the old hardcoded path; a re-added strap reads its own "whoop-<uuid>" raws
            // and "<uuid>-noop" computed sessions (the engine writes computed under `<importedDeviceId>-noop`
            // and both analyzeRecent callers pass the active strap as importedDeviceId).
            val id = runCatching {
                (context.applicationContext as? com.noop.NoopApplication)?.deviceRegistry?.activeDeviceId()
            }.getOrNull()?.takeIf { it.isNotBlank() } ?: "my-whoop"
            val nowSec = System.currentTimeMillis() / 1000L
            // Pick the MOST RECENT night that actually carries skin-temp — not the OLDEST. The old
            // `sleepSessions(…, 1).lastOrNull()` returned the oldest session in the window (ASC order), so a
            // fresh gap night read "skin=0" and the funnel never saw a real night. Walk newest→oldest.
            var recent = repo.sleepSessionsUnion(id, nowSec - 14L * 86400L, nowSec, 200)
            if (recent.isEmpty()) {
                // #1150: a Bluetooth-only strap banks every night under the COMPUTED "-noop" source, so the
                // imported union above is empty and the funnel used to report "no session in 14 days" for a
                // 4.0 user whose nights are all computed. Fall back to the computed union so a real night is
                // analysed. Only on an empty imported read ⇒ an imported install's funnel is unchanged.
                recent = repo.computedSleepSessionsUnion(id, nowSec - 14L * 86400L, nowSec, 200)
            }
            recent = recent.sortedBy { it.startTs }   // `.last()` must be the newest across both branches
            if (recent.isEmpty()) {
                add("(no sleep session in the last 14 days to analyze)")
                return@runCatching
            }
            var session = recent.last()   // non-null (list checked non-empty), newest by ASC start order
            var skin = repo.skinTempSamples(id, session.startTs, session.endTs, Int.MAX_VALUE)
            if (skin.isEmpty()) {
                for (s in recent.asReversed()) {
                    val sk = repo.skinTempSamples(id, s.startTs, s.endTs, Int.MAX_VALUE)
                    if (sk.isNotEmpty()) { session = s; skin = sk; break }
                }
            }
            val grav = repo.gravitySamples(id, session.startTs, session.endTs, Int.MAX_VALUE)
            val hr = repo.hrSamples(id, session.startTs, session.endTs, Int.MAX_VALUE)
            val rr = repo.rrIntervals(id, session.startTs, session.endTs, Int.MAX_VALUE)
            val resp = repo.respSamples(id, session.startTs, session.endTs, Int.MAX_VALUE)
            add("Night ${dayStamp(session.startTs)}: grav=${grav.size} hr=${hr.size} rr=${rr.size} resp=${resp.size} skin=${skin.size}")
            if (grav.isEmpty() && hr.isEmpty()) {
                add("(no raw biometric samples under '$id' for this night — expected on a freshly re-added strap; reconnect + let a history sync run, then re-export)")
                return@runCatching
            }
            com.noop.analytics.SleepStager.remFunnelDiagnostic(session.startTs, session.endTs, grav, hr, rr, resp)
                ?.let { add(it.summary) } ?: add("REM funnel: insufficient motion data (<2 gravity samples)")
            val det = com.noop.analytics.DetectedSleep(
                start = session.startTs, end = session.endTs,
                efficiency = session.efficiency ?: 0.0, stages = emptyList(),
                restingHR = session.restingHr, avgHRV = session.avgHrv,
            )
            val family = if (com.noop.ui.NoopPrefs.lastDevice(context)?.second == com.noop.ble.WhoopModel.WHOOP5_MG)
                com.noop.protocol.DeviceFamily.WHOOP5 else com.noop.protocol.DeviceFamily.WHOOP4
            // Mirror the real per-device anchor (#404): learn it from the WHOLE recent window's raws — not
            // just this night — so a single sparse night (<100 in-band) can't misreport under the global
            // fallback when the window as a whole has enough in-band samples for analyzeDay to learn one.
            val windowSkin = repo.skinTempSamples(id, nowSec - 14L * 86400L, nowSec, Int.MAX_VALUE)
            val devAnchor = if (family == com.noop.protocol.DeviceFamily.WHOOP4)
                com.noop.protocol.Whoop4SkinTemp.deviceAnchorRaw(windowSkin.map { it.raw }) else null
            add(com.noop.analytics.AnalyticsEngine.skinTempFunnel(listOf(det), hr, skin, family, devAnchor).summary)

            // #112/#103 — the 5/MG SpO2 CANDIDATE (@82), as one number a wearer can check against the
            // figure the WHOOP app reports for the same night. The candidate cannot be promoted while two
            // straps disagree about it, and until now the only way to read it was to scroll the Deep
            // Timeline and eyeball it, which is not an instrument to hand a volunteer. Diagnostic only:
            // nothing scores this and it is NOT a blood-oxygen reading. Absent on a WHOOP 4.0, which
            // carries raw red/IR ADC and no candidate — said explicitly so a 4.0 owner is not left
            // wondering. Twin of the Swift `DebugDataDiagnostics` line.
            // Same explicit limit as the Swift twin's `spo2CandidateAuxLimit`, rather than Int.MAX_VALUE,
            // so the two platforms visibly read the same window. A night is ~30k rows at 1 Hz.
            //
            // The aux read gets its OWN runCatching rather than riding the enclosing one. Letting it
            // propagate would abort the whole funnels block on a failure here — the skin-temp and REM
            // lines above would be followed by a generic "(funnels unavailable)" instead of this line
            // saying which of the two things happened. A failed read and a night with no candidate are
            // different facts, and this is a diagnostic. Byte-for-byte the same four outcomes, in the
            // same order, with the same wording as the Swift `DebugDataDiagnostics` twin.
            val auxRead = runCatching {
                repo.v18AuxSamples(id, session.startTs, session.endTs, SPO2_CANDIDATE_AUX_LIMIT)
            }.getOrNull()
            val cand = auxRead?.let {
                com.noop.analytics.AnalyticsEngine.nightlySpo2CandidateMean(listOf(det), it)
            }
            when {
                auxRead == null -> add(
                    "SpO₂ candidate @82: could not read the aux stream for this night — " +
                        "a read failure, NOT an absence of readings.")
                cand != null -> add(
                    "SpO₂ candidate @82 (5/MG): mean ${cand.first} over ${cand.second} in-band readings " +
                        "— UNVERIFIED, compare against the WHOOP app's figure for this night (#103).")
                family == com.noop.protocol.DeviceFamily.WHOOP5 ->
                    add("SpO₂ candidate @82 (5/MG): no in-band readings inside this night's span.")
                else -> add("SpO₂ candidate @82: not carried by a WHOOP 4.0 (raw red/IR ADC only).")
            }
        }.onFailure { add("(funnels unavailable: ${it.message})") }
    }

    /** Workout & imported-activity source breakdown. The "counted but not shown" bug class (#28: strap
     *  workouts banked under "my-whoop" while the load queried the active strap id; #29: "activity-file"
     *  imports the load path never read) is invisible in a strap log without this. Surfaces the RESOLVED
     *  active deviceId + a per-source STORED workout count + the most-recent workout, so a report reveals
     *  WHERE workouts live vs what the Workouts screen loads. Best-effort. */
    suspend fun workoutSourceLines(context: Context): List<String> = buildList {
        add("─".repeat(40))
        add("Workouts by source")
        runCatching {
            val repo = com.noop.data.WhoopRepository.from(context)
            val now = System.currentTimeMillis() / 1000
            val active = runCatching {
                (context.applicationContext as com.noop.NoopApplication).activeDeviceId
            }.getOrNull() ?: "unknown"
            add("Active deviceId: $active" + if (active == "my-whoop") "" else "  (imports + spine under my-whoop)")
            // Per-source STORED counts; ids de-duped so a single-WHOOP install (active == my-whoop) lists once.
            val ids = listOf(active, "my-whoop", "$active-noop", "my-whoop-noop",
                "activity-file", "lifting", "apple-health", "health-connect").distinct()
            val perSource = ids.map { it to repo.workouts(it, 0L, now) }
            add("Stored: " + perSource.joinToString("  ") { "${it.first}=${it.second.size}" })
            val latest = perSource.flatMap { it.second }.maxByOrNull { it.startTs }
            add(if (latest != null) "Latest: ${dayStamp(latest.startTs)} · ${latest.sport} (${latest.source})" else "Latest: none")
        }.onFailure { add("(workout sources unavailable: ${it.message})") }
    }

    /** Daily-data source breakdown + on-device volume. The active-strap↔"my-whoop" id mismatch strands
     *  DAYS / steps / sleep / recovery the same way it strands workouts (#28), so a "no data / no steps /
     *  0% REM" report needs the same reconciliation: per-source day counts, which metrics are actually
     *  populated over the recent week, and the raw-row footprint. Best-effort. */
    suspend fun dailyDataLines(context: Context): List<String> = buildList {
        add("─".repeat(40))
        add("Daily data by source")
        runCatching {
            val repo = com.noop.data.WhoopRepository.from(context)
            val active = runCatching {
                (context.applicationContext as com.noop.NoopApplication).activeDeviceId
            }.getOrNull() ?: "unknown"
            val ids = listOf(active, "my-whoop", "$active-noop", "my-whoop-noop",
                "apple-health", "health-connect").distinct()
            val dayCounts = ids.map { it to repo.days(it).size }
            add("Days: " + dayCounts.joinToString("  ") { "${it.first}=${it.second}" })
            // Which metrics are actually populated over the recent week on the imported spine.
            val recent = repo.days("my-whoop").takeLast(7)
            if (recent.isNotEmpty()) {
                val n = recent.size
                add("Recent ${n}d (my-whoop): " +
                    "sleep=${recent.count { (it.totalSleepMin ?: 0.0) > 0 }}/$n  " +
                    "recovery=${recent.count { it.recovery != null }}/$n  " +
                    "steps=${recent.count { it.steps != null }}/$n  " +
                    "kcal=${recent.count { it.activeKcalEst != null }}/$n")
            } else add("Recent: no day rows")
            val dv = repo.dataVolumeSnapshot(active)
            add("Volume: rawRows=${dv.dbRows}  importedDays=${dv.importedDays}  workouts=${dv.workouts}")
        }.onFailure { add("(daily data unavailable: ${it.message})") }
    }

    /** Alarm state for the debug export: the configured wake + the last arm's sent-vs-strap-reports (#34), so
     *  a "didn't buzz" report shows whether the strap accepted the time. Reads persisted prefs (written by
     *  WhoopBleClient.armStrapAlarm + the GET_ALARM_TIME readback). Best-effort. */
    fun alarmLines(context: Context): List<String> = buildList {
        add("─".repeat(40))
        add("Alarm")
        runCatching {
            val p = com.noop.ui.NoopPrefs.of(context)
            val on = com.noop.ui.NoopPrefs.smartAlarmEnabled(context)
            val mins = com.noop.ui.NoopPrefs.smartAlarmMinutes(context)
            add("Enabled: ${if (on) "yes" else "no"} · set ${"%02d:%02d".format(mins / 60, mins % 60)}")
            // #3: model + the 5/MG experimental gate (a 5/MG firmware alarm is NOT armed unless it's on).
            if (com.noop.ui.NoopPrefs.lastDevice(context)?.second == com.noop.ble.WhoopModel.WHOOP5_MG) {
                val exp = com.noop.ble.PuffinExperiment.from(context).isEnabled
                add("Model: WHOOP 5.0/MG · experimental: ${if (exp) "on" else "off → firmware alarm NOT armed"}")
            } else {
                add("Model: WHOOP 4.0")
            }
            // #4: strap clock health — a reset/stale OR future-dated clock (the #34 / #928 causes) breaks
            // the alarm even when armed.
            val newest = p.getLong("strap.newestRecordTs", 0L)
            if (newest > 0L) {
                val behind = System.currentTimeMillis() / 1000L - newest
                add(when {
                    behind > 3 * 86400L -> "Strap clock: ${behind / 86400L}d behind wall (reset/stale — alarm unreliable)"
                    behind < -3 * 86400L -> "Strap clock: ${-behind / 86400L}d AHEAD of wall (future-dated — alarm unreliable)"
                    else -> "Strap clock: OK"
                })
            }
            val sent = p.getLong("alarm.lastArmSentEpoch", 0L)
            if (sent > 0L) {
                val at = p.getLong("alarm.lastArmAt", 0L)
                var line = "Last arm: sent ${alarmStamp(sent)}"
                if (at > 0L) line += " · ${relTime(System.currentTimeMillis() - at)}"
                if (!p.getBoolean("alarm.lastArmConnected", false)) line += " · strap NOT connected (queued)"
                // #34: live HR at arm, logged only to test whether the strap's own sleep/rest detection
                // (not anything NOOP sends) gates the physical haptic — see recordAlarmArm's doc comment.
                if (p.contains("alarm.lastArmHeartRate")) line += " · HR ${p.getInt("alarm.lastArmHeartRate", 0)} bpm at arm"
                add(line)
                val reported = p.getLong("alarm.lastReportedEpoch", 0L)
                if (reported > 0L) {
                    val mismatch = kotlin.math.abs(reported - sent) > 120
                    add("Strap reports: ${alarmStamp(reported)}" +
                        if (mismatch) "  ⚠️ MISMATCH — strap didn't accept the time" else "  ✓ matches")
                } else add("Strap reports: (no readback)")
            } else add("Last arm: never")
            // #1: did the strap actually fire? (STRAP_DRIVEN_ALARM_EXECUTED)
            val firedAt = p.getLong("alarm.lastFiredAt", 0L)
            add(if (firedAt > 0L) "Last fired: ${relTime(System.currentTimeMillis() - firedAt)}" else "Last fired: never observed")
        }.onFailure { add("(alarm state unavailable: ${it.message})") }
    }

    private fun alarmStamp(epochSec: Long): String = runCatching {
        java.text.SimpleDateFormat("yyyy-MM-dd HH:mm", java.util.Locale.US).format(epochSec * 1000L)
    }.getOrDefault("?")

    /** The DB/prefs-backed diagnostic lines appended to the export header. Suspends (reads the local store);
     *  guarded per-section so it never throws into the export. */
    suspend fun dynamicLines(context: Context): List<String> =
        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Default) {
            strapAndDataLines(context) + funnelLines(context) + workoutSourceLines(context) +
                dailyDataLines(context) + alarmLines(context)
        }

    /** "3h 12m ago" style relative stamp for a positive age in ms. */
    private fun relTime(deltaMs: Long): String {
        if (deltaMs < 60_000L) return "just now"
        val min = deltaMs / 60_000L
        return when {
            min < 60 -> "${min}m ago"
            min < 1440 -> "${min / 60}h ${min % 60}m ago"
            else -> "${min / 1440}d ago"
        }
    }

    private fun tzLine(): String = runCatching {
        val tz = java.util.TimeZone.getDefault()
        val offMin = tz.getOffset(System.currentTimeMillis()) / 60_000
        val a = kotlin.math.abs(offMin)
        "${tz.id} (UTC${if (offMin >= 0) "+" else "-"}${a / 60}:${"%02d".format(a % 60)})"
    }.getOrDefault("unknown")

    private fun dayStamp(epochSec: Long): String = runCatching {
        java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(epochSec * 1000L)
    }.getOrDefault("?")

    /** Doze exemption: an app NOT exempt from battery optimisation is the #1 cause of missed overnight
     *  background work on Android. */
    private fun batteryOptimisationText(context: Context): String = runCatching {
        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
        when (pm?.isIgnoringBatteryOptimizations(context.packageName)) {
            true -> "exempt (background work allowed)"
            false -> "NOT exempt (Android may kill overnight background BLE)"
            null -> "unknown"
        }
    }.getOrDefault("unknown")

    /** A coarse OEM-kill heuristic by manufacturer (the aggressive-background-kill vendors). Pure and
     *  internal so it unit-tests without a Context (the suite stays Robolectric-free). */
    internal fun oemKillHeuristic(manufacturer: String): String =
        // Single source of truth for the aggressive-vendor set (#386): the same list the Settings
        // "Keep NOOP alive overnight" toggle gates on, so the diagnostic and the fix never disagree.
        if (com.noop.ble.BackgroundHealth.isAggressiveVendor(manufacturer))
            "aggressive vendor (${manufacturer.lowercase()}), whitelist NOOP to keep it alive"
        else "standard"

    /** Charging state from the sticky battery intent / BatteryManager. */
    private fun chargingText(context: Context): String = runCatching {
        val bm = context.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
        when (bm?.isCharging) {
            true -> "yes"
            false -> "no (on battery)"
            null -> "unknown"
        }
    }.getOrDefault("unknown")

    /** Grant state of the permissions a background strap app needs. */
    private fun permissionsText(context: Context): String {
        val checks = buildList {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) add("BLUETOOTH_CONNECT" to Manifest.permission.BLUETOOTH_CONNECT)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) add("POST_NOTIFICATIONS" to Manifest.permission.POST_NOTIFICATIONS)
            add("LOCATION" to Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return checks.joinToString(", ") { (label, perm) ->
            val granted = runCatching {
                context.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
            }.getOrDefault(false)
            "$label=${if (granted) "granted" else "denied"}"
        }
    }
}
