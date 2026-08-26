import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Strap & data-state + analytics-funnel lines appended to the iOS debug export — the twin of Android's
/// `AndroidDiagnostics.strapAndDataLines` + `funnelLines`. Best-effort and self-reporting: every section is
/// guarded so a header build never throws, and the funnels print the sample counts they read and say plainly
/// when they can't compute, so a shared log never carries a fabricated verdict.
///
/// Two entry points, matching the two export paths:
///   • `strapStateLines()` — SYNC, offline-safe (persisted defaults + timezone). Usable from the scheduled
///     background export, which has no `Repository`.
///   • `dynamicLines(repo:)` — ASYNC, the full block (strap state + data spine + recomputed funnels for the
///     latest night). Used by the interactive "Save…/Share log" buttons, which hold `model.repo`.
enum DebugDataDiagnostics {

    /// Aux rows read for one night's SpO₂-candidate line (#112). Explicit rather than the store default
    /// so the Kotlin twin can state the SAME number — a night is ~30k rows at 1 Hz, so this is slack.
    static let spo2CandidateAuxLimit = 200_000


    /// Strap identity + timezone from persisted defaults (sync, offline-safe). Mirrors the prefs-backed
    /// portion of the Android strap-state block; keys match the iOS @AppStorage / persisted values.
    static func strapStateLines() -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Strap & data")
        let d = UserDefaults.standard
        // Parse through the enum, never against string literals. `selectedWhoopModel` stores
        // `WhoopModel.rawValue` ("WHOOP 4.0" / "WHOOP 5.0 / MG") — both writers use `.rawValue` — but this
        // switch tested for "whoop5"/"whoop4", which are the CASE names, not the raw values. Neither ever
        // matched, so this header reported "unknown (never paired)" for every strap, forever, including one
        // actively syncing. The sibling block ~270 lines below already compares `.rawValue` and carries a
        // comment warning about this exact trap; this site never got the same treatment. Going through
        // `WhoopModel(rawValue:)` makes the enum the single parser, so a future rename cannot re-open it.
        let model = WhoopModel(rawValue: d.string(forKey: "selectedWhoopModel") ?? "")?.displayName
            ?? "unknown (never paired)"
        lines.append("Model:       \(model)")
        // NOTE: still the legacy GLOBAL key, and therefore the last strap to connect rather than this
        // device's own firmware. strapStateLines is sync and prefs-only by contract (the scheduled export
        // calls it with no store), and the per-device rule needs a registry read for pairedCount. The
        // Devices block further down IS resolved per device, so a multi-strap export carries the correct
        // per-device value there; this line is superseded by it and wants the same follow-up as the Apple
        // write site, which has no peripheral identity to key on today.
        lines.append("Firmware:    \(d.string(forKey: "noop.lastFirmware") ?? "unknown (connect to record)")")
        let syncSec = d.double(forKey: "lastSyncedAt")
        lines.append("Last sync:   \(syncSec > 0 ? relTime(Date().timeIntervalSince1970 - syncSec) : "never")")
        // #57: write-health. "Last sync" fires even on an empty/failed offload, so distinguish "rows
        // actually landed" from "an offload STALLED on a persist failure" (history won't persist — usually a
        // backup restored without an app restart, the closed-store class).
        let now = Date().timeIntervalSince1970
        let okAt = d.double(forKey: "sync.lastWriteOkAt")
        let stalledAt = d.double(forKey: "sync.lastWriteStalledAt")
        let restoreAt = d.double(forKey: "backup.lastRestoreAt")
        lines.append("Data write:  \(okAt > 0 ? "rows last landed \(relTime(now - okAt))" : "no rows ever persisted")")
        if stalledAt > 0, stalledAt >= okAt {
            lines.append("             ⚠ history NOT persisting — last offload STALLED \(relTime(now - stalledAt)) "
                + "(if you restored a backup, fully restart the app — #57)")
        }
        if restoreAt > 0 { lines.append("Last restore: \(relTime(now - restoreAt))") }
        #if os(iOS)
        // #52: iOS Backup & Sync folder-picker health. When users report "won't let me pick a folder",
        // this pins the failure stage: "cancelled"/"never used" ⇒ the picker's Open button never fired
        // (an iOS-side picker issue — the in-app "Use NOOP's own folder" fallback sidesteps it);
        // "picked" + a FAILED flag ⇒ a returned folder failed to bookmark HERE (our bug).
        let pickEvent = d.string(forKey: "backupPicker.lastEvent") ?? "never used"
        let pickAt = d.double(forKey: "backupPicker.lastEventAt")
        lines.append("Folder picker: \(pickEvent)\(pickAt > 0 ? " (\(relTime(now - pickAt)))" : "")")
        if pickEvent == "picked" {
            let scoped = d.bool(forKey: "backupPicker.lastScopedOpen")
            let bmOk = d.bool(forKey: "backupPicker.lastBookmarkOk")
            lines.append("             scoped-access \(scoped ? "ok" : "FAILED"), bookmark \(bmOk ? "ok" : "FAILED")")
        }
        lines.append("Backup mode:  \(FolderBackup.useInternalFolder ? "NOOP's own folder (#52 fallback)" : (FolderBackup.hasFolder ? "external folder" : "none chosen"))")
        #endif
        #if os(macOS)
        // #278: macOS Backup & Sync restore-list health. When a user reports "restore shows no files",
        // this pins whether a folder is even configured and whether its raw entries are being recognized
        // as backups — a folder with real snapshots but 0 recognized (e.g. an undownloaded iCloud Drive
        // placeholder, see `BackupSync.iCloudPlaceholderRealName`) looks very different from a genuinely
        // empty folder, and neither was visible in a debug export before this.
        if let health = FolderBackup.restoreListHealth() {
            lines.append("Backup folder: \(health.isICloud ? "iCloud Drive" : "local")")
            lines.append("Restore list: \(health.snapshots) snapshot(s) recognized of \(health.rawEntries) folder entries")
        } else {
            lines.append("Backup folder: none chosen")
        }
        #endif
        lines.append("Timezone:    \(tzLine())")
        return lines
    }

