import Foundation
import UserNotifications
import StrandAnalytics

/// Surfaces the strap battery state as a user notification — a LOW warning when the cell falls to
/// the threshold so the user can top up before tonight's sleep, and a CHARGED note when it reaches
/// 100%. Mirrors `IllnessNotifier`: requestAuthorization() up front when the toggle is enabled,
/// status-only check at fire time, and the persisted gate advances even when delivery is deferred.
/// On-device only; gated behind the user's "Battery alerts" setting (default ON) by the caller (#368).
enum BatteryNotifier {
    private static let lowAlertedKey = "behavior.batteryLowAlerted"
    private static let fullAlertedKey = "behavior.batteryFullAlerted"
    private static let runtimeAlertedKey = "behavior.batteryRuntimeAlerted"
    /// Gates for the two ESCALATION alerts. Separate keys on purpose — see `onCriticalBattery` /
    /// `onBedtimeRunway`: a latched `lowAlertedKey`/`runtimeAlertedKey` must never silence them.
    private static let criticalAlertedKey = "behavior.batteryCriticalAlerted"
    private static let bedtimeAlertedKey = "behavior.batteryBedtimeAlerted"

    /// The banked reading `onStrapNotSeen` last warned about, as its epoch SECONDS (#2556). Keyed on the
    /// reading rather than a flag so one stale value cannot re-notify on every wake, while a NEWER low
    /// reading still counts as a new fact. Absent means never.
    private static let staleAlertedTsKey = "behavior.batteryStaleAlertedTs"

    /// Whether a strap NOBODY has heard from is worth warning about (#2556).
    ///
    /// `BatteryAlertPolicy` can only judge a percentage the app actually received, and both its crossings
    /// run off the live connection, so a strap that drains while disconnected crosses 15 and 12 unseen and
    /// the wearer gets nothing. That is not hypothetical on an unbonded 5/MG, where a link can average under
    /// two minutes.
    ///
    /// This reads the LAST BANKED reading instead, which is already durable in the `battery` table. It
    /// therefore states something weaker and must say so: "last seen at 11 percent, six hours ago", never
    /// "your strap is at 11 percent". The app has not seen the strap since; it does not know what it is at
    /// now.
    ///
    /// Deliberately silent while connected: the live crossings own that case, and two readouts of one fact
    /// must not be able to disagree.
    ///
    /// Twin of Kotlin `StaleBatteryAlertPolicy`.
    enum StaleBatteryAlertPolicy {
        /// How long out of contact before a low last reading is worth raising.
        static let staleAfterSeconds = 2 * 60 * 60

        struct Decision: Equatable {
            let fire: Bool
            let ageSeconds: Int
        }

        /// How long ago, as a compact label: "6h", "3d".
        ///
        /// Deliberately plural-free. "6 hours ago" needs a plural rule in every locale to avoid printing
        /// "1 hours", and the age here is never below the two-hour window anyway, so the compact form
        /// carries the same meaning for none of the cost. Shared with the Kotlin twin so the two
        /// notifications cannot word the same fact differently.
        static func ageLabel(_ seconds: Int) -> String {
            let hours = seconds / 3600
            return hours >= 48 ? "\(hours / 24)d" : "\(hours)h"
        }

        private static let no = Decision(fire: false, ageSeconds: 0)

        /// `alertedForTs` is the reading this already fired for, persisted, so one stale value cannot
        /// re-notify on every app open. Keyed on the READING's timestamp rather than a boolean: a newer low
        /// reading is a new fact and deserves its own alert.
        static func evaluate(lastSocPct: Int?,
                             lastTsSec: Int?,
                             lastCharging: Bool?,
                             nowSec: Int,
                             connected: Bool,
                             alertedForTs: Int?,
                             lowThreshold: Int = BatteryAlertPolicy.lowThreshold,
                             staleAfterSeconds: Int = staleAfterSeconds) -> Decision {
            if connected { return no }
            guard let lastSocPct, let lastTsSec else { return no }
            // Only a CONFIRMED charging reading suppresses, matching the live policy: unknown still warns.
            if lastCharging == true { return no }
            if lastSocPct > lowThreshold { return no }
            let age = nowSec - lastTsSec
            // A reading from the future is a clock problem, not a stale strap. Never warn on it.
            if age < staleAfterSeconds { return no }
            if alertedForTs == lastTsSec { return no }
            return Decision(fire: true, ageSeconds: age)
        }
    }

