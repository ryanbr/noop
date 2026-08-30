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
     * The strap family a diagnostic export should REPORT — the one that actually advertised, when we know
     * it, and `null` when we genuinely do not.
     *
     * Two prefs hold a model and they disagree. `noop.selectedWhoopModel` is written by
     * `WhoopBleClient.persistSelectedModel` from the family that actually advertised, so it is the truth.
     * `noop.lastDeviceModel` is the pair-time memory, and `NoopPrefs.lastDevice` widens a missing value to
     * `WHOOP4` — a sensible default for RECONNECTING (the code must pick a service to try) but a lie in a
     * report, which is read as an observation.
     *
     * Two field logs from confirmed WHOOP 5 straps were headed "Model: WHOOP 4.0" (#1451, #1464), and both
     * misdirected triage before the decoded layout version gave them away. A report may say "unknown"; it
     * may not invent a model. Reads the raw prefs rather than `lastDevice` precisely so that "remembered as
     * a 4.0" stays distinguishable from "nothing remembered".
     */
    private fun reportedModel(context: Context): com.noop.ble.WhoopModel? {
        val prefs = com.noop.ui.NoopPrefs.of(context)
        val detected = prefs.getString("noop.selectedWhoopModel", null)
        val remembered = prefs.getString(com.noop.ui.NoopPrefs.KEY_LAST_DEVICE_MODEL, null)
        return (detected ?: remembered)
            ?.let { runCatching { com.noop.ble.WhoopModel.valueOf(it) }.getOrNull() }
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
            add(
                "Model:       " + when {
                    dev == null -> "unknown (never paired)"
                    else -> reportedModel(context)?.displayName ?: "unknown (paired, family not yet detected)"
                },
            )
            // #1633 follow-up: the ACTIVE device's own firmware. This read used to be the bare global key,
            // so a two-strap log named whichever strap connected last - a 5/MG log reporting a 4.0's
            // 41.17.6.0. resolveFirmware falls back to the legacy key only when one device is paired.
            val fwRows = runCatching {
                (context.applicationContext as? com.noop.NoopApplication)?.deviceRegistry?.all().orEmpty()
            }.getOrDefault(emptyList())
            val fwActive = runCatching {
                (context.applicationContext as? com.noop.NoopApplication)?.deviceRegistry?.activeDeviceId()
            }.getOrNull()
            val fwRow = fwRows.firstOrNull { it.id == fwActive }
            val fw = com.noop.ble.resolveFirmware(
                live = null,
                perDevice = com.noop.ui.NoopPrefs.firmwareFor(context, fwRow?.peripheralId),
                legacyGlobal = com.noop.ui.NoopPrefs.lastFirmware(context),
                pairedCount = fwRows.size,
            )
            add("Firmware:    ${fw ?: "unknown (connect to record)"}")
            // THIS strap's own sync, attributed the same way the firmware above is. The old global key
            // reported whichever strap synced last, so a 5/MG that had never banked a row showed its
            // paired 4.0's timestamp — the line that made a non-existent sync regression look real.
            val syncSec = com.noop.ble.resolveLastSync(
                perDevice = com.noop.ui.NoopPrefs.lastSyncAtFor(context, fwRow?.peripheralId),
                legacyGlobal = com.noop.ui.NoopPrefs.lastSyncAt(context),
                pairedCount = fwRows.size,
            ) ?: 0L
            add("Last sync:   ${if (syncSec > 0L) relTime(System.currentTimeMillis() - syncSec * 1000L)
                else "never (this strap)"}")
            // #57: write-health. "Last sync" fires even on an empty/failed offload, so distinguish "rows
            // actually landed" from "an offload STALLED on a persist failure" (history won't persist —
            // usually a backup restored without an app restart, the closed-DB class).
            val p = com.noop.ui.NoopPrefs.of(context)
            // Attributed exactly like "Last sync" above — the legacy global counts only when a single
            // strap could have written it, so the pair can never mix one strap's stall with another's
            // success. Read together: "stalled more recently than ok" is the alarm.
            val okAt = com.noop.ble.resolveLastSync(
                perDevice = com.noop.ble.writeHealthPrefKey(fwRow?.peripheralId, "lastWriteOkAt")
                    ?.let { p.getLong(it, 0L) } ?: 0L,
                legacyGlobal = p.getLong("sync.lastWriteOkAt", 0L),
                pairedCount = fwRows.size,
            ) ?: 0L
            val stalledAt = com.noop.ble.resolveLastSync(
                perDevice = com.noop.ble.writeHealthPrefKey(fwRow?.peripheralId, "lastWriteStalledAt")
                    ?.let { p.getLong(it, 0L) } ?: 0L,
                legacyGlobal = p.getLong("sync.lastWriteStalledAt", 0L),
                pairedCount = fwRows.size,
            ) ?: 0L
            val restoreAt = p.getLong("backup.lastRestoreAt", 0L)
            val now = System.currentTimeMillis()
            add("Data write:  ${if (okAt > 0L) "rows last landed ${relTime(now - okAt * 1000L)}" else "no rows ever persisted"}")
            if (stalledAt > 0L && stalledAt >= okAt) {
                add("             ⚠ history NOT persisting — last offload STALLED ${relTime(now - stalledAt * 1000L)} " +
                    "(if you restored a backup, fully restart the app — #57)")
            }
            if (restoreAt > 0L) add("Last restore: ${relTime(now - restoreAt * 1000L)}")
            // #1735: row COUNTS alone cannot separate "Health Connect never brought the ride in" from
            // "it did, but nothing has re-scored since". Both halves of that need a WHEN, and neither had
            // one: the importer recorded no run time at all, and the engine's "re-score: done" goes only to
            // the live log, so an export written hours later has already rolled it away.
            val hcAt = p.getLong("hc.lastImportOkAt", 0L)
            add(
                hcImportLine(
                    ago = if (hcAt > 0L) relTime(now - hcAt * 1000L) else null,
                    rows = p.getInt("hc.lastImportRows", 0),
                    throughDay = p.getString("hc.lastImportThroughDay", null),
                ),
            )
            val scoredAt = p.getLong("score.lastPassAt", 0L)
            add(scoringPassLine(ago = if (scoredAt > 0L) relTime(now - scoredAt * 1000L) else null))
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
            // #1300 follow-up: the header above describes ONE device because it reads the last-connected
            // prefs, not the registry — so a two-strap install produced a log that never mentioned the
            // second strap, leaving `dayOwner readId=` and the funnel's orphan check with nothing to be
            // checked against. Name the whole set instead.
            val invRows = runCatching {
                (context.applicationContext as? com.noop.NoopApplication)?.deviceRegistry?.all().orEmpty()
                    .map {
                            InventoryRow(it.id, it.brand, it.model, it.status, it.lastSeenAt,
                                         com.noop.ui.NoopPrefs.firmwareFor(context, it.peripheralId))
                        }
            }.getOrDefault(emptyList())
            val invActive = runCatching {
                (context.applicationContext as? com.noop.NoopApplication)?.deviceRegistry?.activeDeviceId()
            }.getOrNull()
            deviceInventoryLines(invRows, invActive, System.currentTimeMillis() / 1000L) { relTime(it) }
                .forEach { add(it) }
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
            val grav = repo.gravitySamplesForDevice(id, session.startTs, session.endTs, Int.MAX_VALUE)
            val hr = repo.hrSamplesForDevice(id, session.startTs, session.endTs, Int.MAX_VALUE)
            val rr = repo.rrIntervalsForDevice(id, session.startTs, session.endTs, Int.MAX_VALUE)
            val resp = repo.respSamples(id, session.startTs, session.endTs, Int.MAX_VALUE)
            add("Night ${dayStamp(session.startTs)}: grav=${grav.size} hr=${hr.size} rr=${rr.size} resp=${resp.size} skin=${skin.size}")
            if (grav.isEmpty() && hr.isEmpty()) {
                // #1617 follow-up: do NOT assert "freshly re-added" without testing the other explanation.
                // Several ids can hold one physical strap's data (#1193/#740), and when the history spine
                // and the raw stream split, the samples exist - just under a different id. The old line
                // printed the innocent cause for that case, which stops the investigation at exactly the
                // point it should start. Ask the SAMPLE TABLES, not the registry: "my-whoop" is a source
                // label rather than a pairedDevice row, and forgetting a device drops its row while leaving
                // its samples - so the registry is blind to exactly the ids worth naming here. Only runs
                // when the active id came back empty, so a healthy install pays nothing.
                val elsewhere = runCatching {
                    repo.rawSampleCountsByDevice(session.startTs, session.endTs)
                        .filter { it.first != id }
                }.getOrDefault(emptyList())
                // The registry, so a SECOND strap's night is not reported as a read failure. Only queried
                // when the active id came back empty, so a healthy install still pays nothing.
                val otherStraps = runCatching {
                    repo.pairedDevices()
                        .filter { it.status != "archived" && it.id != id }
                        .map { it.id }
                        .toSet()
                }.getOrDefault(emptySet())
                add(orphanedSamplesLine(id, elsewhere, otherStraps))
                return@runCatching
            }
            com.noop.analytics.SleepStager.remFunnelDiagnostic(session.startTs, session.endTs, grav, hr, rr, resp)
                ?.let { add(it.summary) } ?: add("REM funnel: insufficient motion data (<2 gravity samples)")
            val det = com.noop.analytics.DetectedSleep(
                start = session.startTs, end = session.endTs,
                efficiency = session.efficiency ?: 0.0, stages = emptyList(),
                restingHR = session.restingHr, avgHRV = session.avgHrv,
            )
            // Unknown still resolves to WHOOP4 here: this one picks an analysis default, it does not
            // report an observation, and every prior export took that branch.
            val family = if (reportedModel(context) == com.noop.ble.WhoopModel.WHOOP5_MG)
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
            // #1735: "auto-detect is off but workouts keep appearing" is answerable only if the log says
            // which of the TWO detectors is meant. The Settings toggle governs the opt-in suggestion card
            // ONLY; the engine derives durable sport="detected" rows on every pass regardless, and all the
            // per-bout tracing for that sits behind the Test Centre WORKOUTS domain, which a reporter
            // filing a non-test-mode bug will not have on. Counts read from the store, so this states what
            // IS, not what the code intends.
            // Guarded SEPARATELY from the section: this file's contract is that every probe is guarded,
            // and a throw in here would otherwise be caught by the outer handler and reported as
            // "(workout sources unavailable)" - blaming the store for a failure in the auto-detect probe,
            // with the sources sitting right above it having plainly worked.
            runCatching {
                autoDetectStateLine(
                    suggestionCardEnabled = com.noop.ui.NoopPrefs.autoDetectWorkouts(context),
                    storedDetectedRows = perSource.flatMap { it.second }.count { it.sport == "detected" },
                    // Summed over the SAME strap ids whose rows were counted above. A two-strap install
                    // banks detected rows under both "<active>-noop" and "my-whoop-noop", so reading
                    // dismissals for the active strap alone could print "detected=52 dismissed=0" while
                    // the dismissals sat under the other id, sending a reader after the #107 mechanism.
                    dismissedMarkers = runCatching {
                        listOf(active, "my-whoop").distinct().sumOf { repo.dismissedDetected(it).size }
                    }.getOrNull(),
                )
            }.onSuccess { add(it) }.onFailure { add("(auto-detect state unavailable: ${it.message})") }
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
            // Which metrics are actually populated over the recent week on the imported (raw) spine…
            // The day-SPAN is stamped so a stale spine is visible: `takeLast(7)` can be the last 7 IMPORTED
            // rows (months old), not the last 7 CALENDAR days — without the range they look identical. Twin
            // of the Swift #731 fix.
            val recent = repo.days("my-whoop").takeLast(7)
            if (recent.isNotEmpty()) {
                val n = recent.size
                val span = "${recent.first().day}…${recent.last().day}"
                add("Recent ${n}d (my-whoop, $span): " +
                    "sleep=${recent.count { (it.totalSleepMin ?: 0.0) > 0 }}/$n  " +
                    "recovery=${recent.count { it.recovery != null }}/$n  " +
                    "steps=${recent.count { it.steps != null }}/$n  " +
                    "kcal=${recent.count { it.activeKcalEst != null }}/$n")
            } else add("Recent: no day rows")
            // …and on the COMPUTED "-noop" spine, where steps/activeKcalEst are actually written. Compare the
            // two: if kcal/steps are populated here but 0 on the raw line above, the raw-spine merge/view is
            // dropping them (cosmetic); if 0 on BOTH, the value genuinely wasn't computed (a real gap).
            val recentNoop = repo.days("my-whoop-noop").takeLast(7)
            if (recentNoop.isNotEmpty()) {
                val nn = recentNoop.size
                val spanNoop = "${recentNoop.first().day}…${recentNoop.last().day}"
                add("Recent ${nn}d (my-whoop-noop, computed, $spanNoop): " +
                    "sleep=${recentNoop.count { (it.totalSleepMin ?: 0.0) > 0 }}/$nn  " +
                    "recovery=${recentNoop.count { it.recovery != null }}/$nn  " +
                    "steps=${recentNoop.count { it.steps != null }}/$nn  " +
                    "kcal=${recentNoop.count { it.activeKcalEst != null }}/$nn")
            }
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
            when (reportedModel(context)) {
                com.noop.ble.WhoopModel.WHOOP5_MG -> {
                    val exp = com.noop.ble.PuffinExperiment.from(context).isEnabled
                    // displayName, not a literal: this block spelled it "WHOOP 5.0/MG" while the enum (and
                    // the header a few lines up) says "WHOOP 5.0 / MG", so one export disagreed with itself.
                    add(
                        "Model: ${com.noop.ble.WhoopModel.WHOOP5_MG.displayName} · experimental: " +
                            if (exp) "on" else "off → firmware alarm NOT armed",
                    )
                }
                com.noop.ble.WhoopModel.WHOOP4 -> add("Model: ${com.noop.ble.WhoopModel.WHOOP4.displayName}")
                null -> add("Model: unknown (family not yet detected)")
            }
            // #4: strap clock health — a reset/stale OR future-dated clock (the #34 / #928 causes) breaks
            // the alarm even when armed.
            val newest = p.getLong("strap.newestRecordTs", 0L)
            if (newest > 0L) {
                val behind = System.currentTimeMillis() / 1000L - newest
                add(when {
                    behind > 3 * 86400L -> "Strap clock: ${behind / 86400L}d behind wall (reset/stale — alarm unreliable)"
                    behind < -3 * 86400L -> "Strap clock: ${-behind / 86400L}d AHEAD of wall (future-dated — alarm unreliable)"
                    // #1706: say what this is measuring. It reads RECORD timestamps, and sat two lines
                    // above an alarm readback claiming 2045, which reads as the two contradicting.
                    else -> "Strap clock: OK (from record timestamps, not the alarm readback)"
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
                    // #1706: only judge when both halves are known to be the SAME strap. The readback is
                    // written on the WHOOP 4.0 path alone, so a 5.0-active install comparing these was
                    // always comparing two devices and then blaming one of them.
                    val verdict = com.noop.analytics.AlarmReadback.verdict(
                        sentEpoch = sent,
                        reportedEpoch = reported,
                        sentDeviceId = p.getString("alarm.lastArmDeviceId", null),
                        reportedDeviceId = p.getString("alarm.lastReportedDeviceId", null),
                    )
                    add("Strap reports: ${alarmStamp(reported)}" + com.noop.analytics.AlarmReadback.suffix(verdict))
                    // The bytes the epoch was decoded from: what tells a stored stale alarm from a misdecode.
                    p.getString("alarm.lastReportedRaw", null)
                        ?.takeIf { it.isNotBlank() }
                        ?.let { add("Readback frame: $it") }
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
                dailyDataLines(context) + alarmLines(context) + circadianLines(context)
        }

    /**
     * One-decimal float, always with a DOT.
     *
     * This file already pins `Locale.US` for its dates, for the same reason: the strap log is pasted into
     * issues and read by whoever picks them up, so a device in a comma-decimal locale must not emit
     * "4,7 bpm" beside US-formatted timestamps. Kotlin's `"%.1f".format(x)` uses the default locale and
     * would do exactly that.
     */
    private fun fmt1(v: Double): String = String.format(java.util.Locale.US, "%.1f", v)

    /** Hourly HR buckets over the 14-day window below which the profile is not pooled at all. Mirrors
     *  `circadianBinsFrom`'s own floor — kept here so the diagnostic names the real number, not a guess. */
    internal const val CIRCADIAN_MIN_BUCKETS = 24
    /** Distinct populated local hours below which no estimate is attempted.
     *
     *  REFERENCES the engine's own constant rather than repeating its value. A diagnostic that prints
     *  "needs 6" while the code requires 8 would send whoever reads the log after the wrong thing —
     *  the one failure mode this section exists to prevent. */
    internal val CIRCADIAN_MIN_HOURS get() = com.noop.analytics.V5HealthSignals.MIN_CIRCADIAN_BINS

    /**
     * Which gate the body clock is failing.
     *
     * The first two are sequential gates and are reported in the order they run. The last two are a
     * SINGLE condition in the engine (`daysObserved < minDaysForFit || relativeAmplitude <
     * minRelativeAmplitude`), split apart here because "unreadable" on its own does not say whether to
     * keep wearing the strap or to question the threshold — and those lead somewhere different.
     *
     * The card vanishes for two DIFFERENT reasons that look identical on screen: below the bucket floor
     * or the hour floor there is NO estimate at all (`V5HealthSignals` returns null and the card's `?.let`
     * skips it), while a thin or flat fit still returns an estimate marked UNREADABLE, which DOES draw a
     * card with its own copy. Without this line those are indistinguishable from the outside — the report
     * that prompted it had a body clock missing on both the Health card and the Sleep dial with no way to
     * say which floor was short.
     *
     * Pure so the wording is assertable without a store, matching `noCaptureMsgText`.
     */
    internal fun circadianVerdict(
        buckets: Int,
        populatedHours: Int,
        daysObserved: Int,
        relativeAmplitude: Double?,
        amplitudeBpm: Double? = null,
    ): String = when {
        buckets < CIRCADIAN_MIN_BUCKETS ->
            "no estimate — $buckets hourly HR buckets in 14d, needs $CIRCADIAN_MIN_BUCKETS"
        populatedHours < CIRCADIAN_MIN_HOURS ->
            "no estimate — HR lands in $populatedHours of 24 local hours, needs $CIRCADIAN_MIN_HOURS"
        // Mirrors the engine's OR: a swing passes on the proportional test or on the absolute one. Read
        // the two apart and this line starts reporting "too flat" for rhythms the engine accepts.
        relativeAmplitude != null &&
            relativeAmplitude < com.noop.analytics.CircadianEngine.minRelativeAmplitude &&
            (amplitudeBpm ?: 0.0) < com.noop.analytics.CircadianEngine.minAbsoluteAmplitudeBpm ->
            "unreadable — rhythm too flat (amplitude ${fmt1(relativeAmplitude * 100)}% of mesor, " +
                "needs ${fmt1(com.noop.analytics.CircadianEngine.minRelativeAmplitude * 100)}% or " +
                "${fmt1(com.noop.analytics.CircadianEngine.minAbsoluteAmplitudeBpm)} bpm)"
        daysObserved < com.noop.analytics.CircadianEngine.minDaysForFit ->
            "unreadable — $daysObserved days observed, needs " +
                "${com.noop.analytics.CircadianEngine.minDaysForFit}"
        // SOLID needs BOTH axes, exactly as estimatePhase assigns it. Reading only the days here printed
        // "solid" for a wearer the engine had marked WIDE — the diagnostic contradicting the very screen
        // it exists to explain, which is the one thing this section must never do.
        daysObserved < com.noop.analytics.CircadianEngine.goodDaysForFit ->
            "wide — $daysObserved days observed"
        relativeAmplitude != null &&
            relativeAmplitude < com.noop.analytics.CircadianEngine.minRelativeAmplitude ->
            "wide — $daysObserved days observed, but the swing clears only the absolute floor " +
                "(${fmt1(relativeAmplitude * 100)}% of mesor)"
        else -> "solid — $daysObserved days observed"
    }

    /**
     * The body clock's three inputs, RECOMPUTED from the store.
     *
     * It reports what `estimatePhase` WOULD return for the data on disk — not what `_v5Signals.bodyClock`
     * is currently holding. Those can diverge: a cached-bins staleness once nulled the live estimate on a
     * device whose store was fine, and against that failure this section would have printed a confident
     * verdict beside a missing card, misleading exactly as the silence it replaced did. So a verdict here
     * that disagrees with the screen is itself the finding — it means the snapshot, not the data, is wrong.
     *
     * Hours and days are counted from the RAW buckets rather than from `circadianBinsFrom`, which
     * short-circuits to empty below the bucket floor — reporting its zeros would hide the very numbers
     * this line exists to show.
     */
    suspend fun circadianLines(context: Context): List<String> = buildList {
        add("─".repeat(40))
        add("Body clock inputs (recomputed from the store, not the live snapshot)")
        runCatching {
            val repo = com.noop.data.WhoopRepository.from(context)
            val active = runCatching {
                (context.applicationContext as com.noop.NoopApplication).activeDeviceId
            }.getOrNull() ?: "unknown"
            val nowMs = System.currentTimeMillis()
            val now = nowMs / 1000L
            val tz = java.util.TimeZone.getDefault().getOffset(nowMs) / 1000L
            val buckets = repo.hrBucketsUnion(active, now - 14L * 86_400L, now, 3_600L)
            val hours = buckets.map { (((it.bucket + tz) % 86_400L + 86_400L) % 86_400L / 3_600L) }
                .distinct().size
            val days = buckets.map { (it.bucket + tz) / 86_400L }.distinct().size
            val bins = com.noop.ui.circadianBinsFrom(buckets, tz).first
            val fit = com.noop.analytics.CircadianEngine.cosinor(bins)
            val amp = fit?.let { f ->
                if (f.mesor != 0.0) f.amplitude / kotlin.math.abs(f.mesor) else 0.0
            }
            add("Source: $active (+ imported)  window: last 14d")
            add("Buckets: ${buckets.size} (floor $CIRCADIAN_MIN_BUCKETS)  " +
                "hours: $hours/24 (need $CIRCADIAN_MIN_HOURS)  days: $days " +
                "(need ${com.noop.analytics.CircadianEngine.minDaysForFit})")
            // The ratio alone is not interpretable — "7.3% of mesor" says nothing about whether the
            // rhythm is genuinely flat or the bar is simply set high for this wearer. The absolute pair is
            // what makes the threshold arguable, and it is what `minRelativeAmplitude`'s own note asks for
            // ("it needs a wearer whose amplitude is disproportionately small for their mesor").
            if (fit != null) {
                add("Rhythm: amplitude ${fmt1(fit.amplitude)} bpm on a " +
                    "${fmt1(fit.mesor)} bpm mesor  (acrophase " +
                    "${fmt1(fit.acrophaseHours)}h)")
            }
            add("Verdict: " + circadianVerdict(buckets.size, hours, days, amp, fit?.amplitude))
        }.onFailure { add("  (unavailable: ${it.message})") }
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

    /**
     * When Health Connect last completed an import, and what it brought.
     *
     * The export already listed per-source row counts, which answer "is there data" but never "is it
     * MOVING". #1735 turns on exactly that difference: a ride that has not appeared is either one Health
     * Connect never imported or one it imported and nothing re-scored, and a static count cannot tell
     * those apart. [rows] of 0 with a recent [ago] is a real and useful state - the import ran and found
     * nothing - which is why the empty path is stamped too.
     *
     * A null [ago] means no import has ever completed on this install. Stated plainly rather than dressed
     * up as a fault: plenty of installs never connect Health Connect at all.
     */
    internal fun hcImportLine(ago: String?, rows: Int, throughDay: String?): String {
        if (ago == null) return "HC import:   never completed on this install"
        val through = throughDay?.let { " · through $it" } ?: ""
        return "HC import:   $rows row(s) $ago$through"
    }

    /**
     * When the scoring engine last completed a pass.
     *
     * The analyze watermark records WHAT was scored (an HR fingerprint) and never WHEN, and the engine's
     * own "re-score: done" line is live-log only, so an export written hours after the pass has already
     * rolled it away. Without this, "I synced and nothing appeared" cannot distinguish a pass that ran and
     * found nothing new from one that never ran - and those need opposite next steps.
     *
     * Stamped at BOTH completion sites (the idle pass and the post-sync pass), so the freshest of the two
     * is what shows.
     */
    internal fun scoringPassLine(ago: String?): String =
        if (ago == null) "Scoring:     no pass has completed on this install"
        else "Scoring:     last pass $ago"

    /**
     * Which workout detector produced what, and whether the Settings toggle has anything to do with it.
     *
     * NOOP has TWO detectors and they are deliberately separate (see AutoWorkoutDetector's header). The
     * Settings toggle governs the opt-in SUGGESTION card, which only ever offers a workout and saves
     * nothing until the user taps Save. The IntelligenceEngine separately derives durable sport="detected"
     * rows from the 1 Hz store on every scoring pass, and that has never been gated by the toggle.
     *
     * Both are called "detect" in the UI, so #1735 read the second one's rows as the first one ignoring
     * its own switch, which is an entirely reasonable reading. Every per-bout line that would have shown
     * the difference sits behind the Test Centre WORKOUTS domain, and that report was filed as "not a
     * test-mode bug" with the domain off, so the log carried nothing about it at all.
     *
     * Reads COUNTS from the store rather than describing intent: it states what is on disk, not what the
     * code believes it does. The reassurance clause is emitted only for the combination that actually
     * misleads (card off, rows present) so it never claims to explain a state it is not looking at.
     * [dismissedMarkers] is null when the query failed, and renders "n/a" rather than a wrong zero, which
     * would read as "your dismissals are not sticking".
     */
    internal fun autoDetectStateLine(
        suggestionCardEnabled: Boolean,
        storedDetectedRows: Int,
        dismissedMarkers: Int?,
    ): String {
        val card = if (suggestionCardEnabled) "on" else "off"
        val dismissed = dismissedMarkers?.toString() ?: "n/a"
        val note = if (!suggestionCardEnabled && storedDetectedRows > 0) {
            " (rows with the card off are EXPECTED: a different detector makes them)"
        } else {
            ""
        }
        return "Auto-detect: suggestion card=$card · engine \"Activity\" rows=always on, not gated by " +
            "that toggle · stored detected=$storedDetectedRows · dismissed markers=$dismissed$note"
    }

    /** A coarse OEM-kill heuristic by manufacturer (the aggressive-background-kill vendors). Pure and
     *  internal so it unit-tests without a Context (the suite stays Robolectric-free). */
    internal fun oemKillHeuristic(manufacturer: String): String =
        // Single source of truth for the aggressive-vendor set (#386): the same list the Settings
        // "Keep NOOP alive overnight" row gates on, so the diagnostic and the fix never disagree.
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

    /**
     * #1617 follow-up: the line the night funnel prints when the ACTIVE device id carries no raw samples.
     *
     * The previous wording asserted "expected on a freshly re-added strap" unconditionally. That is one of
     * two explanations, and the other one is a bug: a registry can hold several ids for the same physical
     * strap (#1193/#740), and when the history spine and the raw stream split, the samples are present -
     * just filed under a different id. Printing the innocent cause for that case ends the investigation at
     * the point it should begin, which is worse than printing nothing.
     *
     * [othersWithSamples] is (deviceId, sampleCount) for every OTHER registry id that does hold samples in
     * the same window. Empty means the samples genuinely are not there and the fresh-re-add wording is
     * right; non-empty names the id that has them so the split is visible rather than inferred.
     *
     * [otherLiveStrapIds] is the registered, non-archived device ids OTHER than the active one. It exists
     * because the "not being read" wording was itself an over-assertion — the mirror image of the one it
     * replaced. A wearer with TWO straps has nights owned by the other one, and [DayOwnerResolver] hands
     * each day to whichever device actually holds its data. Samples under another id are then completely
     * normal, and calling that a read failure sends the reader hunting a bug that is not there (it sent
     * ME hunting one). Only when the id holding the samples is NOT a live registered strap is the #1193
     * split the remaining explanation.
     *
     * That correction then over-corrected. "So this is expected" assumes a night is worn on ONE strap,
     * and a reporter wearing a 4.0 and a 5.0 together hit the case it denies: the active strap banked
     * nothing because its handshake never completed (#1635), while the other strap's rows made the line
     * declare the silence normal. Nothing available here can tell the two apart — the wearer knows which
     * straps were on the wrist and this function cannot — so it states the fork instead of picking a
     * side, and names the sync as what to check in the half where something IS wrong.
     *
     * Pure so the wording is unit-tested without a database, a strap, or a registry.
     */
    internal fun orphanedSamplesLine(
        activeId: String,
        othersWithSamples: List<Pair<String, Int>>,
        otherLiveStrapIds: Set<String> = emptySet(),
    ): String {
        if (othersWithSamples.isEmpty()) {
            return "(no raw biometric samples under '$activeId' for this night — expected on a freshly " +
                "re-added strap; reconnect + let a history sync run, then re-export)"
        }
        val ownedByAnotherStrap = othersWithSamples.filter { it.first in otherLiveStrapIds }
        if (ownedByAnotherStrap.isNotEmpty()) {
            val who = ownedByAnotherStrap
                .sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first })
                .joinToString(", ") { "'${it.first}' (${it.second} rows)" }
            return "(no raw biometric samples under the ACTIVE id '$activeId' for this night — they are " +
                "under $who, another registered strap. If you wore THAT strap this night, this is expected " +
                "and the dayOwner line for this date names the owner. If you wore BOTH, the active strap " +
                "banked nothing for this night and its sync is what to check, not this line.)"
        }
        // Tie-break on id: Kotlin's sortedByDescending is stable but Swift's `sorted` is NOT, so equal
        // counts could otherwise order differently on the two platforms and the twin lines would diverge.
        // The tie-break itself compares UTF-16 code units here and Unicode canonical order in Swift; those
        // agree for the machine-generated ASCII ids this ever sees ("my-whoop", "whoop-<mac>"), and a
        // device NICKNAME is a separate field that never reaches this id.
        val named = othersWithSamples
            .sortedWith(compareByDescending<Pair<String, Int>> { it.second }.thenBy { it.first })
            .joinToString(", ") { "'${it.first}' (${it.second} rows)" }
        return "(no raw biometric samples under the ACTIVE id '$activeId' for this night — they are under " +
            "$named instead. The history spine and the raw stream are on different device ids (#1193); this " +
            "is NOT a fresh re-add, the samples exist and are not being read.)"
    }
}