    /// The full dynamic block: strap state + data spine (preloaded `repo.days`) + the REM/skin-temp funnels
    /// recomputed for the most recent night. Async — it reads the on-device store. Never throws.
    @MainActor static func dynamicLines(repo: Repository) async -> [String] {
        var lines = strapStateLines()

        // Data state from the preloaded day spine.
        let days = repo.days
        lines.append("History:     \(days.count) day rows")
        if let s = days.last(where: { ($0.totalSleepMin ?? 0) > 0 }) {
            lines.append("Last sleep:  \(s.day) · \(Int(s.totalSleepMin ?? 0)) min")
        } else { lines.append("Last sleep:  none") }
        if let r = days.last(where: { $0.recovery != nil }) {
            lines.append("Last recov.: \(r.day) · \(Int(r.recovery ?? 0))%")
        } else { lines.append("Last recov.: none") }
        // #1300 follow-up: the header above describes ONE device because it reads the last-connected
        // prefs, not the registry — so a two-strap install produced a log that never mentioned the
        // second strap, leaving `dayOwner readId=` and the funnel's orphan check with nothing to be
        // checked against. Name the whole set instead.
        // `store` is fetched further down for the funnels; take a handle here rather than moving this
        // block below the funnel header, so the inventory prints beside the strap identity it qualifies —
        // the same position it holds on Android.
        if let invStore = await repo.storeHandle() {
            let invRegistry = DeviceRegistryStore(dbQueue: invStore.registryWriter)
            // Bound before the map so the rule below has a count to test. Reading `.all()` inline left
            // nothing to reference, which app-build caught and no local check could — this file needs
            // macOS to compile.
            let invDevices = (try? invRegistry.all()) ?? []
            let invRows = invDevices.map {
                // Firmware resolved by the same rule as the Devices card: this device's own persisted
                // value when there is one, and the LEGACY global key only when a single device is paired
                // (it cannot have come from anything else). Apple does not yet write the per-device key —
                // the write site has no peripheral identity to key on — so today this yields the global
                // value for a single-strap install and "unknown" for a multi-strap one, which is honest
                // rather than another strap's number.
                InventoryRow(id: $0.id, brand: $0.brand, model: $0.model,
                             status: $0.status.rawValue, lastSeenAt: $0.lastSeenAt,
                             firmware: FirmwareAttribution.resolve(
                                 live: nil,
                                 perDevice: FirmwareAttribution.prefKey(peripheralId: $0.peripheralId)
                                     .flatMap { UserDefaults.standard.string(forKey: $0) },
                                 legacyGlobal: UserDefaults.standard.string(forKey: "noop.lastFirmware"),
                                 pairedCount: invDevices.count))
            }
            let invActive = (try? invRegistry.activeDeviceId()) ?? nil
            lines.append(contentsOf: deviceInventoryLines(rows: invRows,
                                                          activeId: invActive,
                                                          nowSec: Int(Date().timeIntervalSince1970),
                                                          relTime: { relTime($0) }))
        }

        // Workout & imported-activity source breakdown (#28/#29 "counted but not shown" class). Runs BEFORE
        // the funnels since those can early-return, so this always lands in the export.
        lines += await workoutSourceLines(repo: repo)
        lines += await dailyDataLines(repo: repo)
        lines += alarmLines()

        // Funnels for the latest night — best-effort, self-reporting.
        lines.append(String(repeating: "─", count: 40))
        lines.append("Analytics funnels (latest night, best-effort)")
        let nowSec = Int(Date().timeIntervalSince1970)
        guard let store = await repo.storeHandle() else {
            lines.append("(on-device store not open yet)")
            return lines
        }
        let did = repo.deviceId
        // Pick the MOST RECENT night that actually carries skin-temp — not the OLDEST in the window. The old
        // `sleepSessions(…, limit: 1).last` returned the oldest session (ASC order), so a fresh gap night read
        // "skin=0" and the funnel never saw a real night. Walk newest→oldest and stop at the first with skin.
        var recent = await repo.sleepSessions(from: nowSec - 14 * 86400, to: nowSec, limit: 200)
        if recent.isEmpty {
            // #1150: a Bluetooth-only strap (no WHOOP/Apple import) banks every night under the COMPUTED
            // "-noop" source, so the imported union above is empty and the funnel reported "no session in
            // 14 days" for a 4.0 user whose nights are all computed — even though computed session rows
            // exist. Fall back to the computed sessions so a real night is analysed. Only on an empty
            // imported read ⇒ a mixed/imported install's funnel is byte-unchanged. Mirrors Android funnelLines.
            recent = await repo.computedSleepSessions(from: nowSec - 14 * 86400, to: nowSec, limit: 200)
        }
        // `.last`/`.reversed()` below assume ASC-by-onset order. The imported union concatenates per-id
        // blocks and is NOT globally sorted for a multi-id (re-added strap + canonical) install, so sort
        // here — else `.last` can pick a non-newest night, and the pick would diverge from Android, which
        // sorts explicitly. A single-source read is already ASC, so this is a no-op there.
        recent.sort { $0.startTs < $1.startTs }
        guard let newest = recent.last else {
            lines.append("(no sleep session in the last 14 days to analyze)")
            return lines
        }
        var cs = newest
        var skin: [SkinTempSample] = []
        for s in recent.reversed() {
            let sk = (try? await store.skinTempSamples(deviceId: did, from: s.startTs, to: s.endTs, limit: 200_000)) ?? []
            if !sk.isEmpty { cs = s; skin = sk; break }
        }
        let grav = (try? await store.gravitySamples(deviceId: did, from: cs.startTs, to: cs.endTs, limit: 200_000)) ?? []
        let hr = await repo.hrSamples(from: cs.startTs, to: cs.endTs, limit: 200_000)
        let rr = (try? await store.rrIntervals(deviceId: did, from: cs.startTs, to: cs.endTs, limit: 200_000)) ?? []
        let resp = (try? await store.respSamples(deviceId: did, from: cs.startTs, to: cs.endTs, limit: 200_000)) ?? []
        lines.append("Night \(dayStamp(cs.startTs)): grav=\(grav.count) hr=\(hr.count) rr=\(rr.count) resp=\(resp.count) skin=\(skin.count)")
        if grav.isEmpty && hr.isEmpty {
            // #1617 follow-up: do NOT assert "freshly re-added" without testing the other explanation.
            // Several ids can hold one physical strap's data (#1193/#740), and when the history spine and
            // the raw stream split, the samples exist - just under a different id. The old line printed the
            // innocent cause for that case, which stops the investigation at exactly the point it should
            // start. Ask the SAMPLE TABLES, not the registry: `my-whoop` is a source label rather than a
            // `pairedDevice` row, and forgetting a device drops its row while leaving its samples - so the
            // registry is blind to exactly the ids worth naming here. Only runs when the active id came
            // back empty, so a healthy install pays nothing.
            let elsewhere = ((try? await store.rawSampleCountsByDevice(from: cs.startTs, to: cs.endTs)) ?? [])
                .filter { $0.0 != did }
            // The registry, so a SECOND strap's night is not reported as a read failure. Only read when
            // the active id came back empty, so a healthy install still pays nothing.
            let otherStraps = Set(
                ((try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? [])
                    .filter { $0.status != .archived && $0.id != did }
                    .map(\.id))
            lines.append(orphanedSamplesLine(activeId: did, othersWithSamples: elsewhere,
                                             otherLiveStrapIds: otherStraps))
            return lines
        }
        if let rem = SleepStager.remFunnelDiagnostic(start: cs.startTs, end: cs.endTs, grav: grav, hr: hr, rr: rr, resp: resp) {
            lines.append(rem.summary)
        } else {
            lines.append("REM funnel: insufficient motion data (<2 gravity samples)")
        }
        let det = SleepSession(start: cs.startTs, end: cs.endTs, efficiency: cs.efficiency ?? 0,
                               stages: [], restingHR: cs.restingHr, avgHRV: cs.avgHrv)
        // Third instance of the same literal bug in this file: "whoop5" is the enum CASE name, while the
        // pref stores `WhoopModel.rawValue` ("WHOOP 5.0 / MG"). It never matched, so this resolved to
        // `.whoop4` for EVERY strap — and unlike the two header sites, that is not a label. It picks the
        // WHOOP-4 device anchor and runs `skinTempFunnel` under the wrong family, so the skin-temp funnel
        // diagnostic has been reporting 4.0 numbers for every 5/MG on Apple. Parse through the enum.
        // Unknown still resolves to `.whoop4`: this chooses an analysis default, matching the Kotlin twin.
        let family: DeviceFamily =
            WhoopModel(rawValue: UserDefaults.standard.string(forKey: "selectedWhoopModel") ?? "") == .whoop5mg
            ? .whoop5 : .whoop4
        // Mirror the real per-device anchor (#404): learn it from the WHOLE recent window's raws — not just
        // this night — so a single sparse night (<100 in-band) can't misreport under the global fallback when
        // the window as a whole has enough in-band samples for analyzeDay to learn a device anchor.
        let windowSkin = (try? await store.skinTempSamples(deviceId: did, from: nowSec - 14 * 86400, to: nowSec, limit: 200_000)) ?? []
        let devAnchor = family == .whoop4 ? Whoop4SkinTemp.deviceAnchorRaw(windowSkin.map { $0.raw }) : nil
        lines.append(AnalyticsEngine.skinTempFunnel([det], hr: hr, skinTemp: skin,
                                                    family: family, anchorRaw: devAnchor).summary)

        // #112/#103 — the 5/MG SpO2 CANDIDATE (@82), as one number a wearer can check against the figure
        // the WHOOP app reports for the same night. The candidate cannot be promoted while two straps
        // disagree about it, and the only way to read it until now was to scroll the Deep Timeline and
        // eyeball it — which is not an instrument to hand a volunteer. Diagnostic only: nothing scores
        // this, and it is NOT a blood-oxygen reading. Absent on a WHOOP 4.0, which carries raw red/IR ADC
        // and no candidate at all — said explicitly so a 4.0 owner is not left wondering.
        //
        // The read is NOT collapsed to `?? []`. A failed read and a night with no candidate are different
        // facts, and this is a diagnostic — printing "no in-band readings" because the query threw would
        // be a confident false statement in the one place whose whole job is to say what is actually
        // there. Same distinction as the imported-water and caffeine read gates (#949).
        let auxRead = try? await store.v18AuxSamples(deviceId: did, from: cs.startTs, to: cs.endTs,
                                                     limit: spo2CandidateAuxLimit)
        if auxRead == nil {
            lines.append("SpO₂ candidate @82: could not read the aux stream for this night — "
                         + "a read failure, NOT an absence of readings.")
        } else if let cand = AnalyticsEngine.nightlySpo2CandidateMean([det], aux: auxRead ?? []) {
            lines.append("SpO₂ candidate @82 (5/MG): mean \(cand.mean) over \(cand.samples) in-band readings "
                         + "— UNVERIFIED, compare against the WHOOP app's figure for this night (#103).")
        } else if family == .whoop5 {
            lines.append("SpO₂ candidate @82 (5/MG): no in-band readings inside this night's span.")
        } else {
            lines.append("SpO₂ candidate @82: not carried by a WHOOP 4.0 (raw red/IR ADC only).")
        }
        return lines
    }

    /// Workout & imported-activity source breakdown: the resolved active deviceId + a per-source STORED
    /// workout count + the most-recent workout, so a "workouts not showing" report reveals WHERE workouts
    /// live vs what the Workouts screen loads (#28 strap↔my-whoop, #29 activity-file). Best-effort.
    @MainActor static func workoutSourceLines(repo: Repository) async -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Workouts by source")
        let did = repo.deviceId
        lines.append("Active deviceId: \(did)\(did == "my-whoop" ? "" : "  (imports + spine under my-whoop)")")
        guard let store = await repo.storeHandle() else {
            lines.append("(on-device store not open yet)")
            return lines
        }
        let nowSec = Int(Date().timeIntervalSince1970)
        var seen = Set<String>()
        let ids = [did, "my-whoop", "\(did)-noop", "my-whoop-noop",
                   "activity-file", "lifting", "apple-health", "health-connect"].filter { seen.insert($0).inserted }
        var parts: [String] = []
        var latestTs = -1
        var latestDesc = ""
        for id in ids {
            let rows = (try? await store.workouts(deviceId: id, from: 0, to: nowSec, limit: 100_000)) ?? []
            parts.append("\(id)=\(rows.count)")
            if let m = rows.max(by: { $0.startTs < $1.startTs }), m.startTs > latestTs {
                latestTs = m.startTs
                latestDesc = "\(dayStamp(m.startTs)) · \(m.sport) (\(m.source))"
            }
        }
        lines.append("Stored: " + parts.joined(separator: "  "))
        lines.append(latestTs >= 0 ? "Latest: \(latestDesc)" : "Latest: none")
        return lines
    }