    /// Pure crossing-with-hysteresis policy, identical on macOS/iOS and Android (#368). The two
    /// `*Alerted` flags are PERSISTED, so they survive process death — and the 25% re-arm band means
    /// a 14↔15% jitter fires the low alert exactly once per discharge cycle (no in-memory prevPct
    /// crossing that re-fires on every bounce and resets on restart). Full re-arms only below 100.
    enum BatteryAlertPolicy {
        static let lowThreshold = 15
        static let lowRearmAbove = 25
        static let fullThreshold = 100

        /// `charging == nil` means unknown — the low alert still fires (only a confirmed `true`
        /// suppresses it). Returns the fire decisions plus the next persisted flag state.
        ///
        /// `clearFull` (#514): the strap was showing a "fully charged" notification and has now
        /// dropped below 100% — the standing note is stale, so cancel it. It's exactly the full
        /// re-arm transition (previouslyFullAlerted && pct < fullThreshold), surfaced so the
        /// notifier can pull the delivered + pending full-charge notification by its id.
        static func evaluate(pct: Int,
                             charging: Bool?,
                             lowAlerted: Bool,
                             fullAlerted: Bool)
            -> (fireLow: Bool, fireFull: Bool, clearFull: Bool, newLowAlerted: Bool, newFullAlerted: Bool) {
            var low = lowAlerted
            var full = fullAlerted
            // The stale 100%-full note must be cleared the moment we re-arm below the full line.
            let clearFull = fullAlerted && pct < fullThreshold
            // Re-arm (hysteresis) so jitter near a threshold can't re-fire. #80: re-arm ONLY on genuine
            // recovery (pct >= lowRearmAbove), NOT on charging. The strap reports its charge bit only every
            // ~8 min, so it flickers true→nil; re-arming on `true` then firing on the `nil` gap re-fired the
            // low alert repeatedly WHILE charging. `fireLow`'s `charging != true` still suppresses an explicit
            // charging reading, and a null-charging strap (generic/FTMS) still alerts.
            if pct >= lowRearmAbove { low = false }
            if pct < fullThreshold { full = false }
            // Fire at most once per genuine crossing.
            let fireLow = !low && pct <= lowThreshold && charging != true
            let fireFull = !full && pct >= fullThreshold
            if fireLow { low = true }
            if fireFull { full = true }
            return (fireLow, fireFull, clearFull, low, full)
        }
    }

    /// Ask up front (called when the user enables the alerts) so the system dialog appears at a
    /// predictable moment, not on the first low-battery crossing.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Run the policy against a fresh battery reading and post at most one notification per genuine
    /// crossing. No-op when the setting is off. The persisted flags are written back ALWAYS (so the
    /// gate advances even if the user declined notifications or delivery is deferred — mirroring how
    /// `IllnessNotifier` marks the day up front).
    static func onBatteryUpdate(pct: Int, charging: Bool?, enabled: Bool) {
        guard enabled else { return }
        let d = UserDefaults.standard
        let result = BatteryAlertPolicy.evaluate(
            pct: pct,
            charging: charging,
            lowAlerted: d.bool(forKey: lowAlertedKey),
            fullAlerted: d.bool(forKey: fullAlertedKey))
        // Advance the persisted gate up front so the once-per-crossing limit holds regardless of
        // authorization or delivery — the in-app battery surfaces stay the live view either way.
        d.set(result.newLowAlerted, forKey: lowAlertedKey)
        d.set(result.newFullAlerted, forKey: fullAlertedKey)
        if result.fireLow {
            post(identifier: "battery-low",
                 title: String(localized: "Low battery"),
                 body: String(localized: "Recharge your WHOOP before tonight."))
        }
        if result.fireFull {
            post(identifier: "battery-full",
                 title: String(localized: "Strap fully charged"),
                 body: String(localized: "Your WHOOP is at 100%."))
        }
        // #514: the strap has dropped below 100% — pull the stale "fully charged" note (delivered
        // banner + any still-pending request) so it can't linger after the cell discharges.
        if result.clearFull {
            let center = UNUserNotificationCenter.current()
            center.removeDeliveredNotifications(withIdentifiers: ["battery-full"])
            center.removePendingNotificationRequests(withIdentifiers: ["battery-full"])
        }
    }