    /// Daily-data source breakdown + on-device volume: per-source day counts, which metrics are populated
    /// over the recent week on the imported spine, and the raw-row footprint — the same source reconciliation
    /// the workout block gives, for the "no data / no steps / 0% REM" report class. Best-effort.
    @MainActor static func dailyDataLines(repo: Repository) async -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Daily data by source")
        let did = repo.deviceId
        guard let store = await repo.storeHandle() else {
            lines.append("(on-device store not open yet)")
            return lines
        }
        var seen = Set<String>()
        let ids = [did, "my-whoop", "\(did)-noop", "my-whoop-noop",
                   "apple-health", "health-connect"].filter { seen.insert($0).inserted }
        var parts: [String] = []
        var spine: [DailyMetric] = []
        var activeRows: [DailyMetric] = []
        var computedActive: [DailyMetric] = []
        var computedSpine: [DailyMetric] = []
        for id in ids {
            let rows = (try? await store.dailyMetrics(deviceId: id, from: "0000-01-01", to: "9999-12-31")) ?? []
            parts.append("\(id)=\(rows.count)")
            if id == "my-whoop" { spine = rows }
            if id == did { activeRows = rows }
            if id == "\(did)-noop" { computedActive = rows }
            if id == "my-whoop-noop" { computedSpine = rows }
        }
        lines.append("Days: " + parts.joined(separator: "  "))
        // #731: this line used to read ONLY "my-whoop" and label it "Recent 7d". For a live-BLE user whose
        // rows land under the ACTIVE strap id that reported sleep=0/7 while every one of the last 7 nights
        // had sleep — it sent triage hunting for missing data that was never missing. It also took
        // `suffix(7)` of that id's rows, so "Recent" could be the last 7 IMPORTED days (months old) rather
        // than the last 7 calendar days. Report the active id (where live data lands) AND the import spine
        // when they differ, each stamped with the day range it actually covers so staleness is visible.
        func recentLine(_ rows: [DailyMetric], id: String) -> String? {
            let recent = Array(rows.suffix(7))
            guard !recent.isEmpty else { return nil }
            let n = recent.count
            let span = (recent.first?.day ?? "?") + "…" + (recent.last?.day ?? "?")
            return "Recent \(n) rows (\(id), \(span)): "
                + "sleep=\(recent.filter { ($0.totalSleepMin ?? 0) > 0 }.count)/\(n)  "
                + "recovery=\(recent.filter { $0.recovery != nil }.count)/\(n)  "
                + "steps=\(recent.filter { $0.steps != nil }.count)/\(n)  "
                + "kcal=\(recent.filter { $0.activeKcalEst != nil }.count)/\(n)"
        }
        var emitted = false
        if let l = recentLine(activeRows, id: did) { lines.append(l); emitted = true }
        if did != "my-whoop", let l = recentLine(spine, id: "my-whoop") { lines.append(l); emitted = true }
        // The COMPUTED "-noop" spine, where steps/activeKcalEst are actually written — compare with the raw
        // lines above: kcal/steps populated here but 0 there ⇒ the raw merge/view drops them (cosmetic); 0 on
        // BOTH ⇒ genuinely not computed (a real gap). Mirrors the Android twin.
        if let l = recentLine(computedActive, id: "\(did)-noop") { lines.append(l); emitted = true }
        if did != "my-whoop", let l = recentLine(computedSpine, id: "my-whoop-noop") { lines.append(l); emitted = true }
        if !emitted {
            lines.append("Recent: no day rows")
        }
        if let dv = await repo.dataVolumeSnapshot() {
            lines.append("Volume: rawRows=\(dv.dbRows)  importedDays=\(dv.importedDays)  workouts=\(dv.workouts)")
        }
        return lines
    }

    /// Alarm state for the debug export: the configured wake + the last arm's sent-vs-strap-reports (#34), so
    /// a "didn't buzz" report shows at a glance whether the strap accepted the time. Reads persisted defaults
    /// (written by BLEManager.armStrapAlarm + the FrameRouter readback); sync + guarded.
    static func alarmLines() -> [String] {
        var lines: [String] = []
        lines.append(String(repeating: "─", count: 40))
        lines.append("Alarm")
        let d = UserDefaults.standard
        let on = d.bool(forKey: "behavior.smartAlarmEnabled")
        let mins = (d.object(forKey: "behavior.smartAlarmMinutes") as? Int) ?? 7 * 60
        lines.append("Enabled: \(on ? "yes" : "no") · set \(String(format: "%02d:%02d", mins / 60, mins % 60))")
        // #3: model + the 5/MG experimental gate — a 5/MG firmware alarm is NOT armed unless Experimental is on.
        // (selectedWhoopModel stores the WhoopModel rawValue — "WHOOP 5.0 / MG" / "WHOOP 4.0" — not "whoop5".)
        // Same rule as the header above: parse through the enum, and ABSTAIN when nothing is known. This
        // defaulted to `whoop4.rawValue`, so an unknown family was reported as a WHOOP 4.0 — the very
        // fabrication this change removes on Android, and it would have left the two platforms disagreeing
        // about the one case that matters. Three arms, mirroring the Kotlin `when`.
        switch WhoopModel(rawValue: d.string(forKey: "selectedWhoopModel") ?? "") {
        case .whoop5mg:
            lines.append("Model: \(WhoopModel.whoop5mg.displayName) · experimental: \(PuffinExperiment.isEnabled ? "on" : "off → firmware alarm NOT armed")")
        case .whoop4:
            lines.append("Model: \(WhoopModel.whoop4.displayName)")
        case nil:
            lines.append("Model: unknown (family not yet detected)")
        }
        // #4 / #67: strap clock health — a reset/stale OR future-dated clock (the #34 / #928 causes) breaks
        // the alarm even when armed, AND misdates offloaded sleep: the strap banks last night with its wrong
        // RTC, so the night lands on the stale date and reads as "missed sleep" on the recent timeline (#67).
        if let newest = d.object(forKey: "strap.newestRecordTs") as? Int, newest > 0 {
            let behind = Int(Date().timeIntervalSince1970) - newest
            if behind > 3 * 86400 {
                lines.append("Strap clock: \(behind / 86400)d behind wall (reset/stale — alarm unreliable; recent sleep may be filed ~\(behind / 86400)d in the past, #67)")
            } else if behind < -3 * 86400 {
                lines.append("Strap clock: \(-behind / 86400)d AHEAD of wall (future-dated — alarm unreliable; recent sleep may be misdated, #67)")
            } else {
                lines.append("Strap clock: OK")
            }
        }
        if let sent = d.object(forKey: "alarm.lastArmSentEpoch") as? Int {
            var line = "Last arm: sent \(alarmStamp(sent))"
            if let at = d.object(forKey: "alarm.lastArmAt") as? Double {
                line += " · \(relTime(Date().timeIntervalSince1970 - at))"
            }
            if !d.bool(forKey: "alarm.lastArmConnected") { line += " · strap NOT connected (queued)" }
            // #34: the strap-clock skew AT ARM. Skew ~0 but the strap still rejects ⇒ a corrupted alarm
            // register, not a clock problem (which pins whether a re-clock could ever help).
            if let skew = d.object(forKey: "alarm.lastArmClockSkew") as? Int, abs(skew) > 3600 {
                let mag = abs(skew) >= 86400 ? "\(skew / 86400)d" : "\(skew / 3600)h"
                line += " · strap clock at arm \(skew > 0 ? "+" : "")\(mag)"
            }
            // #34: live HR at arm, logged only to test whether the strap's own sleep/rest detection (not
            // anything NOOP sends) gates the physical haptic — see the doc comment on recordAlarmArm.
            if let hr = d.object(forKey: "alarm.lastArmHeartRate") as? Int {
                line += " · HR \(hr) bpm at arm"
            }
            lines.append(line)
            if let reported = d.object(forKey: "alarm.lastReportedEpoch") as? Int {
                let mismatch = abs(reported - sent) > 120
                var rline = "Strap reports: \(alarmStamp(reported))"
                    + (mismatch ? "  ⚠️ MISMATCH — strap didn't accept the time" : "  ✓ matches")
                // #34: consecutive rejections — a persistent refusal (vs a one-off) points at a strap whose
                // alarm register needs a reset, and is what SmartAlarmView warns the user about at ≥2.
                let streak = d.integer(forKey: "alarm.rejectStreak")
                if streak >= 2 { rline += " · \(streak) in a row (register likely needs a reset, #34)" }
                lines.append(rline)
            } else {
                lines.append("Strap reports: (no readback)")
            }
        } else {
            lines.append("Last arm: never")
        }
        // #1: did the strap actually fire? (STRAP_DRIVEN_ALARM_EXECUTED)
        if let firedAt = d.object(forKey: "alarm.lastFiredAt") as? Double {
            lines.append("Last fired: \(relTime(Date().timeIntervalSince1970 - firedAt))")
        } else {
            lines.append("Last fired: never observed")
        }
        return lines
    }

    private static func alarmStamp(_ epochSec: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epochSec)))
    }

    // MARK: - Formatting helpers

    private static func relTime(_ deltaSec: Double) -> String {
        if deltaSec < 60 { return "just now" }
        let min = Int(deltaSec / 60)
        switch true {
        case min < 60:   return "\(min)m ago"
        case min < 1440: return "\(min / 60)h \(min % 60)m ago"
        default:         return "\(min / 1440)d ago"
        }
    }

    private static func tzLine() -> String {
        let tz = TimeZone.current
        let offMin = tz.secondsFromGMT() / 60
        let a = abs(offMin)
        return "\(tz.identifier) (UTC\(offMin >= 0 ? "+" : "-")\(a / 60):\(String(format: "%02d", a % 60)))"
    }

    private static func dayStamp(_ epochSec: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epochSec)))
    }

    /// #1617 follow-up: the line the night funnel prints when the ACTIVE device id carries no raw samples.
    ///
    /// The previous wording asserted "expected on a freshly re-added strap" unconditionally. That is one of
    /// two explanations, and the other one is a bug: a registry can hold several ids for the same physical
    /// strap (#1193/#740), and when the history spine and the raw stream split, the samples are present -
    /// just filed under a different id. Printing the innocent cause for that case ends the investigation at
    /// the point it should begin, which is worse than printing nothing.
    ///
    /// `othersWithSamples` is (deviceId, sampleCount) for every OTHER registry id that does hold samples in
    /// the same window. Empty means the samples genuinely are not there and the fresh-re-add wording is
    /// right; non-empty names the id that has them so the split is visible rather than inferred.
    ///
    /// Pure so the wording is unit-tested without a database, a strap, or a registry. Kotlin twin:
    /// `com.noop.testcentre.orphanedSamplesLine`.
    /// `otherLiveStrapIds` is the registered, non-archived device ids OTHER than the active one. It exists
    /// because the "not being read" wording was itself an over-assertion — the mirror image of the one it
    /// replaced. A wearer with TWO straps has nights owned by the other one, and `DayOwnerResolver` hands
    /// each day to whichever device actually holds its data. Samples under another id are then completely
    /// normal, and calling that a read failure sends the reader hunting a bug that is not there. Only when
    /// the id holding the samples is NOT a live registered strap is the #1193 split the explanation left.
    static func orphanedSamplesLine(activeId: String, othersWithSamples: [(String, Int)],
                                    otherLiveStrapIds: Set<String> = []) -> String {
        if othersWithSamples.isEmpty {
            return "(no raw biometric samples under '\(activeId)' for this night — expected on a freshly "
                + "re-added strap; reconnect + let a history sync run, then re-export)"
        }
        let ownedByAnotherStrap = othersWithSamples.filter { otherLiveStrapIds.contains($0.0) }
        if !ownedByAnotherStrap.isEmpty {
            let who = ownedByAnotherStrap.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .map { "'\($0.0)' (\($0.1) rows)" }
                .joined(separator: ", ")
            return "(no raw biometric samples under the ACTIVE id '\(activeId)' for this night — they are "
                + "under \(who), another registered strap. A night worn on a different strap is OWNED by that "
                + "strap, so this is expected; the dayOwner line for this date names the owner.)"
        }
        // Tie-break on id: Kotlin's sortedByDescending is stable but Swift's `sorted` is NOT, so equal
        // counts could otherwise order differently on the two platforms and the twin lines would diverge.
        // The tie-break itself compares Unicode canonical order here and UTF-16 code units in Kotlin; those
        // agree for the machine-generated ASCII ids this ever sees ("my-whoop", "whoop-<mac>"), and a
        // device NICKNAME is a separate field that never reaches this id.
        let named = othersWithSamples.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .map { "'\($0.0)' (\($0.1) rows)" }
            .joined(separator: ", ")
        return "(no raw biometric samples under the ACTIVE id '\(activeId)' for this night — they are under "
            + "\(named) instead. The history spine and the raw stream are on different device ids (#1193); this "
            + "is NOT a fresh re-add, the samples exist and are not being read.)"
    }
}