    /// Predictive twin of `onBatteryUpdate`: run the runtime estimate against
    /// `BatteryEstimator.runtimeAlert` (fire ≤24 h, re-arm ≥36 h — see the policy for why a runtime
    /// threshold beats a fixed SoC one) and post at most one notification per discharge cycle. The
    /// 15% SoC alert stays as the safety net for straps with no usable estimate (`estimate == nil`
    /// is a no-op here). Same gating discipline as #368: the persisted flag advances even when
    /// delivery is deferred, and the whole thing no-ops when the "Battery alerts" setting is off.
    static func onRuntimeEstimate(remainingHours: Double?, charging: Bool?, enabled: Bool) {
        guard enabled, let remainingHours else { return }
        let d = UserDefaults.standard
        let result = BatteryEstimator.runtimeAlert(remainingHours: remainingHours,
                                                   charging: charging,
                                                   alerted: d.bool(forKey: runtimeAlertedKey))
        d.set(result.newAlerted, forKey: runtimeAlertedKey)
        if result.fire {
            post(identifier: "battery-runtime",
                 title: String(localized: "Strap battery low"),
                 body: String(localized: "\(BatteryEstimator.label(hours: remainingHours)) left on your WHOOP — recharge tonight."))
        }
    }

    /// CRITICAL low-battery escalation — the second alert below the 15% one (#368 fires at
    /// `BatteryAlertPolicy.lowThreshold`, this at `BatteryEstimator.criticalSocPct`).
    ///
    /// Why a whole second alert rather than a lower first threshold: on the reference incident the
    /// user's device flags show BOTH the 15% alert and the 24 h predictive alert had already fired —
    /// and both then LATCHED (`lowAlerted` until 25%, `runtimeAlerted` until a 36 h estimate). So the
    /// last ~3 h of the discharge, from 15% down to the ~10% cutoff, passed in total silence and cost
    /// a night of biometrics. This gate is independent of both: `criticalAlertedKey` is its own key, so
    /// a latched low/runtime alert cannot suppress it. Same discipline as #368 otherwise — self-gates
    /// on the setting, advances the persisted flag even when delivery is deferred, once per cycle.
    /// Warn that a strap last seen LOW has not been heard from since (#2556). Twin of Kotlin
    /// `BatteryAlertNotifier.onStrapNotSeen`.
    ///
    /// The live crossings need a connection, so a strap that drains out of range is never judged at all.
    /// This reads the last BANKED reading instead, which is why the copy says "when NOOP last heard from
    /// it" rather than naming a current percentage: the app has not seen the strap since and does not know
    /// what it is at now.
    static func onStrapNotSeen(lastSocPct: Int?,
                               lastTsSec: Int?,
                               lastCharging: Bool?,
                               nowSec: Int,
                               connected: Bool,
                               enabled: Bool) {
        guard enabled else { return }
        let d = UserDefaults.standard
        let decision = StaleBatteryAlertPolicy.evaluate(
            lastSocPct: lastSocPct,
            lastTsSec: lastTsSec,
            lastCharging: lastCharging,
            nowSec: nowSec,
            connected: connected,
            alertedForTs: d.object(forKey: staleAlertedTsKey) as? Int)
        guard decision.fire, let lastSocPct, let lastTsSec else { return }
        let age = StaleBatteryAlertPolicy.ageLabel(decision.ageSeconds)
        post(identifier: "battery-stale",
             title: String(localized: "WHOOP last seen low"),
             body: String(localized: "\(lastSocPct)% when NOOP last heard from it, \(age) ago. Charge it before tonight."),
             interruptionLevel: .timeSensitive)
        // Persisted AFTER posting, keyed on the reading, so a failed post retries on the next wake.
        d.set(lastTsSec, forKey: staleAlertedTsKey)
    }

    static func onCriticalBattery(pct: Int, charging: Bool?, enabled: Bool) {
        guard enabled else { return }
        let d = UserDefaults.standard
        let result = BatteryEstimator.criticalAlert(pct: pct,
                                                    charging: charging,
                                                    alerted: d.bool(forKey: criticalAlertedKey))
        d.set(result.newAlerted, forKey: criticalAlertedKey)
        if result.fire {
            post(identifier: "battery-critical",
                 title: String(localized: "Charge your WHOOP now"),
                 body: String(localized: "\(pct)% left. The strap stops recording near 10% — it won't capture tonight unless you charge it."),
                 interruptionLevel: .timeSensitive)
        }
    }

    /// BEDTIME night-guard — "this won't last the night", delivered while there is still time to act.
    ///
    /// Independent of `runtimeAlertedKey` by design: the generic "recharge tonight" alert may well have
    /// fired (and latched) many hours earlier — on the reference incident it fired ~18 h before the
    /// strap died. This asks a narrower, time-anchored question at the pre-bed moment, and re-arms
    /// every night rather than every charge, so it speaks even when everything else has gone quiet.
    /// `runway` is nil at cold-start (no learned bedtime) — the policy stays silent rather than
    /// inventing one.
    static func onBedtimeRunway(nowSecOfDay: Int,
                                habitualMidsleepSec: Int?,
                                typicalSleepHours: Double?,
                                usableRemainingHours: Double?,
                                charging: Bool?,
                                enabled: Bool) {
        guard enabled else { return }
        let d = UserDefaults.standard
        let result = BatteryEstimator.bedtimeAlert(nowSecOfDay: nowSecOfDay,
                                                   habitualMidsleepSec: habitualMidsleepSec,
                                                   typicalSleepHours: typicalSleepHours,
                                                   usableRemainingHours: usableRemainingHours,
                                                   charging: charging,
                                                   alerted: d.bool(forKey: bedtimeAlertedKey))
        d.set(result.newAlerted, forKey: bedtimeAlertedKey)
        if result.fire, let runway = result.runway {
            post(identifier: "battery-bedtime",
                 title: String(localized: "Won't last the night"),
                 body: String(localized: "\(BatteryEstimator.label(hours: runway.usableHours)) of recording left, but tonight needs about \(BatteryEstimator.label(hours: runway.requiredHours)). Charge before bed."),
                 interruptionLevel: .timeSensitive)
        }
    }

    private static func post(identifier: String, title: String, body: String,
                             interruptionLevel: UNNotificationInterruptionLevel = .active) {
        let center = UNUserNotificationCenter.current()
        // Authorization is requested once via requestAuthorization() when alerts are enabled; here
        // we only check status (no second system prompt).
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // The two escalation alerts ask for .timeSensitive so they can break through a sleep Focus —
            // the whole point is reaching the user in the hour before bed. Without the time-sensitive
            // entitlement the OS silently treats this as .active, so it is safe to request either way.
            content.interruptionLevel = interruptionLevel
            center.add(UNNotificationRequest(identifier: identifier,
                                             content: content, trigger: nil))
        }
    }
}
