import Foundation
import CoreBluetooth
import WhoopProtocol
import WhoopStore
import StrandAnalytics
// #78/#747 hole-4: the one-shot bond-loop salvage probe listens for the app-foreground notification,
// which lives in UIKit on iOS and AppKit on macOS (see installForegroundSalvageProbe).
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Detects a marginal Bluetooth radio that can't sustain the WHOOP 4 R10/R11 raw realtime stream
/// (#80). On a flaky radio (2016 Mac / OpenCore) the link dies the *instant* NOOP arms that
/// high-bandwidth burst, then the auto-rescan reconnects, re-arms, and dies again — an endless loop.
///
/// The tell is a CONNECTION TIMEOUT that lands shortly after we armed realtime: arm → die → rescan →
/// arm → die. We don't trip on a single drop (links die for benign reasons), but on >= `tripThreshold`
/// CONSECUTIVE arm-then-quick-timeout cycles. Once tripped, the caller skips arming R10/R11 on the next
/// connect and relies on the independent low-bandwidth 0x2A37 standard HR profile, which NOOP already
/// subscribes — live HR survives on a radio that otherwise couldn't, and even if 0x2A37 stays silent the
/// arm/die loop stops. Pure + value-typed so the decision is unit-testable without a CoreBluetooth seam.
struct MarginalRadioDetector {
    /// How many consecutive arm-then-quick-timeout cycles before we fall back to standard-HR-only.
    /// 2 (not 1): one drop is noise; two in a row right after arming is the radio buckling under the burst.
    let tripThreshold: Int
    /// A timeout only counts as "right after arming" if it lands within this window. A drop minutes into a
    /// healthy session is unrelated to the arm burst and must NOT be blamed on it (that would mis-trip a
    /// good radio whose link merely flaps later).
    let quickTimeoutWindow: TimeInterval

    private(set) var consecutiveArmTimeouts = 0
    /// True once we've tripped: the next connect should skip the R10/R11 arm and run standard-HR-only.
    private(set) var tripped = false

    init(tripThreshold: Int = 2, quickTimeoutWindow: TimeInterval = 20) {
        self.tripThreshold = tripThreshold
        self.quickTimeoutWindow = quickTimeoutWindow
    }

    /// A connection ended. `wasArmed` = we had armed R10/R11 this connection; `secondsSinceArm` = how long
    /// after arming the link ended (nil if we never armed); `timedOut` = the drop looks like a connection
    /// timeout (vs. an intentional disconnect, a bond reset, etc.). Returns true if THIS event tripped the
    /// fallback (a freshly-crossed threshold), so the caller can log/surface it exactly once.
    mutating func connectionEnded(wasArmed: Bool, secondsSinceArm: TimeInterval?, timedOut: Bool) -> Bool {
        // Only a timeout that lands within the window after we actually armed the burst is evidence the
        // radio choked on the arm. Anything else (clean session that later flapped, non-timeout error,
        // never armed) breaks the streak — a single healthy spell should clear prior suspicion.
        let armCausedTimeout = wasArmed && timedOut
            && (secondsSinceArm.map { $0 <= quickTimeoutWindow } ?? false)
        guard armCausedTimeout else {
            consecutiveArmTimeouts = 0
            return false
        }
        consecutiveArmTimeouts += 1
        if !tripped && consecutiveArmTimeouts >= tripThreshold {
            tripped = true
            return true        // freshly tripped — caller logs/surfaces once
        }
        return false
    }

    /// Clear all suspicion: a clean session is flowing, or the user explicitly re-requested the full
    /// stream (Live re-open / manual Start HR). Lets a transient radio hiccup recover instead of
    /// permanently pinning the user to standard-HR mode.
    mutating func reset() {
        consecutiveArmTimeouts = 0
        tripped = false
    }
}

/// Detects a WHOOP 4 "bond-loop" (#617): the strap bonds successfully, then the encrypted link drops
/// ~1s later with a CONNECTION TIMEOUT (`CBError.connectionTimeout`), the auto-rescan reconnects, it
/// bonds again, and dies again — an endless bond→timeout cycle on macOS/iOS that never settles and never
/// tells the user why.
///
/// The tell is a TIMEOUT drop that lands shortly after a GENUINE bond: bond → die-soon → rescan → bond →
/// die-soon. A bond that survives well past the window is healthy and breaks the streak — links flap for
/// benign reasons minutes in, and a late drop must NOT be blamed on the bond. We don't trip on a single
/// cycle (one quick drop is noise); we trip on >= `tripThreshold` CONSECUTIVE bond-then-quick-timeout
/// cycles. Once tripped, BLEManager surfaces the EXISTING re-pair guide (`state.reconnectGuide`) so the
/// user gets the forget-and-re-pair steps instead of watching a silent loop drain the battery.
///
/// Pure + value-typed so the decision is unit-testable without a CoreBluetooth seam — same shape as
/// `MarginalRadioDetector`.
struct PostBondTimeoutLoopDetector {
    /// How many consecutive bond-then-quick-timeout cycles before we surface the re-pair guide.
    /// 2 (not 1): one quick post-bond drop is noise; two in a row is the loop, not a fluke.
    let tripThreshold: Int
    /// A timeout only counts as "right after bonding" if it lands within this window of the bond. A drop
    /// well into a healthy session is unrelated to bonding and must NOT count (that would mis-trip a good
    /// link that merely flapped later). Generous vs the radio detector's 20s: the loop's signature is a
    /// near-immediate (~1s) drop, but pre-loop links can limp a few seconds before timing out.
    let quickTimeoutWindow: TimeInterval

    private(set) var consecutiveBondTimeouts = 0
    /// True once we've tripped: BLEManager has surfaced (or should surface) the re-pair guide.
    private(set) var tripped = false

    init(tripThreshold: Int = 2, quickTimeoutWindow: TimeInterval = 8) {
        self.tripThreshold = tripThreshold
        self.quickTimeoutWindow = quickTimeoutWindow
    }

    /// A connection ended. `wasBonded` = the link reached a genuine encrypted bond this connection;
    /// `secondsSinceBond` = how long after bonding the link ended (nil if we never bonded); `timedOut` =
    /// the drop looks like a connection timeout (vs an intentional disconnect, a bond reset, a clean close).
    /// Returns true if THIS event tripped the loop (a freshly-crossed threshold), so the caller can
    /// log/surface the guide exactly once.
    mutating func connectionEnded(wasBonded: Bool, secondsSinceBond: TimeInterval?, timedOut: Bool) -> Bool {
        // Only a timeout that lands within the window after we actually bonded is evidence of the loop.
        // Anything else (never bonded, non-timeout close, a drop long after a healthy bond) breaks the
        // streak — a single healthy spell should clear prior suspicion.
        let bondThenQuickTimeout = wasBonded && timedOut
            && (secondsSinceBond.map { $0 <= quickTimeoutWindow } ?? false)
        guard bondThenQuickTimeout else {
            consecutiveBondTimeouts = 0
            return false
        }
        consecutiveBondTimeouts += 1
        if !tripped && consecutiveBondTimeouts >= tripThreshold {
            tripped = true
            return true        // freshly tripped — caller surfaces the re-pair guide once
        }
        return false
    }

    /// Clear all suspicion: a clean session is flowing, or the user explicitly disconnected. Lets a
    /// transient bond hiccup recover instead of permanently flagging the link as bond-looping.
    mutating func reset() {
        consecutiveBondTimeouts = 0
        tripped = false
    }
}

/// #747 / #750: decides when a strap that keeps REFUSING the encrypted bond ("Encryption/Authentication is
/// insufficient", no genuine bond in between) has refused enough times that hammering it further is
/// pointless. Two responsibilities, both pure so they're unit-testable without a CoreBluetooth seam:
///
///  - #747 PAUSE: after `giveUpThreshold` consecutive refusals the auto-reconnect should STOP re-kicking
///    (it can't bond without the user freeing the strap / re-pairing), so the caller pauses the rescan and
///    surfaces an honest hint instead of looping forever and draining the battery.
///  - #750 EPITAPH: at the same moment, emit ONE summary "epitaph" line recording how the bond attempt
///    died (the streak + an opaque, install-local id), so a shared strap log carries the cause without any
///    PII (no MAC, no serial, just the count and a short opaque token).
///
/// The streak accumulates across the reconnect loop (a disconnect does NOT reset it) and is cleared only by
/// a genuine bond or an explicit user reconnect, exactly like BLEManager's existing `bondRefusalStreak`.
struct BondRefusalGiveUp {
    /// Consecutive bond refusals before we pause auto-reconnect + write the epitaph. 5 (not 2, where the
    /// pairing HINT already shows): the hint asks the user to act; we give them several reconnect cycles to
    /// do it before we stop hammering. A genuinely held/stale strap reaches 5 within a couple of minutes.
    let giveUpThreshold: Int

    private(set) var refusals = 0
    /// True once `giveUpThreshold` is reached: auto-reconnect should pause and the epitaph has been (or
    /// should be) written. Stays true until `reset()` so the pause holds across the loop.
    private(set) var gaveUp = false

    init(giveUpThreshold: Int = 5) { self.giveUpThreshold = giveUpThreshold }

    /// Record one bond refusal. Returns true if THIS refusal freshly crossed the give-up threshold (so the
    /// caller pauses the reconnect + writes the epitaph exactly once).
    mutating func recordRefusal() -> Bool {
        refusals += 1
        if !gaveUp && refusals >= giveUpThreshold {
            gaveUp = true
            return true
        }
        return false
    }

    /// Clear the streak: a genuine bond landed, or the user explicitly reconnected. Re-arms auto-reconnect.
    mutating func reset() {
        refusals = 0
        gaveUp = false
    }

    /// #750: the one-line bond-refusal EPITAPH. Records the streak + an OPAQUE install-local id only, never
    /// a MAC or serial. `opaqueId` should be a short token derived from the CoreBluetooth-local peripheral
    /// UUID (per-install, not the hardware address), which carries no PII. Pure so a fixture pins it. No
    /// em-dash (project rule). Byte-identical to the Android twin.
    static func epitaphLine(refusals: Int, opaqueId: String) -> String {
        "Bond epitaph: the strap [\(opaqueId)] refused the encrypted bond \(refusals)x in a row with no successful bond - giving up auto-reconnect to stop hammering it. It is almost certainly held by the official WHOOP app or a stale phone pairing. Free it (close the WHOOP app, put the strap in pairing mode, forget it in Bluetooth settings) then reconnect in NOOP."
    }

    /// #747: the honest user-facing hint shown when auto-reconnect pauses. Tells them WHY it stopped and how
    /// to get going again. Pure; no em-dash. Byte-identical to the Android twin.
    static func pausedHint() -> String {
        "NOOP stopped retrying because your strap keeps refusing to pair. It is likely still held by the official WHOOP app, or your phone is holding an old pairing. Close the WHOOP app, put the strap in pairing mode (tap until the LEDs flash blue), and if it is listed in your Bluetooth settings choose Forget This Device. Then tap Connect to try again."
    }

    /// #750: a short OPAQUE token from a CoreBluetooth-local peripheral UUID for the epitaph. The CB UUID is
    /// per-install (NOT the hardware MAC), and we keep only its first 8 hex chars, so the token is stable
    /// within a log but carries no device-identifying PII. Pure + deterministic. Twin of the Android helper.
    static func opaqueId(fromLocalUUID uuid: String) -> String {
        let hex = uuid.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.prefix(8))
    }
}

/// Decides when a completed sync that handed over only the strap's console/diagnostic output (no sensor
/// records) is sustained enough to warn that the strap's clock has lost sync and it isn't banking to flash
/// (#77 / #91 / #120). A SINGLE empty cycle is common on a perfectly healthy strap — the strap can hand
/// back a console-only window, especially under heavy live-HR polling — so warning on one cycle
/// false-alarms users whose clock is fine (#126). We require CONSECUTIVE empty cycles; any cycle that banks
/// real sensor records clears the streak. Pure value type → unit-testable without a CoreBluetooth seam.
struct EmptySyncTracker {
    /// Consecutive console-only completed syncs before the clock-lost banner shows. 3 (not 1): a genuinely
    /// un-banking strap is console-only on EVERY cycle, so 3 is reached within minutes, while a transient
    /// empty cycle amid healthy ones never accumulates.
    let threshold: Int
    private(set) var consecutiveEmptySyncs = 0

    init(threshold: Int = 3) { self.threshold = threshold }

    /// Record a COMPLETED (HISTORY_COMPLETE) offload. `bankedSensorRecords` = the strap handed over real
    /// sensor records this cycle (decoded, or undecodable-but-archived — either way the clock is banking).
    /// `consoleOnly` = it handed over only diagnostic frames and no sensor records. Returns true only once
    /// emptiness is SUSTAINED (≥ threshold consecutive console-only cycles) — the caller shows the
    /// "clock has lost sync" banner only then. Any banking cycle, or a caught-up cycle with nothing to
    /// offload, clears the streak.
    mutating func recordCompletedSync(bankedSensorRecords: Bool, consoleOnly: Bool) -> Bool {
        guard consoleOnly, !bankedSensorRecords else {
            consecutiveEmptySyncs = 0
            return false
        }
        consecutiveEmptySyncs += 1
        return consecutiveEmptySyncs >= threshold
    }
}

/// #580: a connected WHOOP 5/MG whose firmware acks SEND_HISTORICAL_DATA but emits ZERO type-0x2F
/// offload frames. Live HR streams fine over the standard 0x2A37 profile, but the historical offload is
/// empty, so every session runs the 60s idle watchdog out to a "timeout" and surfaces the WHOOP-4
/// "strap went quiet" sync error — even though nothing is wrong, the 5/MG history offload is simply
/// experimental/unsupported on that firmware. Worse, the empty offload leaves the link idle, so the
/// 120s liveness watchdog can bounce-disconnect/rescan every ~2 min in a thrash loop.
///
/// This pure tracker counts CONSECUTIVE empty 5/MG offloads (a timeout with no offload frames and no
/// rows persisted). Once `quietThreshold` is reached it reports the strap as "history-empty" so the
/// caller can (a) surface an honest "connected, history sync experimental on 5.0" state instead of a
/// sync error, and (b) back off the bounce loop. Any offload that DOES hand over real records clears the
/// streak — so a strap that later starts banking recovers immediately. Value type → unit-testable
/// (Whoop5EmptyOffloadTrackerTests) without a CoreBluetooth seam. Mirrored on Android.
struct Whoop5EmptyOffloadTracker {
    /// Consecutive empty 5/MG offloads before we treat the strap as history-empty (experimental). 2 (not
    /// 1): the very first offload after connect can race the strap waking its flash, so one empty cycle is
    /// noise; two in a row is the firmware genuinely not serving history.
    let quietThreshold: Int

    private(set) var consecutiveEmpty = 0
    /// True once `quietThreshold` consecutive empty offloads have been seen — the link is up + live HR is
    /// flowing but the 5/MG history offload is empty. Drives the honest home-state flag AND the bounce
    /// backoff. Cleared the moment any offload banks real records.
    private(set) var historyEmpty = false

    init(quietThreshold: Int = 2) { self.quietThreshold = quietThreshold }

    /// Record a completed/timed-out 5/MG offload. `bankedRecords` = this offload routed real offload
    /// frames / persisted rows (the strap IS handing over history). Returns true if THIS call freshly
    /// crossed the threshold (so the caller can log/surface once). A banking offload resets everything.
    mutating func recordOffload(bankedRecords: Bool) -> Bool {
        guard !bankedRecords else {
            consecutiveEmpty = 0
            historyEmpty = false
            return false
        }
        consecutiveEmpty += 1
        if !historyEmpty && consecutiveEmpty >= quietThreshold {
            historyEmpty = true
            return true     // freshly crossed — caller logs/surfaces once
        }
        return false
    }

    /// Clear all suspicion — a fresh connect, or the user explicitly re-requested a sync. Lets a strap
    /// that starts banking (or a transient empty spell) recover without waiting out the streak.
    mutating func reset() {
        consecutiveEmpty = 0
        historyEmpty = false
    }
}

/// Decides whether a backfill session that ended on the 60s IDLE cap (not a true HISTORY_COMPLETE)
/// should immediately re-kick another offload instead of tearing down to wait the 15-min periodic floor
/// (#364). The real bug: the strap offloads OLDEST-first at ~60s/session, so on a deep backlog (e.g. the
/// app was off for days) each connection drains only ~one session's worth of the OLDEST data, then waits
/// 15 minutes — so "last night" can take many connections to reach even while the strap stays connected
/// the whole time. Auto-continuing closes that gap: keep re-offloading back-to-back while the strap is
/// still connected, there's demonstrably more backlog, and we're still making progress.
///
/// Pure + value-typed so the decision is unit-testable without a CoreBluetooth seam (Backfill
/// ContinuationTests). Mirrored byte-for-behaviour on Android (WhoopBleClient.shouldAutoContinue).
///
/// The four guards (ALL must hold):
///  1. `stillConnected` — connected + bonded; a dropped link goes through the normal reconnect path.
///  2. backlog remains — the strap's newest banked record (`strapNewestTs`, from GET_DATA_RANGE) is
///     still AHEAD of our persisted data frontier (`ourFrontierTs` = max persisted HR ts) by more than
///     `behindGapSeconds`. Comparing the frontier (not the trim u32, which climbs on empty ENDs even
///     when stuck) is what separates "more to fetch" from "caught up / off-wrist" — same idiom as
///     StuckStrapDetector. nil on either side ⇒ unknown ⇒ don't auto-continue (let the floor handle it).
///  3. `lastTrimAdvanced` — the just-ended session actually moved the strap's trim cursor. If the cursor
///     is frozen (strap handing back console-only / refusing to trim), re-kicking would spin forever
///     burning battery; stop and let the periodic floor retry slowly.
///  4. `consecutiveCount < maxAutoContinues` — a hard per-connection cap so a pathological strap can't
///     pin the radio. Once hit, fall back to the 15-min floor.
///
/// #1012: a FUTURE-dated `strapNewestTs` (more than `futureSkewSeconds` past the wall clock, #928) not
/// only nulls guard 2a — it also STOPS guard 2b. A future-clock strap banks future-dated records, so the
/// rows it hands over are future-timestamped too and "real rows persisted" is no evidence of genuine
/// backlog; 2b would chase the future-dated range through the whole cap (every consecutive pass back-to-back,
/// each to its idle timeout — the reported ~15-min sync). The stale/PAST-epoch case 2b actually exists for (#451)
/// reads BEHIND the frontier, never future-dated, so it is untouched.
struct BackfillContinuation {
    /// Hard cap on consecutive auto-continues per connection (resets on disconnect). Guards 1-3 in
    /// `shouldAutoContinue` (plus the #928/#1012 future-clock exclusion) already stop the pathological
    /// cases, so this is only the backstop against a strap that advances its trim but never advances OUR
    /// frontier. #533: at 6, a well-behaved deep backlog hit the cap and got throttled to the 15-min floor
    /// mid-drain (recent nights landing hours after waking — a false sleep-detection bug in #515). Raised so
    /// a typical deep backlog drains in ONE connection (~24 productive passes ≈ a few minutes back-to-back);
    /// the backstop only ever bites the rare data-shape spin. TUNABLE — needs on-strap validation.
    static let defaultMaxAutoContinues = 24
    /// How far ahead the strap must be (seconds) before "more backlog remains" is real, not clock noise.
    /// Matches StuckStrapDetector.behindGapSeconds (5 min) so the two agree on "behind".
    static let defaultBehindGapSeconds = 300
    /// #928: how far past the WALL CLOCK the strap-reported "newest" may sit before it is implausible.
    /// A strap clock set in the FUTURE (wandering RTC relatch) makes dataRangeNewestUnix read ahead of
    /// every real frontier, so guard 2a would report backlog forever and burn the whole cap in EMPTY
    /// offloads on every connect. 48 h absorbs genuine timezone confusion and mild drift; nothing
    /// legitimate banks records two days ahead of the phone's clock.
    static let defaultFutureSkewSeconds = 48 * 3600

    /// #1012: is the strap-reported "newest banked record" FUTURE-dated beyond the skew allowance — more
    /// than `futureSkewSeconds` past the wall clock? The strap's clock is then almost certainly set in the
    /// future (#928), so its range answer AND its freshly-persisted rows are untrustworthy as backlog
    /// evidence. Pure, and shared between `shouldAutoContinue` (it gates 2a AND 2b) and the call site's
    /// honest stop log so the two can never disagree on the reason. nil ⇒ false: an unanswered range is
    /// UNKNOWN, not future-dated, and 2b's stale-epoch rescue (#451) still applies to it.
    static func isFutureDatedNewest(_ strapNewestTs: Int?, wallNowUnix: Int,
                                    futureSkewSeconds: Int = defaultFutureSkewSeconds) -> Bool {
        guard let n = strapNewestTs else { return false }
        return n > wallNowUnix + futureSkewSeconds
    }

    /// `stillConnected`: link up + command channel usable. `strapNewestTs`: newest record the strap holds
    /// (GET_DATA_RANGE). `ourFrontierTs`: newest record WE'VE persisted (max HR ts). `wallNowUnix`: the
    /// REAL wall clock at decision time (#928 future-clock plausibility check; passed in so the predicate
    /// stays pure). `lastTrimAdvanced`: the just-ended session moved the trim cursor. `consecutiveCount`:
    /// auto-continues already done this connection. Returns true to immediately re-kick beginBackfill;
    /// false to tear down to the floor.
    static func shouldAutoContinue(stillConnected: Bool,
                                   strapNewestTs: Int?,
                                   ourFrontierTs: Int?,
                                   wallNowUnix: Int,
                                   rowsPersistedThisSession: Int = 0,
                                   lastTrimAdvanced: Bool,
                                   consecutiveCount: Int,
                                   maxAutoContinues: Int = defaultMaxAutoContinues,
                                   behindGapSeconds: Int = defaultBehindGapSeconds,
                                   futureSkewSeconds: Int = defaultFutureSkewSeconds) -> Bool {
        guard stillConnected else { return false }                 // 1
        guard consecutiveCount < maxAutoContinues else { return false }   // 4 (cap)
        guard lastTrimAdvanced else { return false }               // 3 (don't spin on a frozen cursor)
        // 3b (#1144): an EMPTY session (0 rows persisted) never auto-continues, whatever the reported
        // frontier gap. When the strap advertises a `newest` AHEAD of our frontier but the offload for that
        // range hands back 0 rows (a PHANTOM gap — a timestamp it won't actually offload), 2a below would
        // latch `true` forever: the frontier can't advance without rows, so `newest - frontier` stays > gap
        // and it re-fires to the full cap in empty offloads (the storm observed on a real 4.0). Guard 3
        // doesn't catch it — the trim u32 climbs on empty ENDs. Stop and let the periodic floor retry;
        // healthy backlog sessions persist real rows so this only bites the empty spin. (Makes 2b's row
        // check the ONE authority for both cases.)
        guard rowsPersistedThisSession > 0 else { return false }
        // #928: a strap clock set in the FUTURE makes "newest" read ahead of ANY real frontier, so 2a
        // would report backlog forever and drive up to the full cap in EMPTY offloads on every connect.
        // A newest more than futureSkewSeconds past the wall clock is implausible: exclude it from 2a.
        let futureDated = isFutureDatedNewest(strapNewestTs, wallNowUnix: wallNowUnix,
                                              futureSkewSeconds: futureSkewSeconds)
        let plausibleNewest = futureDated ? nil : strapNewestTs
        // 2a: the strap reports newer data than we hold — reliable WHEN its clock epoch is sane.
        if let newest = plausibleNewest, let frontier = ourFrontierTs, (newest - frontier) > behindGapSeconds {
            return true
        }
        // #1012: a future-dated newest also gates 2b, not just 2a. A strap whose clock is set ahead
        // (#928) BANKED future-dated records, so the rows this session persisted are themselves
        // future-timestamped — "real rows" is NOT evidence of genuine backlog there, and 2b used to
        // chase the future-dated range through the whole cap (every consecutive pass back-to-back, each run to its
        // idle timeout: the reported ~15-min sync). Stop after this single pass; the periodic floor
        // keeps draining across connects, restoring the pre-#928 single-pass behaviour. The stale/
        // PAST-epoch case 2b exists for (#451) reads BEHIND the frontier, never future-dated, so it
        // falls through untouched below.
        if futureDated { return false }
        // 2b (#451): GET_DATA_RANGE's "newest" can read a STALE / wrong-epoch value — a strap that was
        // fully discharged (or carries a previous owner's history) banks records across multiple clock
        // epochs, and the data-range "newest" can latch an OLD one (e.g. 2024 when the real newest is 2026).
        // That false "we're already past it" would stop the drain after ONE session and make the user
        // tap the strap to re-trigger (exactly #364 / #451). But guard #3 already proved the trim advanced,
        // so if this session also PERSISTED REAL SENSOR ROWS the strap is demonstrably still handing over
        // real backlog — keep going. Empty / console-only ENDs persist 0 rows, so a genuinely stuck or
        // caught-up strap still won't spin, and the consecutive cap bounds it either way.
        return rowsPersistedThisSession > 0
    }
}

/// #927: the "overnight only" schedule for Continuous HRV capture. When the user opts in, the dense
/// R10/R11 + TOGGLE realtime R-R stream that continuous capture holds armed 24/7 is armed only inside a
/// nightly window, roughly halving the battery cost (overnight is where the HRV/recovery/sleep value is;
/// daytime Stress just gets sparser readings, since Stress reads this realtime R-R stream).
///
/// The window reuses the app's quiet-hours convention byte-for-byte (the NotificationSettingsStore keys,
/// the same defaults, and the same wrap-aware membership as SedentaryDetector.windowContains and the
/// Android NotifPrefs.inQuietHours): minutes since LOCAL midnight, inclusive start, exclusive end, and
/// the window may cross midnight (22:00 → 07:00 by default). Local wall time keeps it DST-agnostic the
/// same way quiet hours are: a DST jump moves the wall clock, the window definition never changes.
///
/// The MODE is composed from the two persisted booleans so existing users need no migration:
///   continuous OFF                → stream never held open (unchanged)
///   continuous ON, overnight OFF  → ALWAYS: armed 24/7 (the pre-#927 behaviour; overnight defaults off)
///   continuous ON, overnight ON   → OVERNIGHT: armed only inside the window
///
/// Pure + value-typed so the predicate is unit-testable (ContinuousHrvScheduleTests). BLEManager
/// RE-DERIVES it at every arm site (reconcile / keep-alive tick / post-bond arm) instead of caching it,
/// so a reconnect outside the window can never re-arm the flood from a stale precomputed want.
struct ContinuousHrvSchedule {
    /// The reused quiet-hours window keys (written by NotificationSettingsStore; the same reuse idiom as
    /// InactivityPrefs.NotifK) and their defaults (22:00 / 07:00).
    static let quietStartKey = "notif.quietStartMinutes"
    static let quietEndKey = "notif.quietEndMinutes"
    static let defaultStartMinutes = 22 * 60
    static let defaultEndMinutes = 7 * 60

    /// Wrap-aware membership: is `minuteOfDay` inside `[startMin, endMin)`, where the window may cross
    /// midnight? Byte-for-byte the quiet-hours semantics (SedentaryDetector.windowContains / the Android
    /// NotifPrefs.inQuietHours): start <= end is the plain daytime interval; start > end wraps midnight.
    static func windowContains(_ minuteOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        if startMin <= endMin { return minuteOfDay >= startMin && minuteOfDay < endMin }
        return minuteOfDay >= startMin || minuteOfDay < endMin
    }

    /// The composed want: should the continuous-capture stream be held open at local wall-clock minute
    /// `minuteOfDay`? False when the feature is off; true 24/7 in ALWAYS mode (overnightOnly false, the
    /// pre-#927 behaviour every existing user reads with no migration); window-gated in OVERNIGHT mode.
    static func streamWanted(continuousHrv: Bool, overnightOnly: Bool,
                             minuteOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        guard continuousHrv else { return false }
        guard overnightOnly else { return true }
        return windowContains(minuteOfDay, startMin: startMin, endMin: endMin)
    }
}

/// CoreBluetooth engine for the WHOOP 4.0: scan-by-service → connect → discover →
/// BOND (one confirmed write) → subscribe → reassemble char-05 frames → FrameRouter.
/// Cannot run in the simulator; verified manually on-device (Task C6).
@MainActor
public final class BLEManager: NSObject, ObservableObject {

    // MARK: GATT UUIDs (authoritative, from FINDINGS.md)
    static let customService   = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    static let whoop5Service   = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a") // WHOOP 5.0 / MG
    static let cmdWriteChar    = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // CMD → strap
    static let cmdNotifyChar   = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // responses
    static let eventNotifyChar = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // events
    static let dataNotifyChar  = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // data (frag)
    // WHOOP 5.0 / MG ("puffin") characteristics under the fd4b service. EXPERIMENTAL — see the
    // whoop5 connect path in didDiscoverCharacteristics. fd4b0002 takes the static CLIENT_HELLO.
    static let whoop5CmdWriteChar = CBUUID(string: "fd4b0002-cce1-4033-93ce-002d5875f58a")
    static let whoop5NotifyChars: [CBUUID] = [
        CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0004-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0007-cce1-4033-93ce-002d5875f58a"),
    ]
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateChar    = CBUUID(string: "2A37") // HR + R-R (works unbonded)
    static let batteryService   = CBUUID(string: "180F")
    static let batteryChar      = CBUUID(string: "2A19")
    /// Standard Device Information Service — read-only. Used ONLY to tell a WHOOP MG apart from a
    /// plain 5.0 (#520): the serial's prefix and the hardware-revision string are the two signals
    /// `Whoop5Variant` resolves. No writes, and 4.0 never reads these (see the post-bond gate).
    static let disService       = CBUUID(string: "180A")
    static let disSerialChar    = CBUUID(string: "2A25") // Serial Number String
    static let disHwRevChar     = CBUUID(string: "2A27") // Hardware Revision String

    static let restoreID = "com.openwhoop.ble.central"

    // MARK: Published state
    public let state: LiveState
    private let router: FrameRouter
    private var collector: Collector?
    /// #716: stored on bootstrap so the scan callback can fix the seeded "WHOOP" model label.
    private var registryStore: DeviceRegistryStore?
    /// #716: true once the seeded "WHOOP" model has been stamped to the correct family.
    private var modelStamped = false

    // MARK: Upload / server sync — REMOVED for Strand (standalone, fully on-device).

    // MARK: Backfill
    private var backfiller: Backfiller?
    /// True while a historical offload session is in progress (frames route to Backfiller).
    private var backfilling = false
    /// Wall time of the most recent offload frame OR HISTORY_COMPLETE — drives the #174 deep-packet
    /// cooldown. A type-0x2F frame arriving just after a backfill ends (backfilling already flipped
    /// false) is a TRAILING historical frame, not the live R22 stream; it must not be miscounted as a
    /// "live deep packet". nil until the first offload frame this process.
    private var lastOffloadFrameAt: Date?
    /// Window after the last offload frame/HISTORY_COMPLETE during which a type-0x2F frame is treated
    /// as trailing-historical, not live. ~10 s comfortably covers the post-completion drain lull.
    static let deepPacketLiveCooldownSeconds: TimeInterval = 10
    /// How far back the inactivity reminder (#419) reads gravity on each offload completion (4 h
    /// comfortably spans the threshold + re-nudge cadence and a separating Active break for bout
    /// continuity). Mirrors the Android WhoopBleClient.INACTIVITY_LOOKBACK_S.
    static let inactivityLookbackSeconds = 4 * 3600
    /// Safety-net detector: strap reports newer data than us AND our frontier frozen 10 min ⇒ flag for
    /// reboot. behindGapSeconds avoids false positives when off-wrist / caught up. Insurance only.
    private var stuckDetector = StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300)
    /// Newest record unix the strap reports having (from the GET_DATA_RANGE response); refreshed each
    /// offload. Compared against our frontier to tell "stuck" from "off-wrist/caught-up".
    private var strapNewestTs: Int?
    /// Fires if the strap goes silent mid-offload; re-armed on every frame during backfill.
    private var backfillTimeout: DispatchWorkItem?
    /// Periodic opportunistic upload while connected. Without it, upload only fires at connect +
    /// backfill-exit, so during a long live session decoded rows pile up locally and the server
    /// (dashboard) lags. Started on bond, cancelled on disconnect.
    private var uploadTimer: DispatchSourceTimer?
    static let uploadIntervalSeconds = 30
    /// Periodic re-trigger of the type-47 historical offload. This is the PRIMARY continuous metric
    /// source (mirrors how WHOOP syncs): the strap's 14-day biometric store is re-offloaded every
    /// `backfillIntervalSeconds` while connected+bonded, rather than once per connect. Started on
    /// bond, cancelled on disconnect. Plain SEND_HISTORICAL_DATA returns the type-47 store (no
    /// high-freq-sync), so each periodic tick just routes through requestSync(.periodic) → beginBackfill
    /// (SEND_HISTORICAL_DATA + watchdog), subject to the BackfillPolicy floor.
    private var backfillTimer: DispatchSourceTimer?
    // The timer fires this often, but BackfillPolicy.periodicFloorSeconds is the real floor (a recent
    // event-triggered sync defers the next periodic tick). 900s = 15 min, matching WHOOP.
    static let backfillIntervalSeconds = 900
    /// Scheduling flexibility for the long-running periodic offload timer. The offload remains no
    /// earlier than its battery-adaptive deadline; this only lets Darwin coalesce the wake with nearby
    /// system work instead of waking the CPU at an unnecessarily exact instant.
    static let backfillTimerLeewaySeconds = 60
    /// #477: stretched offload cadence while low on power (45 min). The strap banks to flash meanwhile,
    /// so this only delays sync (larger batches), never loses data. Mirrors Android
    /// `LOW_BATTERY_BACKFILL_INTERVAL_MS`.
    static let lowBatteryBackfillIntervalSeconds = 2700

    /// Pure battery-adaptive gate (#477), the twin of Android `WhoopBleClient.idleThrottleActive`. Keyed
    /// on the STRAP's battery: armed by `thresholdPct` > 0, engages while the strap is discharging at/below
    /// `thresholdPct`. The phone's own Low Power Mode deliberately does NOT trigger it. Charging never engages.
    static func lowPowerThrottleActive(batteryPct: Int, charging: Bool, thresholdPct: Int) -> Bool {
        thresholdPct > 0 && !charging && batteryPct <= thresholdPct
    }

    /// Pure offload-interval decision (#477), the twin of Android `offloadIntervalMsFor`.
    static func offloadInterval(baseSeconds: Int, lowSeconds: Int,
                                batteryPct: Int, charging: Bool, thresholdPct: Int) -> Int {
        lowPowerThrottleActive(batteryPct: batteryPct, charging: charging, thresholdPct: thresholdPct)
            ? max(baseSeconds, lowSeconds) : baseSeconds
    }

    /// #battery: pure 5/MG battery-read throttle decision, unit-testable without a CoreBluetooth seam.
    /// Returns true when no prior read exists (the first read of a connection, or post-disconnect re-seed)
    /// OR when at least `whoop5BatteryReadMinIntervalSeconds` has elapsed since the last read. Stops the
    /// 30 s keep-alive tick from re-reading 0x2A19 every cycle. Twin of the Android `keepAliveTick % 2 == 0`
    /// ~60 s cadence (WhoopBleClient keepAliveFire).
    static func shouldPollWhoop5Battery(lastReadAt: Date?, now: Date = Date()) -> Bool {
        guard let last = lastReadAt else { return true }
        return now.timeIntervalSince(last) >= whoop5BatteryReadMinIntervalSeconds
    }

    /// #battery: pure periodic-offload interval for a 5/MG whose history is known-empty, unit-testable
    /// without a CoreBluetooth seam. Stretches to the low-battery floor (45 min) regardless of battery %,
    /// because an experimental-history 5/MG banks nothing per pass. Stacks with the BackfillPolicy
    /// empty-backoff (which engages one cycle later, at 3 empties). Twin of Android `nextBackfillDelayMs`'s
    /// `whoop5EmptyOffload.historyEmpty` branch.
    static func whoop5EmptyHistoryBackfillInterval(baseSeconds: Int, lowSeconds: Int,
                                                   historyEmpty: Bool) -> Int {
        historyEmpty ? max(baseSeconds, lowSeconds) : baseSeconds
    }

    /// Keep-alive: re-arm realtime, poll battery, and bounce a stalled link so streaming
    /// never silently dies. Started on bond, cancelled on disconnect.
    private var keepAliveTimer: DispatchSourceTimer?
    static let keepAliveIntervalSeconds = 30
    private var keepAliveTick = 0
    /// #battery: minimum gap between 5/MG 0x2A19 battery reads. `enableLiveNotifications` fires from the
    /// 30 s keep-alive tick AND once each from the CLIENT_HELLO-ack / post-bond callers, so without a
    /// throttle a 5/MG was READ every ~30 s — 2 880 GATT reads/day, 2× the Android twin's ~60 s cadence
    /// (WhoopBleClient keepAliveFire polls 5/MG battery on `keepAliveTick % 2 == 0`) and 20× finer than
    /// the BatteryEstimator's own 600 s same-% throttle can consume. The post-bond / CLIENT_HELLO-ack
    /// reads still fire promptly (the first read of a connection has `lastBatteryReadAt == nil`); only
    /// the repeating keep-alive ticks are spaced to this floor. Reset to nil on disconnect so the next
    /// connect reads immediately. Parity fix — Android was already at ~60 s, this brings iOS to match.
    static let whoop5BatteryReadMinIntervalSeconds: TimeInterval = 60
    private var lastBatteryReadAt: Date?
    /// If a persisted/missing strap-family preference points at the wrong service, a service-filtered
    /// BLE scan can run forever even though the strap is nearby (the common "won't reconnect after an
    /// update" report). Rotate between WHOOP families after a short miss and persist whichever family
    /// actually advertises. (PR#195)
    private var scanFallbackWorkItem: DispatchWorkItem?
    static let scanFallbackDelaySeconds: TimeInterval = 8
    /// #730 diagnostic. A direct `central.connect(p)` to a RESTORED peripheral never scans, so
    /// `scanFallbackWorkItem` (which only fires while `central.isScanning`) does not cover it — and
    /// CoreBluetooth's connect has NO timeout, it pends indefinitely. A reporter's log showed exactly
    /// that: "reconnecting", then nothing, with `didFailToConnect` (which DOES log) never firing, so
    /// there was no way to tell pending from failed. Log once if the connect is still outstanding.
    /// DIAGNOSTIC ONLY — it never cancels or retries; recovery is separate work.
    private var pendingConnectProbe: DispatchWorkItem?
    static let pendingConnectProbeSeconds: TimeInterval = 15
    /// Last time ANY notification arrived — drives the liveness watchdog.
    private var lastDataAt = Date()
    /// True while a Live/Health screen is on-screen and wants the realtime stream. One of the two
    /// inputs to `wantsRealtime`. Driven by `startRealtime()` / `stopRealtime()`.
    private var screenWantsRealtime = false
    /// True while the "Continuous HRV capture" preference wants the realtime stream held open even with
    /// no Live screen visible, so the strap banks dense beat-to-beat R-R 24/7 (better overnight
    /// HRV/recovery/sleep). The second input to `wantsRealtime`. Default off; set by
    /// `setKeepRealtimeForData(_:)`. Mirrors the Android `keepStreamForData`. #927: this is the RAW
    /// preference intent; the effective want is window-gated through `continuousCaptureWantsNow()` when
    /// "overnight only" is on, re-derived at every arm site.
    private var keepRealtimeForData = false
    /// #477 battery (parity with Android): STRAP battery-% at/below which the periodic offload cadence
    /// stretches to `lowBatteryBackfillIntervalSeconds` (0 = off), and at/below which the background
    /// continuous-HRV stream is released. Both key off the STRAP's charge (not the phone's), and both are
    /// benign (no link risk). Set from Settings via `setLowBatteryOffloadThrottle`/`setPauseCaptureOnPowerSave`.
    private var lowBatteryOffloadPct = 0
    /// STRAP battery-% at/below which the continuous-HRV pause engages (0 = off) — like the offload lever.
    private var pauseCaptureBatteryPct = 0
    /// Derived want: the (heavy) realtime stream should be armed while EITHER a screen wants it OR the
    /// continuous-capture preference wants it. Keep-alive re-arms it; the post-bond branch arms it on
    /// connect. Recomputed only inside `reconcileRealtime()`.
    private var wantsRealtime = false
    /// What we last told the strap (armed = TOGGLE_REALTIME_HR 1). Lets `reconcileRealtime()` send the
    /// toggle only on the false↔true edge instead of on every input change. Cleared on disconnect — the
    /// strap forgets the toggle across a connection, and the post-bond branch re-arms from `wantsRealtime`.
    private var realtimeArmed = false
    /// #80 marginal-radio fallback: tracks consecutive arm-then-quick-timeout cycles. When it trips,
    /// `standardHRFallback` goes true and the next connect skips arming R10/R11 (relies on 0x2A37).
    private var marginalRadio = MarginalRadioDetector()
    /// #617 bond-loop detector: tracks consecutive bond-then-quick-timeout cycles on a WHOOP 4. When it
    /// trips, BLEManager surfaces the existing re-pair guide (`state.reconnectGuide`) instead of looping
    /// silently. Reset on a clean session / intentional disconnect / a successful connect.
    private var postBondLoop = PostBondTimeoutLoopDetector()
    /// Wall time the encrypted bond was established this connection, to measure how soon a drop follows
    /// the bond (the #617 bond-loop tell). nil until bonded; cleared on disconnect.
    private var bondedAt: Date?
    /// Monotonic per-connection token, bumped on every didConnect. The #711 bond-loop stabilization check
    /// captures it and clears the re-pair guide only if it is UNCHANGED when the check fires, i.e. the SAME
    /// continuous connection survived. CoreBluetooth reuses the CBPeripheral object across reconnects, so a
    /// `===` identity check would NOT tell a healthy session apart from a later loop cycle. Named distinctly
    /// from Repository.swift's v7.0.3 refreshGen publish token so the two never get confused.
    private var connectGeneration = 0
    // MARK: Connection & Sync test mode (Test Centre) - diagnostic-only counters
    //
    // These exist purely to feed the .connection-tagged diagnostic lines + readout when that test mode is
    // active; they change NO connect / bond / offload behaviour. Every emit site that reads them is gated
    // behind TestCentre.active(.connection) BEFORE any string is built, so the counters are still
    // maintained cheaply (a Date()/Int) but nothing tagged is ever produced when the mode is off.
    /// Wall time the current connect attempt began (the scan/connect call), to measure connect latency at
    /// didConnect. nil between attempts; set when connect() kicks the radio.
    private var connectAttemptStartedAt: Date?
    /// Count of INVOLUNTARY reconnects this run (a drop or failed-connect that was not user-initiated),
    /// surfaced as the reconnect-churn count. Reset by an intentional disconnect.
    private var connReconnectCount = 0
    /// When the current session reached connected, for the `connect down` duration readout (#1020).
    /// A session's length separates the causes of a drop at a glance — a bond watchdog fires seconds
    /// in, a stall bounce minutes in, a radio drop anywhere.
    ///
    /// Set on EVERY connect, not only when the connection test mode is active: the mode is usually
    /// switched on after something already looks wrong, so a stamp taken under the gate would carry a
    /// previous session's start. Never cleared on the way down, so read it only where a session is known
    /// to have been held (`didDisconnectPeripheral`, which fires only for a peripheral that connected).
    /// Android twin: `WhoopBleClient.connectedAtMs`.
    private var connSessionStartedAt: Date?
    /// #126 false-alarm guard: tracks CONSECUTIVE console-only completed syncs so the "clock has lost
    /// sync" banner only fires on sustained emptiness, not a single transient empty cycle on a healthy strap.
    private var emptySyncTracker = EmptySyncTracker()
    /// #580: tracks CONSECUTIVE empty 5/MG offloads so a 5/MG whose firmware serves no history offload (but
    /// streams live HR fine) reads as "history sync experimental on 5.0" instead of a sync error, and the
    /// 120s bounce loop backs off while live HR is flowing. Reset on connect / a banking offload.
    private var whoop5EmptyOffload = Whoop5EmptyOffloadTracker()
    /// When true, SKIP arming the R10/R11 raw realtime stream on connect — the radio couldn't sustain
    /// it (see MarginalRadioDetector). Live HR then comes only from the already-subscribed low-bandwidth
    /// 0x2A37 standard-HR profile. Per-session: set by the detector, cleared on a clean reconnect (a
    /// connection that actually carried data) or when the user re-opens Live / taps Start HR.
    private var standardHRFallback = false
    /// Wall time we last armed the R10/R11 realtime burst this connection, to measure how soon a drop
    /// follows the arm (the marginal-radio tell). nil until armed; cleared on disconnect.
    private var realtimeArmedAt: Date?
    /// Last-offload-attempt time (unix seconds), persisted so the rate limiter survives relaunch
    /// (matches WHOOP's DATA_SYNC_WORKER_LAST_WORK_TIME watermark).
    static let backfillLastAtKey = "backfillLastAt"
    /// Prevents a second backfill from starting on a same-process reconnect to the same strap.
    private var backfillStarted = false
    /// #364 auto-continue: how many times we've immediately re-kicked a backfill after a 60s idle-cap OR
    /// HISTORY_COMPLETE exit on THIS connection. Bounded by BackfillContinuation.maxAutoContinues so a
    /// pathological strap can't pin the radio. Reset to 0 once shouldAutoContinue proves we're caught up
    /// (its else path, under the cap) and on disconnect — NOT unconditionally on every HISTORY_COMPLETE,
    /// so a strap that slices one offload into many completions can't reset the cap each slice (#25).
    private var consecutiveAutoContinues = 0
    /// #battery: consecutive offload sessions that banked ZERO sensor rows — a clean HISTORY_COMPLETE-empty
    /// OR an idle-timeout STALL. Feeds BackfillPolicy's exponential backoff so the 15-min periodic poll
    /// stops spinning the radio on a strap returning nothing (a capture showed ~6 empty stalls/hour with no
    /// backoff, because only HISTORY_COMPLETE fed emptySyncTracker). SEPARATE from that tracker — which
    /// stays console-only-specific for the clock-lost banner — so counting stalls can never falsely fire
    /// that banner. Any banked rows reset it; the productive auto-continue tail doesn't count. Twin of
    /// Android `consecutiveEmptyOffloads`.
    private var consecutiveEmptyOffloads = 0
    /// #364 spin-detector: the trim cursor as of the END of the previous backfill session this
    /// connection. exitBackfilling compares the current Backfiller.lastAckedTrim against this to decide
    /// whether the just-ended session actually advanced the strap's trim (progress) or froze (stop
    /// re-kicking). nil until the first session ends; reset on disconnect.
    private var lastSessionEndTrim: UInt32?
    /// Runs the connect handshake EXACTLY ONCE per connection. `didWriteValueFor` re-fires on every
    /// `.withResponse` write (the bond write, every SEND_HISTORICAL, every HISTORY_END ack); without
    /// this guard those re-entries re-blasted hello/SET_CLOCK at the strap mid-offload and stopped it
    /// from streaming type-47 — THE iOS "won't serve" root cause. Reset on disconnect.
    private var connectHandshakeDone = false
    /// #34: true once the cmd-notify characteristic (61080003) has CONFIRMED it's subscribed
    /// (`didUpdateNotificationStateFor` fired for it with `isNotifying == true`) — as opposed to merely
    /// requested. Together with `connectHandshakeDone`, gates `state.connectSettled` (see LiveState.swift)
    /// so the alarm re-arm doesn't fire GET_ALARM_TIME before the strap's reply channel is actually live.
    /// Reset on disconnect alongside `connectHandshakeDone`.
    private var cmdNotifyConfirmedActive = false
    /// #34: latches once `state.connectSettled` has been bumped for the CURRENT connection, so a
    /// didUpdateNotificationStateFor re-fire (or any other later call into the check) can't double-bump.
    /// Reset on disconnect.
    private var connectSettledSignaled = false
    /// #613: set for one restored session when CoreBluetooth hands back an ALREADY-connected peripheral
    /// via `willRestoreState`. The inherited notify subscriptions come back reported-active but no longer
    /// deliver, and the subscribe loops skip anything already `isNotifying` — so nothing re-arms and no live
    /// HR/R-R arrive, while `didUpdateNotificationStateFor` never fires (→ `cmdNotifyConfirmedActive` →
    /// `connectSettled` never latch). While this is true, `requestNotify` forces one real off→on
    /// re-subscribe so delivery — and the settle/alarm-re-arm chain — is re-established. Cleared the moment
    /// `connectSettled` bumps, and on disconnect.
    private var restoreNeedsResubscribe = false
    /// Re-entrancy guard for captureRawAccel: true while a bounded on-demand window is running.
    /// A second tap is a no-op until the active capture's asyncAfter block fires and clears this.
    private var rawCaptureInFlight = false
    /// Ordered queue of frames awaiting drain through the serial Backfiller task.
    private var backfillFrameQueue: [[UInt8]] = []
    /// True while the drain task is running (prevents a second drain task from launching).
    private var backfillDraining = false
    /// Keep each main-actor drain slice small enough that SwiftUI can process input/paint between slices.
    private static let backfillDrainBatchSize = 12

    /// Records WHOOP 5/MG puffin frames to a JSON file for protocol mapping. Passive (read-only on the
    /// strap) and gated by the Settings → Experimental "Record puffin frames" toggle; a no-op for
    /// WHOOP 4.0 and when the toggle is off. Lazy so it shares `state` after init. (Cherry-picked from
    /// @j0b-dev's PR #20.)
    private lazy var puffinRecorder = PuffinFrameRecorder(state: state)
    private lazy var puffinEventLog = PuffinEventLog()

    /// Durable log of the WHOOP 5/MG high-rate R22 deep buffers (type-0x2F ≥ 1 KB) for #423 reverse-
    /// engineering. Gated on the same capture toggle; no-op otherwise.
    private lazy var puffinDeepBufferLog = PuffinDeepBufferLog()

    /// Force the puffin capture buffer to disk so the Settings export/reveal targets a current file.
    public func flushPuffinCaptures() { puffinRecorder.flush() }

    /// Record a local physical-phase marker for the passive optical experiment. This deliberately has
    /// no peripheral/write path: it only appends to `puffin-deepbuffers.jsonl` when capture is enabled.
    @discardableResult
    func markWhoop5OpticalPhase(_ phase: PuffinOpticalExperimentPhase) -> Bool {
        puffinDeepBufferLog.appendOpticalPhase(phase)
    }

    /// Flush and expose the passive deep-buffer experiment log for a user-initiated export.
    func whoop5OpticalExperimentURL() -> URL? {
        puffinDeepBufferLog.opticalExperimentURL()
    }

    // MARK: CoreBluetooth
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Multi-WHOOP: when non-nil, the scan/discover path connects ONLY to the peripheral whose
    /// `identifier == preferredPeripheralUUID` and ignores every other discovered WHOOP. When nil
    /// (the only state a single-WHOOP user is ever in) the discover path is byte-for-byte unchanged —
    /// it connects to the FIRST WHOOP discovered. Set by the app via `setPreferredPeripheral(_:)` to
    /// the active device's persisted `peripheralId`. Purely additive; nothing reads it on the nil path.
    private var preferredPeripheralUUID: UUID?
    /// Multi-WHOOP Add-a-WHOOP wizard: while true, `didDiscover` POPULATES `discoveredWhoops` instead
    /// of auto-connecting — an explicit, separate "present the nearby straps" mode the wizard turns on
    /// (`scanForWhoops()`) then off (`stopWhoopScan()`). Default false leaves the auto-connect path
    /// untouched. Must never overlap the normal connect flow (the wizard owns the central while true).
    private var isPresentingScan = false
    /// The CBPeripheral.identifier.uuidString of the WHOOP we most recently CONNECTED to (`didConnect`).
    /// Published so the app/AppModel can persist it onto the active registry device
    /// (`registry.setPeripheralId`) — letting "my-whoop" adopt its strap's id on first connect and a
    /// specific WHOOP confirm its identity. BLEManager stays decoupled: it never writes the registry.
    @Published public private(set) var connectedPeripheralUUID: String?
    /// Multi-WHOOP Add-a-WHOOP wizard surface: straps seen while `isPresentingScan` is true, WITHOUT
    /// auto-connecting. Cleared at the start of each `scanForWhoops()`. Empty/unused on the default path.
    @Published public private(set) var discoveredWhoops: [(uuid: String, name: String, rssi: Int)] = []
    /// Peripheral captured during `willRestoreState`; cleared in `didConnect`.
    /// Non-nil signals that `centralManagerDidUpdateState` should reconnect this
    /// specific peripheral rather than starting a fresh scan.
    private var restoredPeripheral: CBPeripheral?
    /// #280: true while `lastSyncError` currently holds a radio-state message (off / unauthorized /
    /// unsupported) that `centralManagerDidUpdateState` set. Lets the poweredOn transition clear ONLY
    /// that message, never a genuine mid-sync error (e.g. "Sync interrupted").
    private var radioStateErrorShown = false
    /// #391: pending one-shot escalation armed when the central reports `.unauthorized` while the TCC
    /// grant reads as granted (the macOS cold-start settling window). Canceled by ANY later state
    /// callback (the settle resolved); if it fires instead, the state never settled — the wedged-grant
    /// shape (#429) — and the #295 re-grant banner is shown after all.
    private var unauthorizedSettleWork: DispatchWorkItem?
    private var cmdCharacteristic: CBCharacteristic?
    /// #613: true when a command would ACTUALLY reach the strap right now — the same condition `send()`
    /// requires (connected peripheral + a discovered command characteristic). The alarm-arm log and the
    /// persisted `alarm.lastArmConnected` diagnostic key off THIS, not merely a non-nil
    /// `connectedPeripheralUUID`, so an arm attempted before characteristic discovery finishes (e.g. mid
    /// state-restoration) is reported "queued" — matching whether `send()` dropped it — not a false "armed".
    private var commandChannelReady: Bool {
        state.connected && peripheral?.state == .connected && cmdCharacteristic != nil
    }
    /// #730: a DISABLE_ALARM that `send` dropped because the link wasn't up. The connect-settle hook
    /// re-issues ONLY this case, so a user who turned the alarm off while disconnected still gets the
    /// strap disarmed — without making every connect emit a DISABLE_ALARM for the majority who never
    /// armed one. Cleared once a disarm actually reaches the strap.
    private(set) var disarmPending = false
    private var cmdNotifyCharacteristic: CBCharacteristic?
    private var eventNotifyCharacteristic: CBCharacteristic?
    private var dataNotifyCharacteristic: CBCharacteristic?
    private var heartRateCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    /// #520 DIS: remembered at discovery, READ post-bond (see the #490 note — a 5/MG refuses standard
    /// reads before the link is encrypted). Serial + hardware revision are immutable, so they are read
    /// ONCE per connection (`disRead`), never re-polled like the battery.
    private var disSerialCharacteristic: CBCharacteristic?
    private var disHwRevCharacteristic: CBCharacteristic?
    private var disRead = false
    private var disSerial: String?
    private var disHwRev: String?
    /// EXPERIMENTAL WHOOP 5.0/MG puffin notify chars (fd4b0003/4/5/7), remembered at discovery so we
    /// can re-subscribe them AFTER bonding — the strap refuses them ("Authentication is insufficient")
    /// until the link is encrypted (issue #17).
    private var whoop5NotifyCharacteristics: [CBCharacteristic] = []
    private var reassembler = Reassembler()
    private var seq: UInt8 = 0
    private var didBond = false
    /// WHOOP 5/MG only: realtime HR has been armed (puffin TOGGLE_REALTIME_HR sent) once for this
    /// connection, so the post-bond callback re-firing on later `.withResponse` writes doesn't re-send it.
    private var whoop5RealtimeArmed = false
    /// Once-per-connection guard for the 5/MG offload kick (connectHandshakeDone + requestSync +
    /// startBackfillTimer). Stops the HISTORY_END acks re-entering didWriteValueFor from re-triggering
    /// the offload mid-stream (the 5/MG twin of the WHOOP4 connectHandshakeDone ack-storm guard).
    private var whoop5SessionStarted = false
    /// Backfill ACKs can arrive hundreds or thousands of times in one offload. Keep the strap log
    /// readable and avoid forcing SwiftUI to auto-scroll on every ACK row.
    private var historicalAckLogCounter = 0

    // WHOOP MG ECG ("Labrador") probe run state. All main-queue only, like every other probe here.
    /// The commands sent this run and what each came back with.
    private var ecgProbeSteps: [Whoop5EcgProbe.Step] = []
    /// Structural-triage hits: the empirical search for the packet TYPE these records arrive under.
    private var ecgProbeCandidates: [String] = []
    private var ecgProbePacketsSeen = 0
    /// Non-nil while the listen window is open; drives `ecgProbeArmed`.
    private var ecgProbeDeadline: Date?
    /// Supersedes a previous run's pending verdict timer when the user taps again.
    private var ecgProbeRunToken = 0
    private var clockRequested = false
    /// #700: retry count for GET_CLOCK when no correlation establishes before backfill. Capped at 3.
    private var clockRetries = 0
    private var intentionalDisconnect = false
    /// Consecutive `didFailToConnect` count, for the auto-reconnect backoff (#414). Reset to 0 on a
    /// successful connect; grows the reschedule delay so a strap that's genuinely out of range doesn't
    /// hammer Bluetooth (vs the disconnect path's flat 3s, which is fine for an already-bonded drop).
    private var failedConnectAttempts = 0
    /// Multi-WHOOP stale-pin recovery (#52). The identifier of the last peripheral that reached a GENUINE
    /// encrypted bond this run. When the pinned strap keeps refusing the bond but THIS one bonds fine, it's
    /// the live working strap the registry pin should point at. nil until any strap genuinely bonds.
    private var lastBondedPeripheralUUID: UUID?
    /// #78: consecutive "Encryption/Authentication is insufficient" CLIENT_HELLO refusals with NO genuine
    /// bond in between. When the strap genuinely refuses the encrypted bond (held by the WHOOP app, or a
    /// stale iOS pairing), this climbs and we surface actionable pairing-mode guidance; a single transient
    /// refusal right after a good bond (#74) stays quiet. Reset to 0 on any genuine bond, NOT on disconnect
    /// (so it accumulates across the reconnect loop). Distinct from `pinnedBondRefusals`, which is gated to
    /// the multi-WHOOP pinned peripheral and drives the #52 stale-pin handoff.
    private var bondRefusalStreak = 0
    /// #747 / #750: after the bond is refused persistently, pause auto-reconnect (stop hammering) and write
    /// a one-line epitaph. Fed by the SAME refusal events as `bondRefusalStreak`; its higher give-up
    /// threshold fires once the pairing HINT has had several cycles to be acted on. Reset on a genuine bond
    /// or an explicit user reconnect (so a manual retry re-arms auto-reconnect).
    private var bondGiveUp = BondRefusalGiveUp()
    /// True while auto-reconnect is PAUSED by the #747 give-up. The disconnect-rescan and the
    /// failed-connect backoff both consult this and skip scheduling a reconnect; a manual connect()/
    /// disconnect() clears it via `bondGiveUp.reset()`. Distinct from `intentionalDisconnect` so a paused
    /// link still reports its state honestly rather than looking like a user teardown.
    private var autoReconnectPausedForBondLoop = false
    /// When the bond-loop pause last tripped (or last salvage-probed). Drives the #78 hole-4 salvage
    /// probe's 10-minute floor (`shouldSalvageProbe`): a paused strap the user has since FREED self-heals
    /// on the next app-foreground instead of staying disconnected until a manual Connect, while a strap
    /// that's still held gets at most one bounded attempt per foreground per floor window. Set wherever
    /// the pause trips (#747 give-up + the #617 bond-then-quick-timeout detector, deliberately both:
    /// probing a #617-paused link costs one bounded cycle and self-heals the same way); nil whenever the
    /// pause clears. Never persisted.
    private var bondLoopPausedAt: Date?
    /// NotificationCenter token for the app-foreground salvage probe (installForegroundSalvageProbe).
    private var foregroundSalvageObserver: NSObjectProtocol?
    /// Multi-WHOOP stale-pin recovery (#52). Consecutive "Encryption/Authentication is insufficient" bond
    /// refusals on the CURRENTLY PINNED peripheral. A stale registry pin (pointing at a strap that bonds to
    /// the official app / isn't really here) makes `connect()` drop the strap that DOES bond and loop
    /// forever on the dead pin. Counts up here; cleared by any genuine bond (a healthy pin never accrues).
    private var pinnedBondRefusals = 0
    /// Refusals on the pinned strap before we hand the pin off to a different, live-bonding strap (#52). 3
    /// (not 1): a single "insufficient" can be a transient just-works race; three in a row on the pin while
    /// ANOTHER strap bonds fine is an unrecoverable stale pin. Mirrors the EmptySync/marginal-radio idiom.
    private let pinBondRefusalLimit = 3
    /// The strap we're mid-handoff onto during a #52 re-adoption (set in `readoptWorkingStrap`, cleared
    /// when that strap re-bonds in `noteGenuineBond`). Gates the one-time `connectedPeripheralUUID`
    /// re-publish that confirms the re-adoption to SourceCoordinator. nil whenever no handoff is in flight.
    private var readoptingTo: UUID?
    /// The strap family the user chose to pair. Drives which service we scan for
    /// and which service we discover after connecting. Hydrated from the persisted
    /// pick so restoration/reconnect after a relaunch target the right strap.
    private var selectedModel: WhoopModel = .persisted
    private var lastStandardHRLogAt: Date?

    /// True when the selected/connected strap is a WHOOP 5/MG. Read-only window onto the private
    /// `selectedModel` so a view can tell whether the firmware-alarm path is the experimental 5/MG one
    /// (see `armStrapAlarm`, which only arms a 5/MG when Experimental is on). #864: the iOS Smart-alarm
    /// UI needs this so it stops telling a 5/MG owner the strap is armed when, without Experimental, it
    /// isn't. Mirrors the Android `LiveState.whoop5Detected` signal the equivalent screen reads.
    var isWhoop5: Bool { selectedModel.deviceFamily == .whoop5 }

    /// True when the selected/connected strap is a WHOOP 4.0. Read-only window onto the private
    /// `selectedModel`, used to gate the 4.0-only reboot probe (Test Centre → Connection) in the UI.
    var isWhoop4: Bool { selectedModel.deviceFamily == .whoop4 }

    /// The 5-generation hardware variant resolved from the strap's Device Information Service (#520).
    /// `.unknown` until a DIS string lands — and `.unknown` is NOT MG, so an MG-only capability stays
    /// off until the hardware actually attests to itself.
    var whoop5Variant: Whoop5Variant {
        guard selectedModel.deviceFamily == .whoop5 else { return .unknown }
        return Whoop5Variant.from(serial: disSerial, hardwareRevision: disHwRev)
    }

    /// True only for a POSITIVELY identified WHOOP MG — the one variant with ECG electrodes. Gates the
    /// experimental ECG probe in both the UI and the command allowlist. A plain 5.0 (no electrodes), a
    /// 4.0, or an unidentified strap all read false.
    var isWhoop5MG: Bool { whoop5Variant.isMG }

    /// Stable device id; matches the server's existing device for sync parity. Overridable.
    /// Seeded from the init argument, then refined once in bootstrapStore() to the device registry's
    /// active id (still "my-whoop" today) before any store writes use it — see bootstrapStore().
    private(set) var deviceId: String
    /// Captured (device↔wall) correlation from GET_CLOCK; nil until the response lands.
    private(set) var clockRef: ClockRef?

    /// The strap's OWN clock extrapolated to right now (its RTC at the last GET_CLOCK + elapsed since).
    /// Used to judge live-gesture freshness in the strap's clock domain rather than wall time — so a
    /// real-time gesture is "now" and a replayed historical one is "old" REGARDLESS of how stale the
    /// strap RTC is (fix #72's straps). Falls back to wall-now when GET_CLOCK hasn't landed.
    private var strapClockNow: Int {
        let wallNow = Int(Date().timeIntervalSince1970)
        guard let ref = clockRef else { return wallNow }
        return ref.device + (wallNow - ref.wall)
    }

    public init(state: LiveState, deviceId: String = "my-whoop") {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        // WhoopStore.init is now async, so it can't run here.
        // bootstrapStore() is called once the CBCentralManager reaches poweredOn
        // (see centralManagerDidUpdateState), which guarantees the store is ready
        // before any BLE data arrives.
        self.collector = nil
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Restore identifier + background-capable central (foundation for M3 state restoration).
        #if os(iOS)
        // iOS background state preservation/restoration: the restore identifier is what makes
        // CoreBluetooth relaunch the app into the background and deliver willRestoreState after
        // a suspend-then-jettison. Without it, willRestoreState is never called.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
        #else
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
        // #78 hole-4: a paused-for-bond-loop strap gets one bounded salvage attempt per app-foreground.
        installForegroundSalvageProbe()
    }

    /// Build the WhoopStore + Collector + Backfiller asynchronously. Safe to call multiple
    /// times — bails out early if the collector is already initialised.
    func bootstrapStore() async {
        guard collector == nil else { return }
        // Surface store-open failures instead of swallowing them with `try?` (#222): a silent failure
        // here left `backfiller` nil forever and the only visible symptom was the downstream
        // "store not ready" tick, with no clue why. On iOS a background reconnect that opens the
        // data-protected store while the device is locked throws SQLITE_IOERR/CANTOPEN — logging the
        // code proves it; the periodic tick (see beginBackfill) re-attempts so it self-heals on unlock.
        let path: String
        do {
            path = try StorePaths.defaultDatabasePath()
        } catch {
            log("Backfill: bootstrap FAILED resolving DB path — \(error)")
            return
        }
        let store: WhoopStore
        do {
            store = try await WhoopStore(path: path)
        } catch {
            let ns = error as NSError
            log("Backfill: bootstrap FAILED opening store — \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
            return
        }
        // Route deviceId through the device registry: use the active device's id (migration v15 seeds
        // a single 'my-whoop' row as active, so this is still "my-whoop" today — zero behaviour change).
        // Guarded + best-effort: if the registry is empty/unreadable, deviceId stays as it was, so no
        // crash and no behaviour change. registryWriter is nonisolated/Sendable (the Pool manages
        // its own concurrency).
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        self.registryStore = registry
        if let activeId = try? registry.activeDeviceId(),
           !activeId.isEmpty {
            self.deviceId = activeId
        }
        try? await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 4.0")
        // Research toggle — OFF by default. When disabled the app is decoded-only and never
        // persists raw frames. Flip "enableRawCapture" in UserDefaults to capture raw again.
        let enableRawCapture = UserDefaults.standard.bool(forKey: "enableRawCapture")
        collector = Collector(store: store, deviceId: deviceId,
                              enableRawCapture: enableRawCapture)
        // The store can finish bootstrapping AFTER connect(model:) already ran (both wait on
        // poweredOn), so apply the family/clock configuration here too — whichever runs last wins.
        configureCollectorFamily()
        backfiller = Backfiller(store: store, deviceId: deviceId,
                                ackTrim: { [weak self] trim, endData in
                                    self?.ackHistoricalChunk(trim: trim, endData: endData)
                                },
                                enableRawCapture: enableRawCapture,
                                log: { [weak self] s in self?.log(s) },
                                rejectedSink: { [weak self] frames, trim, family in
                                    self?.archiveRejectedFrames(frames, trim: trim, family: family) ?? true
                                },
                                onChunk: { [weak self] decoded, console in
                                    if decoded { self?.state.decodedChunksThisSession += 1 }
                                    if console { self?.state.consoleChunksThisSession += 1 }
                                },
                                // Connection & Sync test mode (Test Centre): the cheap gate + tagged sink the
                                // Backfiller checks before building any .connection diagnostic line. The gate is
                                // one UserDefaults bool; nothing is emitted (or built) when the mode is off.
                                connectionActive: { TestCentre.active(.connection) },
                                connectionLog: { [weak self] s in self?.state.append(log: s, domain: .connection) },
                                // UNIVERSAL clock-drift: bank the strap's historical layout so the export's
                                // universal clock-drift line is firmware-aware on every export. Unconditional.
                                firmwareLayout: { [weak self] v in self?.state.setStrapFirmwareLayout(v) })
        // Strand: no server uploader/sync — all data stays on-device.

        // Retro-decode: when the decoder gains a historical layout (e.g. WHOOP 4.0 v25), re-run every
        // archived undecodable frame through it and insert whatever now decodes — the only path by
        // which already-acked banked history backfills after an update. Run ONCE per app version (no
        // manual decoder-version constant to forget to bump); idempotent if it re-runs (rows dedupe
        // by ts) and the archive is small, so the once-per-update cost is negligible. (#152)
        // Note: the archive carries no deviceId, so replayed rows attribute to the current strap.
        let replayKey = "rejectArchiveReplayedAppVersion"
        if UserDefaults.standard.string(forKey: replayKey) != AppChangelog.currentVersion {
            do {
                let rows = try await rejectedHistoryArchive.replay(into: store, deviceId: deviceId)
                if rows > 0 { log("Backfill: retro-decoded \(rows) record(s) from the reject archive after an update.") }
                // Advance the gate ONLY on success — a failed insert must retry next launch, because
                // the archive holds the only surviving copy of these records. (#152)
                UserDefaults.standard.set(AppChangelog.currentVersion, forKey: replayKey)
            } catch {
                log("Backfill: reject-archive retro-decode deferred (store insert failed) — will retry next launch.")
            }
        }

        // Battery "~X days left" seed (#7): `LiveState.batterySamples` is fed ONLY by live BLE events, so
        // after a reconnect the runtime estimate restarted from an empty buffer and ignored the discharge
        // history already on disk (Android seeds from its persisted battery table over a 14-day window;
        // iOS/macOS did not = divergence). Read the persisted SoC series for the active device over the last
        // 14 days and seed the live buffer once the store is up. The setter de-dupes against any points
        // already banked from live events this session, so a seed that races the first live reading is safe.
        // nil-SoC rows are dropped here (the buffer is non-optional %); a read failure is non-fatal, the
        // estimate just cold-starts as before.
        let seedNow = Int(Date().timeIntervalSince1970)
        let fourteenDays = 14 * 24 * 3600
        if let rows = try? await store.batterySamples(
            deviceId: deviceId, from: seedNow - fourteenDays, to: seedNow, limit: 2000) {
            let seed = rows.compactMap { row -> (ts: Int, soc: Double)? in
                guard let soc = row.soc else { return nil }
                return (ts: row.ts, soc: soc)
            }
            state.seedBatterySamples(seed)
        }
    }

    /// Designated initializer for testing and preview use: accepts a pre-built Collector.
    init(state: LiveState, deviceId: String = "my-whoop", collector: Collector?) {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        self.collector = collector
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Restore identifier + background-capable central (mirrors the production initializer
        // so a restored manager matches by identifier; only exercised by tests/previews).
        #if os(iOS)
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
        #else
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
        // #78 hole-4: a paused-for-bond-loop strap gets one bounded salvage attempt per app-foreground.
        installForegroundSalvageProbe()
    }

    // MARK: Public API

    /// USER-initiated connect (the Connect button, the scan flow, Add-a-WHOOP). The ONLY entry that
    /// re-arms a bond-loop give-up: a user gesture is an explicit "try again", so the streak + pause
    /// clear and auto-reconnect works again if it bonds. System-initiated paths (Bluetooth poweredOn,
    /// the deferred reconnect timers, the salvage probe) MUST use `connectFromSystem()` instead - the
    /// old single entry point let every poweredOn event (a Bluetooth toggle, a bluetoothd restart)
    /// silently un-pause the give-up and re-run the full refusal hammer, forever, one burst per event
    /// (#78 hole-2; Android's onBluetoothRadioOn always had the correct one-attempt-latched shape).
    public func connect(model: WhoopModel = .persisted) {
        // #747/#750: re-arm on the user's explicit retry: clear the give-up streak + pause so this fresh
        // attempt isn't immediately re-paused and the auto-reconnect works again if it bonds.
        if autoReconnectPausedForBondLoop {
            bondGiveUp.reset()
            autoReconnectPausedForBondLoop = false
            bondLoopPausedAt = nil
        }
        connectCore(model: model)
    }

    /// SYSTEM-initiated connect: byte-identical to `connect()` except it NEVER resets the bond-loop
    /// give-up (#78 hole-2). While paused this makes at most one bounded attempt (Android
    /// onBluetoothRadioOn parity): a refusal during it cannot write a second epitaph
    /// (`BondRefusalGiveUp.gaveUp` latches, `recordRefusal()` returns false) and the paused disconnect
    /// path schedules nothing afterwards, so the hammer loop cannot restart. A genuine bond still fully
    /// resets via the didWriteValueFor path, so a strap freed since the give-up self-heals.
    func connectFromSystem(model: WhoopModel = .persisted) {
        connectCore(model: model)
    }

    private func connectCore(model: WhoopModel) {
        intentionalDisconnect = false
        // Connection test mode: stamp when this connect attempt began so didConnect can report the connect
        // latency. A plain Date() assignment, no behaviour change; only read behind the .connection gate.
        connectAttemptStartedAt = Date()
        selectedModel = model
        // Battery "~X days left" fallback (#713): a 5/MG runs far longer than a 4.0, so point the estimator's
        // rated-life fallback at the connected family. The Today badge reads state.batteryEstimate (which uses
        // state.batteryRatedHours); without this it always assumed WHOOP 4.0 (108h).
        state.batteryRatedHours = model.deviceFamily == .whoop5
            ? BatteryEstimator.ratedLifeHoursWhoop5 : BatteryEstimator.ratedLifeHoursWhoop4
        // Frame the inbound stream for the chosen family (WHOOP 4.0 CRC8 vs WHOOP 5.0 CRC16/puffin)
        // and tell the router which decoder to use. Fresh per connection so no stale bytes carry over.
        reassembler = Reassembler(family: model.deviceFamily)
        router.family = model.deviceFamily
        // Live 5/MG persistence: point the Collector's decode at the selected family and install the
        // identity clock ref for a 5/MG (its live timestamps are already real unix). WHOOP 4.0 keeps
        // the GET_CLOCK correlation flow untouched. Re-applied after bootstrapStore builds the
        // collector so whichever runs last wins.
        configureCollectorFamily()
        guard central.state == .poweredOn else {
            log("Bluetooth not powered on (state=\(central.state.rawValue)); cannot scan yet")
            return
        }
        // Reuse the already-held peripheral ONLY if it's the strap we're pinned to. Without this guard a
        // multi-WHOOP switch attached straight back to the previously-held strap, ignoring the new active
        // device (registry said B, radio stayed on A). No pin (single-WHOOP) → always true, unchanged.
        if let p = peripheral, p.state == .connected, isPreferredPeripheral(p) {
            state.connected = true
            p.delegate = self
            log("Already connected to \(model.displayName) — refreshing services and notifications")
            discoverPrimaryServices(on: p)
            enableLiveNotifications(reason: "manual refresh")
            return
        }
        // Existing OS-level connections for this WHOOP family. CoreBluetooth keeps a bonded strap connected
        // across app sessions, and `retrieveConnectedPeripherals(...).first` previously adopted WHICHEVER
        // WHOOP macOS already had open — bypassing the scan (the only place the preferred-strap pin was
        // read), so a switch could never move off the wrong strap. Now: with a pin set, drop every OTHER
        // open WHOOP (so it stops holding the link) and attach ONLY to the pinned one. No pin → first-wins,
        // exactly as before. #52: this drop is what abandoned a strap that bonds fine when the pin was
        // STALE — `readoptWorkingStrap()` repoints the pin to the live-bonding strap first, so after a
        // handoff this loop drops the dead strap and attaches to the working one instead of vice-versa.
        let existing = central.retrieveConnectedPeripherals(withServices: [model.scanService])
        if preferredPeripheralUUID != nil {
            for other in existing where !isPreferredPeripheral(other) {
                log("Dropping non-active WHOOP connection \(other.identifier) — not the selected strap")
                central.cancelPeripheralConnection(other)
            }
        }
        if let p = existing.first(where: { isPreferredPeripheral($0) }) {
            log("Found existing \(model.displayName) connection \(p.identifier) — attaching")
            preparePeripheral(p)
            // Attach OUR OWN session even when CoreBluetooth reports the strap .connected. On Apple
            // platforms an LE link is shared system-wide, so a strap held by the WHOOP app, a prior NOOP
            // session, or the OS itself reads .connected while NOOP has NO session of its own yet. The old
            // .connected branch flipped state.connected = true and jumped straight to discovery + live
            // notifications, which then silently delivered nothing: the UI claimed "connected" but no data
            // ever flowed (#689). Routing through connect(_:) instead fires didConnect almost immediately
            // for an already-system-connected peripheral, which runs the normal discover, bond and notify
            // flow and only flips state.connected once OUR link is actually up, so we never falsely report
            // "connected" either.
            central.connect(p, options: nil)
            return
        }
        // Pinned to a specific strap that isn't already open → connect it DIRECTLY by identifier. A scan
        // would let any in-range WHOOP satisfy the connect and could land on the wrong one; the targeted
        // retrieve can only ever return the strap we asked for.
        if let preferred = preferredPeripheralUUID,
           let p = central.retrievePeripherals(withIdentifiers: [preferred]).first {
            log("Connecting to selected strap \(preferred) — targeted")
            preparePeripheral(p)
            central.connect(p, options: nil)
            return
        }
        startScan(for: model, allowFallback: true)
    }

    public func disconnect() {
        intentionalDisconnect = true
        cancelScanFallback()
        // A user-initiated teardown is a clean slate: clear any #80 marginal-radio fallback so the next
        // (manual) reconnect attempts the full R10/R11 stream again rather than inheriting old suspicion.
        marginalRadio.reset()
        postBondLoop.reset()   // #617: a clean teardown clears the bond-loop streak so a manual reconnect starts fresh
        bondGiveUp.reset()     // #747/#750: a clean teardown clears the bond-refusal give-up + un-pauses auto-reconnect
        autoReconnectPausedForBondLoop = false
        bondLoopPausedAt = nil
        state.reconnectGuide = nil   // #711: a user-initiated teardown resolves the re-pair guide (no longer looping)
        readoptingTo = nil   // #52: a clean teardown abandons any in-flight pin handoff
        standardHRFallback = false
        state.standardHRMode = nil
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        central.stopScan()
    }

    /// #78: fully RELEASE a strap when the user removes it from the Devices screen. Archiving the registry
    /// row alone left the strap connected — NOOP kept re-grabbing it (the 3s disconnect→reconnect timer, the
    /// targeted-connect pin, and iOS state restoration ALL still pointed at it), so it stayed connected and
    /// the user could never put it into pairing mode to re-pair (the #78 deadlock: a WHOOP that's connected
    /// can't show its blue pairing LEDs). Stop auto-reconnect, drop the live link, and clear the targeting +
    /// restoration references that point at this strap so NOOP lets go for good — until the user deliberately
    /// reconnects (which clears `intentionalDisconnect` again via connect()).
    public func forgetDevice(_ peripheralId: String?) {
        let target = peripheralId.flatMap { UUID(uuidString: $0) }
        let isCurrent = target == nil || peripheral?.identifier == target
        intentionalDisconnect = true            // defuses the disconnect→3s-reconnect loop's guard
        cancelScanFallback()
        readoptingTo = nil                       // abandon any in-flight #52 pin handoff
        // Clear the targeted-connect pin + the iOS state-restoration peripheral if they point at this strap,
        // so connect()/restoration can't re-target it.
        if target == nil || preferredPeripheralUUID == target { setPreferredPeripheral(nil) }
        if target == nil || restoredPeripheral?.identifier == target { restoredPeripheral = nil }
        // Drop the live BLE link so the strap is free to enter pairing mode.
        if isCurrent, let p = peripheral {
            central.cancelPeripheralConnection(p)
            peripheral = nil
            resetCharacteristics()
            state.connected = false
            state.bonded = false
            state.encryptedBond = false
            state.pairingHint = nil
            bondRefusalStreak = 0
        }
        // #747/#750 invariant: releasing a strap fully resets the give-up + pause (like disconnect()) so
        // a paused state can never outlive the strap it belonged to and wedge a later re-add.
        bondGiveUp.reset()
        autoReconnectPausedForBondLoop = false
        bondLoopPausedAt = nil
        central.stopScan()
        log("Device removed — released the strap: stopped auto-reconnect, dropped the link, cleared targeting. Put it in pairing mode (blue LEDs) to re-pair if you want it back. (#78)")
    }

    /// Switch which strap we'll connect to next: drop the current strap and clear the **sticky** bond
    /// state so a newly-picked model bonds fresh. `bonded` deliberately survives a disconnect (it means
    /// "this strap is paired"), but that left a user with BOTH a WHOOP 4 and a 5/MG unable to switch —
    /// `bonded` stayed true from the first strap, which hid the strap picker and kept the scan pointed at
    /// the old family's service. Call this when the user changes the strap selection.
    public func prepareForModelSwitch() {
        disconnect()
        state.connected = false
        state.bonded = false
        state.encryptedBond = false
    }

    /// Idle the engine before presenting an Add-a-WHOOP scan — but ONLY when we're not already
    /// connected to a strap of this same family. Opening the scan must NOT tear down a live, bonded
    /// same-family connection: a WHOOP 5/MG that just bonded refuses the encrypted re-bond on the
    /// reconnect ("Encryption/Authentication is insufficient") and loops forever (#74). A genuine
    /// family switch (e.g. a connected 4.0 while scanning for a 5/MG, or nothing connected) still
    /// idles via `prepareForModelSwitch()` so the scan starts clean. `connect()` reuses the live
    /// same-family peripheral on its "Already connected — refreshing" path.
    public func prepareForPresentScan(model: WhoopModel) {
        if state.connected, selectedModel.deviceFamily == model.deviceFamily {
            log("Add-a-WHOOP scan: keeping the live \(selectedModel.displayName) connection (#74) — presenting nearby straps without dropping it")
            return
        }
        prepareForModelSwitch()
    }

    // MARK: Bond-loop salvage probe (#78 hole-4)

    /// Minimum time since the pause tripped (or since the last probe) before another salvage probe may
    /// fire. 10 minutes: long enough that a still-held strap sees a handful of bounded attempts per day,
    /// short enough that a strap the user freed reconnects on the next natural app open.
    static let bondLoopSalvageFloorSeconds: TimeInterval = 10 * 60

    /// Pure gate for the one-shot bond-loop salvage probe: probe ONLY while the pause is latched, with no
    /// live link, no user teardown in force, and at least `bondLoopSalvageFloorSeconds` since the pause
    /// tripped (or since the previous probe re-stamped it). nil seconds = no trip timestamp = never probe.
    /// Pure so the never-hammer contract is pinned by unit tests without a CoreBluetooth seam.
    nonisolated static func shouldSalvageProbe(pausedForBondLoop: Bool,
                                               connected: Bool,
                                               intentionalDisconnect: Bool,
                                               secondsSincePauseTripped: TimeInterval?) -> Bool {
        guard pausedForBondLoop, !connected, !intentionalDisconnect else { return false }
        guard let s = secondsSincePauseTripped else { return false }
        return s >= bondLoopSalvageFloorSeconds
    }

    /// #78 hole-1: classify a "the strap refused the encrypted bond" error by its ATT CODE first,
    /// locale-proof. Foundation LOCALIZES CoreBluetooth error strings, so the old
    /// `localizedDescription.contains("encryption"/"authentication")` check silently never matched on a
    /// non-English device - no pairing hint, no give-up, no #52 pin handoff: exactly the futile reconnect
    /// loop #78 describes, still live for the (large) localized user base. Android was always immune (it
    /// matches GATT status ints 5/15). The English string match is kept as a FALLBACK only, never
    /// replaced: some CoreBluetooth paths surface plain NSErrors outside the CBATTError domain, and the
    /// code check must be additive so English-device detection can't regress. Pure + nonisolated so a
    /// unit test pins both routes without a CoreBluetooth seam.
    nonisolated static func isInsufficientAuthError(_ error: Error) -> Bool {
        if let att = error as? CBATTError,
           att.code == .insufficientEncryption || att.code == .insufficientAuthentication {
            return true
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("encryption") || text.contains("authentication")
    }

    /// #78 hole-4: ONE bounded salvage attempt while the bond-loop pause is latched, fired on
    /// app-foreground (see `installForegroundSalvageProbe`). This is what makes the give-up provably
    /// unable to strand a strap the user has since freed: a genuine bond on the probe fully resets the
    /// pause via the normal didWriteValueFor path, while a still-refusing strap costs one attempt per
    /// foreground per 10-minute floor and NEVER re-enters the hammer loop (the give-up stays latched, no
    /// second epitaph, the paused disconnect path schedules nothing). Re-stamps `bondLoopPausedAt` so
    /// back-to-back foregrounds can't chain probes.
    func salvageProbeIfBondLoopPaused(now: Date = Date()) {
        let since = bondLoopPausedAt.map { now.timeIntervalSince($0) }
        guard BLEManager.shouldSalvageProbe(pausedForBondLoop: autoReconnectPausedForBondLoop,
                                            connected: state.connected,
                                            intentionalDisconnect: intentionalDisconnect,
                                            secondsSincePauseTripped: since) else { return }
        bondLoopPausedAt = now   // re-floor: max one probe per foreground AND per 10-min window
        log("Bond-loop pause: one salvage probe (the strap may have been freed since the give-up) - the give-up stays latched")
        connectFromSystem()
    }

    /// Observe the app-foreground notification and run the salvage probe. Installed once per manager from
    /// init; self-contained here so the probe needs no per-target scene wiring. iOS and macOS only (the
    /// watch never builds this file).
    private func installForegroundSalvageProbe() {
        #if os(iOS) || os(macOS)
        #if os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #else
        let name = NSApplication.didBecomeActiveNotification
        #endif
        foregroundSalvageObserver = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.salvageProbeIfBondLoopPaused() }
        }
        #endif
    }

    // MARK: Multi-WHOOP (additive — inert on the single-WHOOP path)

    /// Pin connections to ONE specific strap by its CBPeripheral.identifier.uuidString. The app sets
    /// this to the active device's persisted `peripheralId` when it has one; pass nil to clear it
    /// (back to "connect to the first WHOOP discovered" — the single-WHOOP default). An unparseable
    /// string clears the pin rather than wedging the scan. Only `didDiscover` reads it; setting it
    /// does NOT start/stop/redirect an in-flight connection on its own.
    public func setPreferredPeripheral(_ uuidString: String?) {
        let resolved = uuidString.flatMap { UUID(uuidString: $0) }   // nil for unparseable → clears the pin
        // A genuinely NEW pin starts the #52 refusal streak clean — the old streak belonged to the strap we
        // were pinned to before, not this one. Re-applying the SAME pin (the common no-op when the active
        // device doesn't change) deliberately preserves an in-progress count. A pin change to anything other
        // than the in-flight handoff target also abandons that handoff (the user/registry re-targeted).
        if resolved != preferredPeripheralUUID {
            pinnedBondRefusals = 0
            if resolved != readoptingTo { readoptingTo = nil }
        }
        preferredPeripheralUUID = resolved
    }

    /// True when `p` is the strap we're pinned to — or when no pin is set (the single-WHOOP default, so
    /// any WHOOP is acceptable and the legacy first-found behaviour is preserved byte-for-byte). The
    /// attach/reconnect paths consult this so they can never adopt the WRONG already-connected strap on a
    /// multi-WHOOP setup (the registry said one strap, the radio stayed on another — multi-WHOOP switch bug).
    private func isPreferredPeripheral(_ p: CBPeripheral) -> Bool {
        guard let preferred = preferredPeripheralUUID else { return true }
        return p.identifier == preferred
    }

    /// #52: a strap reached a GENUINE encrypted bond. Remember its identifier as the live working strap
    /// (the candidate the registry pin should follow if a stale pin keeps refusing), and clear the
    /// pin-refusal streak — any healthy bond proves the current path is fine, so a later transient
    /// "insufficient" starts counting from zero rather than inheriting old suspicion. If this bond is the
    /// strap we're mid-handoff onto (#52 re-adoption), CONFIRM it to SourceCoordinator now: republish its
    /// identity on `connectedPeripheralUUID` while `encryptedBond` is true, the one emission of that seam
    /// that proves a genuine bond — which is exactly how SourceCoordinator tells a vetted re-adoption from
    /// the ordinary pre-bond `didConnect` publish (where `encryptedBond` is still false).
    private func noteGenuineBond(of p: CBPeripheral) {
        lastBondedPeripheralUUID = p.identifier
        pinnedBondRefusals = 0
        if readoptingTo == p.identifier {
            readoptingTo = nil
            log("Multi-WHOOP (#52): working strap bonded — confirming re-adoption to the registry.")
            // nil first so the publisher's removeDuplicates() can't swallow the value when this strap was
            // already the last-connected uuid (the nil emission is ignored downstream — the uuid guard).
            connectedPeripheralUUID = nil
            connectedPeripheralUUID = p.identifier.uuidString
        }
    }

    /// #52: the pinned strap (`stalePin`) has refused the encrypted bond `pinBondRefusalLimit` times in a
    /// row while a DIFFERENT strap (`working`) bonds fine — the registry pin is stale and is making
    /// connect() abandon the strap that actually works. Hand the pin off to the working strap: re-point our
    /// own pin so connect()/didDiscover stop dropping the working strap, then reconnect onto it. Once it
    /// re-bonds, `noteGenuineBond` republishes its identity to SourceCoordinator (with `encryptedBond` true)
    /// so the registry re-adopts it. The normal first-connect/identity path (encryptedBond false at
    /// didConnect) is untouched, so this never fires on the correct-pin or single-strap path.
    private func readoptWorkingStrap(_ working: UUID, awayFrom stalePin: UUID) {
        log("Multi-WHOOP (#52): pinned strap refused the bond \(pinnedBondRefusals)× but another strap is bonded — handing the pin off to the working strap.")
        preferredPeripheralUUID = working
        pinnedBondRefusals = 0
        readoptingTo = working
        // The stale pin made us drop the working strap; reconnect so the now-correct pin lands on it. If
        // it's somehow still the held+bonded peripheral, confirm the re-adoption straight away instead.
        if let p = peripheral, p.identifier == working, p.state == .connected, state.encryptedBond {
            noteGenuineBond(of: p)
        } else if !intentionalDisconnect {
            connect(model: selectedModel)
        }
    }

    /// Re-point which device id live WHOOP samples store under, when the active WHOOP changes (a
    /// WHOOP↔WHOOP switch via the registry). Only the `SourceCoordinator` calls this, and only when a
    /// DIFFERENT registered WHOOP becomes active — the single-WHOOP path leaves the seeded "my-whoop" id
    /// in place (bootstrapStore set it; this is never called), so that path is byte-for-byte unchanged.
    /// Sets the manager's `deviceId` AND re-points the in-flight Collector/Backfiller so the very next
    /// flush / standard-HR persist / historical finishChunk attributes new samples to the new id —
    /// without waiting for a relaunch or a full strap-switch store rebuild. The Collector reads
    /// `deviceId` at persist time (live + 0x2A37 standard-HR paths) and the Backfiller at finishChunk,
    /// so updating their mutable `deviceId` here is sufficient. Additive: nothing on the single-WHOOP
    /// path invokes it, so with one WHOOP the id stays "my-whoop" throughout.
    public func setActiveDeviceId(_ id: String) {
        guard !id.isEmpty else { return }
        deviceId = id
        collector?.deviceId = id
        backfiller?.deviceId = id
    }

    /// Add-a-WHOOP wizard: scan the selected family's WHOOP service and surface every nearby strap in
    /// `discoveredWhoops` WITHOUT auto-connecting. Turns on the `isPresentingScan` flag that diverts
    /// `didDiscover` to collect-not-connect, and uses duplicate-allowing scanning so RSSI refreshes.
    /// The wizard MUST call `stopWhoopScan()` before any normal connect resumes — this mode owns the
    /// central while active. No-op-to-the-connect-path: it never touches `peripheral`/bond state.
    public func scanForWhoops() {
        guard central.state == .poweredOn else {
            log("Add-a-WHOOP scan: Bluetooth not powered on (state=\(central.state.rawValue))")
            return
        }
        cancelScanFallback()            // no family-rotation timer should fire during a present-scan
        isPresentingScan = true
        discoveredWhoops = []           // fresh list each time the wizard opens the scan
        central.stopScan()
        // Allow duplicates so the wizard's RSSI/signal readout updates as straps move.
        central.scanForPeripherals(
            withServices: [selectedModel.scanService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        log("Add-a-WHOOP scan: presenting nearby \(selectedModel.displayName) straps")
    }

    /// End the Add-a-WHOOP present-scan: stop scanning and clear `isPresentingScan` so `didDiscover`
    /// returns to its normal auto-connect behaviour. Safe to call when not presenting (idempotent).
    public func stopWhoopScan() {
        guard isPresentingScan else { return }
        isPresentingScan = false
        central.stopScan()
        log("Add-a-WHOOP scan: stopped")
    }

    /// Apply the raw-outbox retention policy (24h synced window / 50MB unsynced cap).
    /// Called when the app enters the background; no-op without a concrete store.
    public func pruneRaw() {
        Task { @MainActor in await collector?.prune() }
    }

    /// Light storage summary for the UI (decoded rows, raw batches, raw bytes). nil without a store.
    public func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        await collector?.storageStats()
    }

    /// Capture raw accelerometer (type-43 IMU) frames on demand for a bounded window, then stop.
    /// Persists raw even when the global research toggle is off (that's the point: on-demand, not
    /// 24/7). The Collector's window auto-expires at its deadline so a dropped stop can't leak raw.
    public func captureRawAccel(seconds: TimeInterval = 30) {
        guard !rawCaptureInFlight else {
            log("Raw-accel capture: already in flight — ignoring")
            return
        }
        rawCaptureInFlight = true
        let secs = RawCaptureWindow.clamp(seconds)
        collector?.beginRawCapture(seconds: secs)
        send(.startRawData, payload: [0x01])
        send(.toggleIMUMode, payload: [0x01])
        log("Raw-accel capture: started for \(secs)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self else { return }
            // Only stop the raw stream if the 24/7 research toggle is OFF.  When it's ON, the
            // continuous stream must keep running — we just flush/upload the bounded window we
            // captured without halting the wider session.
            if !UserDefaults.standard.bool(forKey: "enableRawCapture") {
                self.send(.stopRawData, payload: [0x01])
            }
            self.rawCaptureInFlight = false
            Task { @MainActor in
                await self.collector?.endRawCapture()
            }
            self.log("Raw-accel capture: stopped + flushed")
        }
    }

    /// Send a command to the WHOOP strap.
    /// - Parameters:
    ///   - command: The command to send.
    ///   - payload: Command payload bytes (default `[0x00]`).
    ///   - writeType: BLE write type; defaults to `.withoutResponse` so all existing call
    ///     sites are unaffected. Pass `.withResponse` for acked commands (e.g. historicalDataResult).
    public func send(_ command: WhoopCommand, payload: [UInt8] = [0x00],
                     writeType: CBCharacteristicWriteType = .withoutResponse) {
        // #314 parity: CoreBluetooth already covers both Android defects here — this `p.state == .connected`
        // guard makes a write a no-op once the radio powers off (no DeadObjectException to crash on), and
        // centralManagerDidUpdateState publishes state.connected = false on .poweredOff, so the iOS/macOS UI
        // can't show a stale-connected link. The Android fix re-creates both behaviours; no Swift change needed.
        guard state.connected, let p = peripheral, p.state == .connected, let ch = cmdCharacteristic else {
            let reason = state.connected ? "command characteristic unavailable" : "not connected"
            log("send(\(command.label)) ignored — \(reason)")
            return
        }
        // The MG ECG family is 5/MG-only by construction, and the WHOOP 4.0 branch further down has no
        // allowlist of its own — so without this a caller bug could frame an ECG opcode for a 4.0, which
        // has neither the electrodes nor this command space. Dropping it HERE keeps the invariant inside
        // send(), rather than resting entirely on every caller remembering to check.
        if isEcgCommand(command), selectedModel.deviceFamily != .whoop5 {
            log("send(\(command.label)) skipped — MG ECG commands are WHOOP 5/MG only")
            return
        }
        // WHOOP 5.0/MG uses puffin (CRC16) command framing, not the WHOOP4 frame. The realtime-HR toggle
        // is hardware-confirmed (issue #17 — a 5/MG owner saw live HR over a public build), which proves
        // the strap does act on puffin-framed commands. We now also send haptics (buzz) and the
        // firmware-alarm family on that same proven transport. Everything else stays dropped.
        // WHOOP 4.0 is unaffected.
        if selectedModel.deviceFamily == .whoop5 {
            // Allowlist: live (toggle HR, buzz), the firmware-alarm family (set/get/run/disable —
            // same command numbers as WHOOP4 over puffin framing; the 5/MG REVISION_4/REVISION_2
            // bodies are built at the call sites and pad4 covers their 20-/2-byte bodies), the two
            // historical-offload commands, and the clock pair. SEND_HISTORICAL_DATA triggers the
            // offload; HISTORICAL_DATA_RESULT acks each HISTORY_END to walk the trim cursor.
            // SET_CLOCK/GET_CLOCK are MANDATORY before history: an un-clocked WHOOP 5 doesn't save
            // sensor data to flash at all ("RTC timestamp … is invalid; not saving data to flash"),
            // so offloads complete with zero body frames — hardware-validated, same 8-byte WHOOP4
            // payload over puffin framing. (#78 fork)
            guard command == .toggleRealtimeHR || command == .runHapticsPattern
                || command == .setAlarmTime || command == .getAlarmTime
                || command == .runAlarm || command == .disableAlarm
                // REBOOT_STRAP (29) over puffin: opcode shared with 4.0, framing is the puffin form built
                // below. NOT hardware-confirmed on 5/MG — rebootStrap() logs the COMMAND_RESPONSE so a strap
                // log confirms whether the frame is accepted. User-initiated + confirmation-gated only.
                || command == .rebootStrap
                // GET_EXTENDED_BATTERY_INFO (98) over puffin: read-only opcode probe (#592) — a real WHOOP 5
                // (fw 50.38.1.0) already answered this number. Driven only by probeExtendedBatteryInfo().
                || command == .getExtendedBatteryInfo
                // GET_BODY_LOCATION_AND_STATUS (84) over puffin: read-only opcode probe (#690). Driven only by
                // probeBodyLocationAndStatus() (user-initiated, Test Centre gated); decoded to a diagnostic
                // report only, never gates wear/scoring. Whether 5/MG answers is a hardware check.
                || command == .getBodyLocationAndStatus
                // START_FF_KEY_EXCHANGE (117) / SEND_NEXT_FF (118) over puffin: the READ-ONLY feature-flag
                // ENUMERATION probe (#761) — it reads the strap's own flag NAMES and writes no value. Gated
                // harder than the probes above: allowed ONLY while a probe is actually in flight, so on a
                // 5/MG a default install can never form these bytes. NOTE this whole allowlist is inside the
                // `deviceFamily == .whoop5` branch — WHOOP 4.0 has no send allowlist at all, so on a 4.0 the
                // only thing keeping 117/118 off the wire is probeFeatureFlags()'s own Test Centre gate.
                // Same practical result, different mechanism, and worth knowing because the 4.0 is the
                // family with a published key dump to reproduce and so the likely first runner.
                // The SET verbs (120 SET_FF_VALUE / 119 SET_DEVICE_CONFIG_VALUE) keep their own separate
                // opt-in clauses below and are never sent from this path. Driven only by
                // probeFeatureFlags() (user-initiated, Test Centre gated).
                || ((command == .startFeatureFlagKeyExchange || command == .sendNextFeatureFlag)
                    && featureFlagReport != nil)
                // ABORT_HISTORICAL_TRANSMITS (20) over puffin: stop an offload already in flight. Allowed
                // ONLY while one actually is, so a default install can never form these bytes on a 5/MG —
                // and the gate is the same state the command is about. Non-destructive: the strap frees
                // records on our HISTORY_END ack, not on this, so an aborted drain re-offloads intact.
                || (command == .abortHistoricalTransmits && backfilling)
                // GET_DEVICE_CONFIG_VALUE (121) / GET_FF_VALUE (128) over puffin: the READ-ONLY
                // device-config READ probe (#103) — it asks for a key's VALUE and writes none. Gated the
                // same way as 117/118: allowed ONLY while a probe is actually in flight, and the opcode
                // must additionally satisfy DeviceConfigReadProbe.isReadOnlyOpcode, the same predicate a
                // unit test proves rejects SET_FF_VALUE(120) and SET_DEVICE_CONFIG_VALUE(119). Those two
                // keep their own separate opt-in clauses below and are never sent from this path. Driven
                // only by probeDeviceConfigValues() (user-initiated, Test Centre gated).
                || (DeviceConfigReadProbe.isReadOnlyOpcode(command.rawValue) && deviceConfigReport != nil)
                || command == .sendHistoricalData || command == .historicalDataResult
                || command == .setClock || command == .getClock
                // SET_CONFIG / SET_FF_VALUE (120), ENABLE direction — the R22 deep-stream unlock. Allowed
                // only while the deep-data experiment is opted in, and only for a KEY and a VALUE the gate
                // recognises: one of the sixteen R22 flags carrying that key's own enable value. The clause
                // this replaces was opcode-only, so it admitted ANY feature-flag key with ANY value for as
                // long as the opt-in happened to be on — the same weakness #907 closed on opcode 119.
                // Driven only by enableWhoop5DeepData(). (#174)
                || FeatureFlagWriteGate.admitsEnableWrite(opcode: command.rawValue,
                                                          payload: payload,
                                                          deepDataOptIn: PuffinExperiment.deepDataEnabled)
                // SET_FF_VALUE (120), DISABLE direction — the undo. Gated on a disable run being in flight
                // rather than on the opt-in, exactly like the 128 read-back clause below, and restricted to
                // `featureFlagOffValue`. The opt-in CANNOT gate this: `deepDataEnabled` is @AppStorage bound
                // straight to the Settings switch, so it is already false by the time the user confirms the
                // undo the switch itself offered — gating on it made the whole toggle-off path dead (every
                // write refused here, and the run's own guard returning early). Gating on the run is also
                // narrower the other way: with the opt-in merely left on, no off value reaches the wire
                // unless a run is genuinely walking its plan. Driven only by disableWhoop5DeepData(). (#174)
                || FeatureFlagWriteGate.admitsDisableWrite(opcode: command.rawValue,
                                                           payload: payload,
                                                           disableRunInFlight: r22DisableRun != nil)
                // GET_FF_VALUE (128) as the disable run's mandatory READ-BACK. Gated on a disable run being
                // in flight, exactly like the read probes' 121/128 clause above, so a default install can
                // never form these bytes. The write ack is not trusted; this is what proves the clear.
                || (FeatureFlagWriteGate.isReadBackOpcode(command.rawValue) && r22DisableRun != nil)
                // SET_DEVICE_CONFIG (the Broadcast-HR flag) is allowed ONLY while that opt-in is on —
                // it writes one persistent device-config value so the strap advertises standard HR.
                // Reversible; driven only by setBroadcastHr(_:). (#181)
                || (command == .setDeviceConfig && PuffinExperiment.broadcastHrEnabled)
                // The WHOOP MG ECG ("Labrador") family — allowed ONLY when BOTH gates hold: the
                // Experimental opt-in is on AND the strap has POSITIVELY attested itself an MG over the
                // Device Information Service. A plain 5.0 has no electrodes and an unidentified strap
                // proves nothing, so `.unknown` keeps these dropped. Every one is user-initiated and
                // confirmation-gated at the call site; none is ever sent automatically. (See
                // `Whoop5Ecg` for the payloads and the safety rationale.)
                || (isEcgCommand(command) && ecgCommandsAllowed && isWhoop5MG) else {
                log("send(\(command.label)) skipped — no WHOOP 5/MG framing for this command yet")
                return
            }
            // WHOOP 5/MG haptics differ from WHOOP 4.0 on BOTH the opcode AND the payload (#48, decoded
            // from the working "maverick" app's binary). Opcode: 0x13, not RUN_HAPTICS_PATTERN=79 (a real-MG
            // capture showed the strap rejecting 79 with COMMAND_RESPONSE result=0x03). Payload: the maverick
            // haptic body [0x01, effects(8), loopControl(u16 LE), overallLoop] — here the "notify" preset
            // (effects 47,152), NOT the 4.0 [patternId, loops, …]. puffinCommandFrame pads the inner to a
            // 4-byte boundary, which this 12-byte payload needs. WHOOP 4.0 is untouched (79 + its own frame).
            let isHaptics = command == .runHapticsPattern
            let puffinCmd: UInt8 = isHaptics ? 0x13 : command.rawValue
            let puffinPayload: [UInt8] = isHaptics ? [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0, 0, 0] : payload
            seq = seq &+ 1
            let frame = puffinCommandFrame(cmd: puffinCmd, seq: seq, payload: puffinPayload)
            p.writeValue(Data(frame), for: ch, type: writeType)
            let cmdNote = isHaptics ? " cmd=0x13" : ""
            if command == .historicalDataResult {
                historicalAckLogCounter += 1
                if historicalAckLogCounter == 1 || historicalAckLogCounter.isMultiple(of: 25) {
                    log("→ \(command.label) ack #\(historicalAckLogCounter) payload=\(hex(puffinPayload)) (puffin)")
                }
                return
            }
            log("→ \(command.label) payload=\(hex(puffinPayload)) (puffin\(cmdNote))")
            return
        }
        seq = seq &+ 1
        let frame = command.frame(seq: seq, payload: payload)
        p.writeValue(Data(frame), for: ch, type: writeType)
        log("→ \(command.label) payload=\(hex(payload))")
    }

    /// Point the Collector's live decode at the selected family. For a 5/MG, also install an identity
    /// clock ref: live puffin REALTIME_DATA timestamps are already real-unix seconds, so device==wall
    /// makes toWall a no-op (the same idiom the Backfiller uses for 5/MG history). For a WHOOP 4.0 the
    /// collector takes the manager's GET_CLOCK correlation (nil until it lands — the normal 4.0 flow);
    /// this also evicts a stale identity ref a prior 5/MG session installed when the user switches
    /// straps, which would otherwise mis-stamp WHOOP4 device-epoch frames as wall-clock. Idempotent;
    /// called from connect() AND after the async store bootstrap builds the collector, so the
    /// configuration lands regardless of which finishes first.
    private func configureCollectorFamily() {
        collector?.family = selectedModel.deviceFamily
        if selectedModel.deviceFamily == .whoop5 {
            let now = Int(Date().timeIntervalSince1970)
            collector?.clockRef = ClockRef(device: now, wall: now)
        } else {
            collector?.clockRef = clockRef   // the WHOOP4 correlation, nil until GET_CLOCK lands
        }
    }

    /// Refresh the battery reading on demand. Source is FAMILY-SPECIFIC (#77): on a WHOOP 4.0 the
    /// standard 0x2A19 characteristic is a STUB that reports a constant 100 — the real charge only
    /// comes from the proprietary GET_BATTERY_LEVEL command (COMMAND_RESPONSE, u16/10). Reading both
    /// flashed 100% before the true value corrected it (and a stub notification could revert a real
    /// 94% back to 100%). So WHOOP 4 uses ONLY the command; WHOOP 5/MG uses ONLY 0x2A19.
    public func refreshBattery() {
        guard state.connected, let p = peripheral, p.state == .connected else {
            log("refreshBattery ignored — not connected")
            return
        }

        if selectedModel.deviceFamily == .whoop4 {
            send(.getBatteryLevel, payload: [0x00])
            return
        }

        if let batteryCharacteristic {
            if batteryCharacteristic.properties.contains(.read) {
                p.readValue(for: batteryCharacteristic)
                log("Reading standard Battery Level")
            } else {
                log("Battery Level read unavailable; waiting for notifications")
            }
        } else {
            log("Battery Level characteristic unavailable")
        }
    }

    /// Ack one HISTORY_END chunk so the strap may trim it. Confirmed write — the strap forgets
    /// the chunk once this lands (link-layer half of safe-trim; decoded + raw already persisted).
    ///
    /// High-freq-sync ack form (matches re/sync_openwhoop.py, which pulled 762 type-47 records):
    /// HISTORICAL_DATA_RESULT(23) payload = `[0x01] + end_data`, where end_data is the verbatim
    /// 8 bytes of the HISTORY_END metadata.data[10:18] (trim u32 at [10:14] + next u32 at [14:18]).
    /// The `trim` argument (= end_data first u32) is already persisted as the strap_trim cursor by
    /// the Backfiller; it is passed here only for logging.
    func ackHistoricalChunk(trim: UInt32, endData: [UInt8]) {
        send(.historicalDataResult, payload: [0x01] + endData, writeType: .withResponse)
        // Progress signal for the "Syncing strap history…" UI (#77). Same main-queue delegate path as
        // the other state mutations (e.g. lastSyncedAt in exitBackfilling). NOT historicalAckLogCounter
        // — that's a puffin-write log throttle that never increments on WHOOP 4.
        state.syncChunksThisSession += 1
    }

    // MARK: Backfill helpers

    /// Start a historical-offload session: tell the store machine to begin, flip the routing
    /// flag, kick the strap with sendHistoricalData, and arm the idle timeout.
    @discardableResult
    private func beginBackfill() -> Bool {
        // #700: if backfill is about to start and we STILL have no clock correlation, re-send
        // GET_CLOCK. The strap may have silently dropped the first response (observed on a reporter's
        // WHOOP 4.0 — GET_CLOCK sent, no reply, entire session decodes under IDENTITY fallback, all
        // rows land on the current day). Capped at 3 retries to avoid flooding.
        if clockRef == nil && clockRetries < 3 {
            clockRetries += 1
            log("Clock: no correlation yet — re-sending GET_CLOCK (retry \(clockRetries)/3)")
            send(.getClock, payload: [])
            send(.getClock, payload: [0x00])
        } else if clockRef == nil, let newest = strapNewestTs {
            // #700 fallback: GET_CLOCK never responded even after retries. Derive a rough correlation
            // from the Data Range's newest-banked timestamp (already parsed, always answered). The
            // offset is approximate (the newest record could be minutes old) but vastly better than
            // identity (offset 0), which mis-dates entire nights.
            let wall = Int(Date().timeIntervalSince1970)
            let ref = ClockRef(device: newest, wall: wall)
            clockRef = ref
            collector?.clockRef = ref
            backfiller?.clockRef = ref
            log("Clock: GET_CLOCK unresponsive — derived rough correlation from Data Range (device=\(newest) wall=\(wall), offset \(wall - newest)s)")
        }
        // Never offload before the connect handshake has run: a racing foreground/restore trigger
        // firing SEND_HISTORICAL ahead of hello/SET_CLOCK was part of the storm that stopped serving.
        guard connectHandshakeDone else {
            log("Backfill: deferred — connect handshake not done yet")
            return false
        }
        guard let backfiller else {
            // Store not built yet (bootstrapStore failed or hasn't run). Do NOT force live HR — the
            // type-47 backfill is the metric source. RE-ATTEMPT the bootstrap here so a transient
            // first-open failure self-heals: on iOS the data-protected store is unreadable while the
            // phone is locked, so a background-reconnect bootstrap can fail and, with no retry, stay
            // dead forever (#222). Each periodic tick now retries; the first one that runs after the
            // device is unlocked rebuilds the store and backfill proceeds. bootstrapStore() guards on
            // `collector == nil`, so this is a no-op once the store is up.
            log("Backfill: store not ready — re-attempting bootstrap, will retry next tick")
            Task { @MainActor in await self.bootstrapStore() }
            return false
        }
        // Capture the family at begin() (not init): selectedModel is reliably set by connect() before any
        // backfill starts, whereas bootstrapStore() can build the Backfiller before the family is known.
        // #42/#364: consecutiveAutoContinues > 0 means this offload is re-kicked after an EARLIER session in
        // the same burst banked rows — tell the backfiller so its no-cursor END reads as "caught up", not
        // "no banked history / charge to 100%". A fresh offload (count 0) keeps the honest guidance.
        backfiller.begin(family: selectedModel.deviceFamily, continuedAfterRows: consecutiveAutoContinues > 0)
        backfilling = true
        state.backfilling = true
        state.syncChunksThisSession = 0
        state.rejectedFramesThisSession = 0
        state.rejectedFramesUnarchived = 0
        state.decodedChunksThisSession = 0
        state.consoleChunksThisSession = 0
        state.r22FlagsAccepted = 0
        state.deepPacketsThisSession = 0
        historicalAckLogCounter = 0
        // Payload MUST be [0x00], NOT empty: verified on-device that this strap serves type-47 only with
        // [0x00] (empty → 0 frames on a clean stable link with ~2k records pending); the Mac ground-truth
        // offload (re/sync_openwhoop.py, re/diagnose_biometrics.py) uses [0x00] too. Plain offload — the
        // strap streams HISTORY_START → type-47 records → HISTORY_END (acked) … → HISTORY_COMPLETE.
        send(.sendHistoricalData, payload: [0x00], writeType: .withResponse)
        armBackfillTimeout()
        log("Backfill: session started — historical offload requested")
        return true
    }

    /// Feed a frame to the Backfiller preserving exact arrival order. Frames are appended
    /// synchronously (delegate order) and drained sequentially in small slices, so START /
    /// data / END chunk assembly is never reordered while the UI still gets time to paint.
    private func routeBackfillFrame(_ frame: [UInt8]) {
        backfillFrameQueue.append(frame)
        guard !backfillDraining else { return }
        backfillDraining = true
        Task { @MainActor in await drainBackfillFrames() }
    }

    private func drainBackfillFrames() async {
        while !backfillFrameQueue.isEmpty {
            let count = min(Self.backfillDrainBatchSize, backfillFrameQueue.count)
            let batch = Array(backfillFrameQueue.prefix(count))
            backfillFrameQueue.removeFirst(count)

            for f in batch {
                await backfiller?.ingest(f)
                afterBackfillIngest()
                if !backfilling {
                    backfillFrameQueue.removeAll(keepingCapacity: true)
                    break
                }
            }

            if !backfillFrameQueue.isEmpty {
                await Task.yield()
            }
        }
        backfillDraining = false
    }

    /// Called after every Backfiller.ingest completes. If the Backfiller has consumed all
    /// historical data (isBackfilling drops to false), exit the backfill session cleanly.
    private func afterBackfillIngest() {
        guard backfilling, backfiller?.isBackfilling == false else { return }
        exitBackfilling(reason: "HISTORY_COMPLETE")
    }

    /// True when a frame is part of the historical offload (HISTORICAL_DATA=47, EVENT=48,
    /// METADATA=49 / puffin METADATA=56, CONSOLE_LOGS=50) rather than the live stream (REALTIME_DATA=40,
    /// REALTIME_RAW_DATA=43). The live type-43 raw flood streams continuously and unprompted on
    /// this firmware, so the backfill idle-watchdog must NOT be re-armed by it — only by genuine
    /// offload progress — otherwise the session can neither complete nor time out.
    static func isOffloadFrame(_ frame: [UInt8], family: DeviceFamily) -> Bool {
        // The type byte sits at the inner-record start: frame[4] on WHOOP 4.0, frame[8] on WHOOP 5/MG
        // (the puffin envelope is 4 bytes longer). Reading frame[4] for a puffin frame misclassifies
        // EVERY offload frame as live-flood and routes nothing to the Backfiller.
        let typeIndex = family == .whoop5 ? 8 : 4
        guard frame.count > typeIndex else { return false }
        switch frame[typeIndex] {
        case 47, 48, 49, 50, 56: return true   // HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS
        default: return false              // 40 REALTIME_DATA, 43 REALTIME_RAW_DATA (live flood)
        }
    }

    /// Re-arm the idle watchdog. Called on every offload frame during backfill so the timer resets
    /// as long as the strap keeps sending HISTORY; if the strap goes silent the timer fires and we
    /// exit the session (the durable strap_trim cursor means the next session resumes where we left
    /// off). Timeout is generous (60 s, not 20 s): the unstoppable ~2/s type-43 raw flood eats BLE
    /// airtime, so genuine offload frames can arrive in bursts with multi-second lulls between chunks
    /// — a short watchdog cut sessions short mid-drain. Longer = more records drained per session.
    static let backfillIdleTimeoutSeconds = 60
    private func armBackfillTimeout() {
        backfillTimeout?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.backfiller?.timeoutFired()
            self.exitBackfilling(reason: "timeout")
        }
        backfillTimeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.backfillIdleTimeoutSeconds), execute: item)
    }

    /// Tear down the backfill session. Does NOT auto-start live HR: the periodic type-47 backfill
    /// is the primary metric source now, mirroring how WHOOP syncs. Live HR is opt-in only (the
    /// manual "Start HR" button in LiveView). Between backfills the Collector sees only the live
    /// type-43 flood, which extractStreams ignores — the data comes from the next periodic offload.
    /// Stop an offload that is part-way through, at the user's request.
    ///
    /// NOOP has been able to START a drain since day one (`sendHistoricalData`) with no way to stop it:
    /// a session ran to HISTORY_COMPLETE, the backfill timeout, or a dropped link. On a strap with a
    /// large banked history that is a long time to be stuck, and the only escape was walking out of
    /// Bluetooth range.
    ///
    /// NOTHING IS LOST. The strap frees banked records when NOOP acks a HISTORY_END, so records already
    /// acked are persisted and records not yet acked stay in flash and re-offload on the next sync. This
    /// is a stop, not a trim, and no cursor moves.
    ///
    /// The local teardown does NOT depend on the strap honouring opcode 20. `exitBackfilling` runs
    /// either way — the same path the timeout and disconnect already use, including the drain loop's
    /// `!backfilling` check that discards queued frames — so a firmware that ignores the abort degrades
    /// to exactly today's behaviour (frames keep arriving and are dropped) rather than leaving the UI
    /// wedged in "Syncing". That is deliberate: the opcode is confirmed in use on WHOOP 4.0 by OpenStrap
    /// Edge but is NOT hardware-confirmed here, on either family.
    ///
    /// Twin of Android `abortBackfill()`.
    public func abortBackfill() {
        guard backfilling else {
            log("Abort sync ignored — no offload in flight")
            return
        }
        // Send before tearing down: the 5/MG allowlist admits opcode 20 only while `backfilling` is
        // still true, so ordering here is load-bearing, not stylistic.
        if state.connected {
            // Body `[0x00]`, matching the only hands-on use of this opcode (OpenStrap Edge sends
            // `const [0x00]`) rather than an empty body — the same b3 convention `sendHistoricalData`
            // already uses here, where an empty body was verified NOT to work.
            send(.abortHistoricalTransmits, payload: [0x00], writeType: .withResponse)
            log("Abort sync: ABORT_HISTORICAL_TRANSMITS (20) sent; unacked records stay on the strap")
        } else {
            log("Abort sync: not connected — tearing down the local session only")
        }
        // The reason string is deliberately NOT one `exitBackfilling` classifies. Only "HISTORY_COMPLETE"
        // stamps `lastSyncedAt` and only "timeout" raises a sync error; everything else falls through
        // leaving both untouched — which is exactly right for an abort. A cancelled sync is neither a
        // success nor a failure: nothing was lost, and the next sync re-offloads what was left.
        // If a future edit starts classifying more reasons, this one must stay in the fall-through.
        exitBackfilling(reason: "aborted by user")
    }

    private func exitBackfilling(reason: String) {
        guard backfilling else { return }
        backfilling = false
        state.backfilling = false
        // #174: a backfill just ended. Start (or extend) the deep-packet cooldown from this instant so
        // any type-0x2F records the strap flushes in the seconds after the session aren't miscounted as
        // the live R22 stream — they're the offload's tail.
        lastOffloadFrameAt = Date()
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        log("Backfill: session ended — reason=\(reason)")
        // Inactivity reminder (#419): read-only hook on the natural offload completion (no cadence
        // change). Only on a true HISTORY_COMPLETE — a timeout/disconnect didn't bring a fresh window.
        if reason == "HISTORY_COMPLETE" { maybeBuzzInactivity() }
        // Success-side summary (#150 forensics): we logged failures (decoded-to-0) but never successes,
        // so a strap log couldn't tell a banking strap from a broken one. Emit the per-session persistence
        // tally whenever anything actually landed — the win-rate signal a log previously lacked.
        if let bf = backfiller,
           let summary = Backfiller.sessionSummaryLine(rows: bf.sessionRowsPersisted, motion: bf.sessionMotionRows, skinTemp: bf.sessionSkinTempRows, nights: bf.sessionNights) {
            log(summary)
            // #67: WHERE the rows landed + WHY (the clock ref that decoded them). A reset-RTC strap banks
            // last night into the past; this line makes the misdating self-evident in the strap log instead
            // of leaving "persisted N rows across 1 night(s)" looking like a clean sync.
            if let diag = Backfiller.sessionClockDiagLine(nightKeys: bf.sessionNightKeys,
                                                          device: bf.sessionClockDevice,
                                                          wall: bf.sessionClockWall,
                                                          usedIdentityRef: bf.sessionUsedIdentityRef) {
                log(diag)
            }
        }
        // #520: the motion-magnitude diagnostic for this session. Emitted independently of the summary
        // above — a caught-up session banks no rows but can still have decoded records — and silent when
        // nothing carried the field, which a WHOOP 4.0 never does.
        if let bf = backfiller,
           let dynLine = bf.sessionDynAccel.logLine(threshold: dynAccelStillThresholdG) {
            log(dynLine)
        }
        // Connection test mode: the offload OUTCOME the readout's lastOffloadResult id binds. Gated
        // zero-cost (the .connection bool is read before any string is built). Diagnostic only - it reads
        // the same per-session tallies the existing summary above does, changing no offload behaviour. A
        // timeout/idle-cap exit is a STALL; a HISTORY_COMPLETE with rows is a clean complete; with none it
        // is an empty (console-only) cycle.
        if TestCentre.active(.connection), let bf = backfiller {
            let rows = bf.sessionRowsPersisted
            let result: String
            if reason == "timeout" {
                result = "stalled (idle timeout, rows=\(rows) so far)"
            } else if reason == "HISTORY_COMPLETE" {
                result = rows > 0
                    ? "complete rows=\(rows) nights=\(bf.sessionNights)"
                    : "empty (console only, no sensor records)"
            } else {
                result = "\(reason) rows=\(rows)"
            }
            state.append(log: "offload result=\(result)", domain: .connection)
        }
        // #547 RE-POLLUTION: this session's ingest gate dropped bad-clock records, so the strap has a
        // wandering clock and may have banked similar garbage on an OLDER build whose gate was weaker. Arm
        // a heal re-run so the next analyze tick purges any such pollution — not gated behind the one-shot
        // done flag. Pure UserDefaults set (no engine handle here); IntelligenceEngine honours it next tick.
        if (backfiller?.sessionDroppedImplausible ?? 0) > 0 {
            IntelligenceEngine.requestTimestampReheal()
        }
        // #364 auto-continue spin-detector: did THIS session move the strap's trim cursor? Compare the
        // Backfiller's current high-water trim against where it stood when the previous session ended.
        // A frozen cursor (console-only / strap refusing to trim) ⇒ don't re-kick (it would spin forever).
        let currentTrim = backfiller?.lastAckedTrim
        let trimAdvanced = currentTrim != nil && currentTrim != lastSessionEndTrim
        lastSessionEndTrim = currentTrim
        // #324/#928: a strap whose newest banked record is dated in the FUTURE (RTC relatched ahead) is
        // future-dated regardless of HOW this offload ended — a deep future-dated backlog TIMES OUT as
        // readily as it completes (the reporter's #324 session ended on timeout, not HISTORY_COMPLETE).
        // Compute the banner once so BOTH outcomes name the real cause instead of "strap went quiet".
        let wallNowForBanner = Int(Date().timeIntervalSince1970)
        let futureClockBanner = BLEManager.futureDatedStrapBanner(
            strapNewestTs: strapNewestTs, wallNowUnix: wallNowForBanner)
        if futureClockBanner != nil {
            let aheadH = ((strapNewestTs ?? 0) - wallNowForBanner) / 3600
            log("Backfill: the strap's newest banked record is \(aheadH)h AHEAD of the wall clock (#324/#928) - clock set in the future; showing the future-clock banner and importing nothing from this range.")
        }
        // Honest sync outcome for a cloud-free user (mirrors Android exitBackfilling, ed6a31d):
        // HISTORY_COMPLETE stamps lastSyncedAt + clears any error; the idle-watchdog timeout surfaces
        // a non-silent error. A disconnect mid-sync bypasses this path (didDisconnectPeripheral resets
        // the flags directly) — that's not a sync failure, and the next connect re-offloads.
        // #battery: maintain the empty-offload backoff counter for EVERY exit reason (twin of Android
        // consecutiveEmptyOffloads). A 0-row session — clean HISTORY_COMPLETE-empty OR an idle-timeout STALL
        // — feeds BackfillPolicy's exponential backoff so the periodic poll stops spinning on a strap
        // handing over nothing; any banked rows reset it, and a productive auto-continue tail doesn't count.
        if (backfiller?.sessionRowsPersisted ?? 0) > 0 { consecutiveEmptyOffloads = 0 }
        else if consecutiveAutoContinues == 0 { consecutiveEmptyOffloads += 1 }
        if reason == "HISTORY_COMPLETE" {
            state.lastSyncedAt = Date().timeIntervalSince1970
            // #77 / #91: a sync that COMPLETED but discarded records must not read as a clean
            // "History synced" — the wording distinguishes bytes saved on this Mac from bytes the
            // full archive could not preserve, so "saved" is never claimed falsely.
            let archived = state.rejectedFramesThisSession
            let unarchived = state.rejectedFramesUnarchived
            // Classify this completed offload (pure, unit-tested in EmptyBankingClassifierTests).
            let banking = BLEManager.classifyCompletedOffload(
                decodedChunks: state.decodedChunksThisSession,
                archivedFrames: archived,
                unarchivedFrames: unarchived,
                consoleChunks: state.consoleChunksThisSession,
                rowsPersisted: backfiller?.sessionRowsPersisted ?? 0)
            let bankedSensorRecords = banking.bankedSensorRecords
            // #42: the empty tail of an auto-continue burst (consecutiveAutoContinues > 0) isn't a "banked
            // nothing" sync — an EARLIER session in the same burst handed over real rows and this pass just
            // confirms we're caught up. Don't surface the "charge to 100%" framing, and don't count it toward
            // the sustained-empty streak (the productive session already cleared it).
            let productiveBurstTail = consecutiveAutoContinues > 0
            let bankedNothing = banking.bankedNothing && !productiveBurstTail
            let sustainedEmpty = productiveBurstTail ? false : emptySyncTracker.recordCompletedSync(
                bankedSensorRecords: bankedSensorRecords, consoleOnly: banking.bankedNothing)
            // #612: expose the streak as a queryable flag (previously only reached UI as `lastSyncError`
            // free text below). Set on EVERY HISTORY_COMPLETE, not just the empty branch, so a productive
            // sync clears it immediately.
            state.sustainedEmptyOffload = sustainedEmpty
            // #57 debug: write-health for the export. Distinguish "rows actually landed" from "an offload
            // STALLED on a persist failure" — the latter (usually a restore without a restart) is otherwise
            // invisible in a report that just shows "0 synced".
            let du = UserDefaults.standard
            if (backfiller?.sessionRowsPersisted ?? 0) > 0 { du.set(Date().timeIntervalSince1970, forKey: "sync.lastWriteOkAt") }
            if backfiller?.persistStalled == true { du.set(Date().timeIntervalSince1970, forKey: "sync.lastWriteStalledAt") }
            if unarchived > 0 {
                state.lastSyncError = "Synced, but \(archived + unarchived) record(s) couldn't be decoded (unrecognised strap firmware layout), and the on-device archive is full - the \(unarchived) newest weren't preserved. Please share a strap log so the layout can be mapped."
            } else if archived > 0 {
                state.lastSyncError = "Synced, but \(archived) record(s) couldn't be decoded (unrecognised strap firmware layout). The raw bytes were saved on this Mac - please share a strap log so the layout can be mapped."
            } else if bankedNothing {
                // #77 / #214 family: the offload COMPLETED but the strap handed over no sensor records
                // at all — either console/diagnostic output across many chunks, OR a near-empty
                // metadata-only completion (zero rows persisted) — i.e. it isn't banking history to
                // flash (its RTC has lost sync). Only escalate to the actionable banner once emptiness
                // is SUSTAINED (#126): a single empty cycle on an otherwise-banking strap stays silent.
                let detail = state.consoleChunksThisSession >= 3
                    ? "console-only across \(state.consoleChunksThisSession) chunks"
                    : "metadata-only, 0 sensor rows persisted"
                log("Backfill: completed but the strap banked no sensor history (\(detail)); consecutive empty syncs = \(emptySyncTracker.consecutiveEmptySyncs).")
                state.lastSyncError = sustainedEmpty
                    ? "Synced, but your strap had no stored history to hand over - only its diagnostic output. This usually means its clock has lost sync, so it isn't saving data to flash. Fully charge it to 100%, then reconnect, and it should start banking again."
                    : nil
            } else if let futureBanner = futureClockBanner {
                // #324/#928: the strap banked records but its newest is dated implausibly in the FUTURE
                // (RTC relatched ahead). #773 drops the future-dated samples so nothing is misfiled, but
                // the "banked something" path above would otherwise report a clean sync and leave the
                // user with no data and no reason. Name the real cause + the strap-side remedy.
                state.lastSyncError = futureBanner
            } else {
                state.lastSyncError = nil
            }
            // #580: a 5/MG that reaches a real HISTORY_COMPLETE with banked sensor records proves its
            // history offload IS working — clear the experimental note + empty streak so the home state
            // stops saying "history sync experimental".
            if selectedModel.deviceFamily == .whoop5, bankedSensorRecords {
                whoop5EmptyOffload.reset()
                state.historySyncExperimental = false
            }
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
            // NOTE: the auto-continue streak is NOT reset here. A HISTORY_COMPLETE is no longer assumed to
            // mean "caught up" (#25): a strap whose firmware segments a deep offload into many small
            // HISTORY_COMPLETE slices would otherwise reset the streak on every slice and never engage the
            // 6-per-connection cap. The streak is cleared only once shouldAutoContinue proves we're actually
            // caught up — inside maybeAutoContinueBackfill's else path, fired below for BOTH exit reasons.
        } else if reason == "timeout" {
            // #580: distinguish a genuine WHOOP-4 "strap went quiet mid-sync" from a WHOOP 5/MG whose
            // firmware acks SEND_HISTORICAL_DATA but never emits a single type-0x2F offload frame. The
            // 5/MG case isn't a failure — live HR is streaming fine over 0x2A37, the history offload is
            // just experimental/empty on that firmware. "Banked" = this offload made ANY offload progress
            // (chunks acked, rows persisted, or deep packets seen); an empty 5/MG offload has none.
            let bankedThisOffload = state.syncChunksThisSession > 0
                || (backfiller?.sessionRowsPersisted ?? 0) > 0
                || state.deepPacketsThisSession > 0
            if selectedModel.deviceFamily == .whoop5 {
                let crossed = whoop5EmptyOffload.recordOffload(bankedRecords: bankedThisOffload)
                if whoop5EmptyOffload.historyEmpty {
                    // Honest home state (#580): NOT a sync error — connected + live HR, history experimental.
                    state.historySyncExperimental = true
                    state.lastSyncError = nil
                    if crossed {
                        log("Backfill: WHOOP 5/MG offload empty \(whoop5EmptyOffload.consecutiveEmpty)× — history sync is experimental on 5.0; surfacing 'connected, history experimental' (not a sync error) and backing off the bounce loop.")
                    }
                } else {
                    // Either the first empty cycle (could be the strap waking flash — stay quiet, don't
                    // cry failure) OR a banking offload that just cleared the streak (recovery — drop the
                    // experimental note). Both want a clean, error-free state.
                    state.historySyncExperimental = false
                    state.lastSyncError = nil
                }
            } else {
                // #324/#928: a future-dated strap TIMES OUT on its deep future-dated backlog — that's not
                // "the strap went quiet", it's the clock being set ahead. Prefer the honest future-clock
                // banner so the reporter's timeout case (the common one) names the real cause + remedy.
                state.lastSyncError = futureClockBanner
                    ?? "Sync interrupted - the strap went quiet. It will retry on the next sync."
            }
        }
        checkStrapLiveness()         // safety-net: strap ahead of us AND our frontier frozen ⇒ stuck?
        // #364 / #25: a session that ended on the 60s IDLE cap OR on a true HISTORY_COMPLETE while still
        // connected, with more backlog to fetch and the trim still advancing, immediately re-kicks another
        // offload instead of tearing down to wait the 15-min floor — so a deep oldest-first backlog drains
        // in back-to-back ~60s passes rather than one-per-15-min. #25: fire on HISTORY_COMPLETE too — some
        // straps segment a deep overnight offload into many small HISTORY_COMPLETE slices and would
        // otherwise stall between slices until the periodic floor. The pure shouldAutoContinue guards make
        // this safe: a genuinely caught-up strap (newest within behindGapSeconds of the frontier and 0 rows)
        // returns false and stops; that else path is also where the consecutive streak is cleared. Bounded
        // by the consecutive-cap and the spin-detector inside the pure predicate either way.
        if reason == "timeout" || reason == "HISTORY_COMPLETE" {
            maybeAutoContinueBackfill(trimAdvanced: trimAdvanced,
                                      rowsPersisted: backfiller?.sessionRowsPersisted ?? 0)
        }
    }

    /// #364 / #25: evaluate (and, if warranted, fire) an immediate back-to-back backfill after a 60s
    /// idle-cap exit OR a HISTORY_COMPLETE. The "more backlog remains" test needs our persisted data
    /// frontier (max HR ts), which only the Collector can read, so this hops onto a Task exactly like
    /// `checkStrapLiveness`. The decision itself is the pure `BackfillContinuation.shouldAutoContinue` so it
    /// stays unit-testable; this method only gathers the inputs, bumps the counter (or clears it on the
    /// caught-up else path — see #25), and re-kicks via the SAME gated requestSync path (so it still
    /// respects connected/bonded and can't double-start). The `.autoContinue` trigger ⇒
    /// the BackfillPolicy 15-min floor is bypassed for this expedited continuation (the cap is the guard).
    /// `trimAdvanced` is the spin-detector signal computed in exitBackfilling (did this session move the
    /// trim cursor vs the previous one) — passed in because exitBackfilling has already advanced
    /// `lastSessionEndTrim` past the comparison point by the time this Task runs.
    private func maybeAutoContinueBackfill(trimAdvanced: Bool, rowsPersisted: Int) {
        // Cheap pre-checks first (no Task if we already know we won't continue): still connected, under
        // the cap, and the trim moved. The frontier read only happens when those already hold.
        guard state.connected, state.bonded else { return }
        let newest = strapNewestTs
        let count = consecutiveAutoContinues
        Task { @MainActor in
            let frontier = await collector?.latestHRSampleTs() ?? nil
            let wallNow = Int(Date().timeIntervalSince1970)   // #928: real wall clock, at decision time
            let stillConnected = state.connected && state.bonded
            guard BackfillContinuation.shouldAutoContinue(
                stillConnected: stillConnected,
                strapNewestTs: newest,
                ourFrontierTs: frontier,
                wallNowUnix: wallNow,
                rowsPersistedThisSession: rowsPersisted,
                lastTrimAdvanced: trimAdvanced,
                consecutiveCount: count) else {
                // #1012: name the stop honestly when the future-clock gate is what ended the chain —
                // without this line the log just goes quiet after one pass and a strap-log export can't
                // tell "caught up" from "future-dated range refused". Fires ONLY when 2b would otherwise
                // have continued (still connected, rows banked, trim advanced, under the cap), so a
                // frozen-trim / cap / disconnect stop is never misattributed to the clock.
                if stillConnected, rowsPersisted > 0, trimAdvanced,
                   count < BackfillContinuation.defaultMaxAutoContinues,
                   BackfillContinuation.isFutureDatedNewest(newest, wallNowUnix: wallNow) {
                    let aheadH = ((newest ?? wallNow) - wallNow) / 3600
                    log("Backfill: not auto-continuing (#1012) - the strap-reported newest banked record reads \(aheadH)h AHEAD of the wall clock, so the range is future-dated and the strap clock is likely wrong (#928). Stopping after one pass instead of chasing future-dated ranges; the periodic sync keeps draining across connects.")
                }
                // No re-kick. THIS is the real "we're done draining" signal (#25): clear the auto-continue
                // streak so the NEXT deep backlog (e.g. after the app's been off again) gets a fresh budget
                // of re-kicks. Reset here — NOT unconditionally on every HISTORY_COMPLETE — so a strap that
                // slices one offload into many completions can't keep resetting the cap and spin forever.
                // EXCEPTION: if we stopped because the per-connection CAP is hit, leave the streak at/over
                // the cap so it STAYS engaged for the rest of this connection (the 15-min floor takes over);
                // zeroing it here would immediately re-arm the cap and let a runaway strap spin again.
                if count < BackfillContinuation.defaultMaxAutoContinues {
                    consecutiveAutoContinues = 0
                }
                return
            }
            // Guard against a race: a real backfill may already have re-started (periodic/connect) in the
            // gap before this Task ran. requestSync's own gate (!backfilling) handles that, but skip the
            // log/counter churn if so.
            guard !backfilling else { return }
            consecutiveAutoContinues += 1
            log("Backfill: auto-continuing (#364/#451) — the trim advanced and the strap is still handing over real records (frontier \(frontier.map(String.init) ?? "?"), strap-reported newest \(newest.map(String.init) ?? "?")); re-kicking offload \(consecutiveAutoContinues)/\(BackfillContinuation.defaultMaxAutoContinues) without waiting the 15-min floor.")
            // .autoContinue bypasses the BackfillPolicy floor (the whole point — don't wait 15 min);
            // requestSync still re-checks connected/bonded/not-backfilling before kicking, and the
            // consecutive-cap above is the runaway guard.
            requestSync(.autoContinue)
        }
    }

    /// On-device archive for HISTORICAL_DATA record frames that failed decode (#77 / #91).
    private let rejectedHistoryArchive = RawHistoryArchive()

    /// Durably archive undecodable record frames (append-only JSONL, fsynced) BEFORE the Backfiller
    /// acks the trim — the user's only remaining copy of an unmapped firmware's records once the
    /// strap frees them, and the corpus a later layout mapping re-ingests. Updates the session
    /// counters that drive the honest sync status. Returns false ONLY on a genuine write failure,
    /// which makes the Backfiller hold the cursor/ack so the strap re-sends the chunk (no data loss
    /// either way). Frames carry sensor payloads, not identifiers — no serials/MACs are archived.
    private func archiveRejectedFrames(_ frames: [[UInt8]], trim: UInt32, family: DeviceFamily) -> Bool {
        switch rejectedHistoryArchive.archive(frames, trim: trim, family: family) {
        case .written(let count):
            state.rejectedFramesThisSession += count
            return true
        case .capReached(let count):
            // Cap reached: succeed WITHOUT writing (wedging the offload over a full archive would be
            // worse; ample sample bytes exist by now), counted separately so the sync status never
            // claims "saved" for bytes that were not.
            state.rejectedFramesUnarchived += count
            log("Backfill: rejected-frame archive is FULL — \(count) frame(s) NOT preserved (acking anyway so the offload can finish)")
            return true
        case .failed:
            log("Backfill: rejected-frame archive FAILED — holding ack so the strap re-sends")
            return false
        }
    }

    /// After an offload, judge liveness: stuck = strap reports records newer than our frontier AND our
    /// frontier (max persisted HR ts) hasn't advanced for the detector window. Off-wrist / caught up
    /// (strap not ahead) is NOT stuck. On stuck: attempt recovery (defensive EXIT + SET_CLOCK) and raise
    /// the surface. Best-effort; reads the frontier via the Collector (which owns the concrete store).
    private func checkStrapLiveness() {
        let strapNewest = strapNewestTs
        Task { @MainActor in
            let frontier = await collector?.latestHRSampleTs()
            let front: Int? = frontier ?? nil
            let now = Date().timeIntervalSince1970
            let stuck = stuckDetector.observe(strapNewestTs: strapNewest,
                                              ourFrontierTs: front,
                                              now: now)
            state.strapNeedsReboot = stuck
            if stuck {
                log("Watchdog: behind + frontier frozen — recovery (exit high-freq + SET_CLOCK)")
                send(.exitHighFreqSync, payload: [0x00])
                sendSetClockBothForms()
            }
        }
    }

    /// Pure decision: should the periodic timer kick off another historical offload? Only when
    /// connected + bonded and NOT already mid-backfill. Extracted so the gate is unit-testable
    /// without a CoreBluetooth seam. Note this intentionally does NOT consult `backfillStarted`
    /// (that flag guards the once-per-connect INITIAL kick); the periodic re-trigger is separate.
    static func shouldRunPeriodicBackfill(connected: Bool, bonded: Bool, backfilling: Bool) -> Bool {
        connected && bonded && !backfilling
    }

    /// Pure classification of a COMPLETED (HISTORY_COMPLETE) offload, extracted from exitBackfilling so
    /// it's unit-testable without a CoreBluetooth seam (EmptyBankingClassifierTests).
    /// - `bankedSensorRecords`: the strap handed over real sensor records — decoded, or
    ///   undecodable-but-archived (either way its clock is banking to flash).
    /// - `bankedNothing` (#77/#120/#214): the offload completed but banked NO sensor records at all,
    ///   in EITHER shape — console-only across ≥3 diagnostic chunks, OR a near-empty metadata-only
    ///   completion (zero rows persisted) with fewer than 3 console frames. The #214 broadening is the
    ///   `rowsPersisted == 0` arm: before it, a metadata-only completion slipped through silently. The
    ///   sustained-streak gate (EmptySyncTracker) still decides whether the banner fires.
    nonisolated static func classifyCompletedOffload(decodedChunks: Int, archivedFrames: Int,
                                                     unarchivedFrames: Int, consoleChunks: Int,
                                                     rowsPersisted: Int)
        -> (bankedSensorRecords: Bool, bankedNothing: Bool) {
        let bankedSensorRecords = decodedChunks > 0 || archivedFrames > 0 || unarchivedFrames > 0
        let bankedNothing = !bankedSensorRecords && (consoleChunks >= 3 || rowsPersisted == 0)
        return (bankedSensorRecords, bankedNothing)
    }

    /// #324/#928: the post-sync banner for a strap whose clock is set in the FUTURE. Unlike the
    /// "clock lost / not banking" case (`bankedNothing`), this strap DOES bank records every pass — but
    /// its RTC relatched to a future base, so every banked timestamp reads ahead of the wall clock and
    /// NOOP won't import them (importing would misfile the night days or years ahead). The existing
    /// clock-lost banner is gated on empty syncs and never fires here, so this failure mode was silent
    /// (#324). Returns the user-facing string when the strap-reported newest record is future-dated
    /// beyond the 48 h skew allowance (`BackfillContinuation.isFutureDatedNewest`), else nil. Pure and
    /// deterministic — one detection is decisive (nothing legitimate banks 48 h ahead), so no streak
    /// gate is needed. Mirrors Android `futureDatedStrapBanner`.
    nonisolated static func futureDatedStrapBanner(strapNewestTs: Int?, wallNowUnix: Int) -> String? {
        guard BackfillContinuation.isFutureDatedNewest(strapNewestTs, wallNowUnix: wallNowUnix) else { return nil }
        return "Synced, but your strap's clock is set in the future - its banked history is dated ahead of "
            + "today, so NOOP can't trust those timestamps and didn't import them (importing them would "
            + "misfile your data days or years ahead). Fully charge the strap to 100% and power-cycle it so "
            + "its clock re-syncs, then reconnect."
    }

    /// Start (or restart) the periodic backfill timer. Each tick re-runs the type-47 historical
    /// offload while connected+bonded and not already backfilling — the primary metric sync.
    // MARK: - Keep-alive (always-ping + liveness watchdog)

    /// Enable live HR and remember we want it re-armed by keep-alive.
    /// Some WHOOP firmware acknowledges TOGGLE_REALTIME_HR but only emits usable live samples once
    /// the R10/R11 realtime stream is also on. Keep that stream scoped to the Live tab and stop it
    /// on disappear so it does not permanently compete with historical offload.
    public func startRealtime() {
        screenWantsRealtime = true
        state.liveFeedActive = true   // drives the menu-bar Start/Stop label off the real intent
        // The user explicitly (re-)asked for the full stream by opening Live / tapping Start HR — give the
        // heavy R10/R11 burst another chance even if a prior marginal-radio fallback had tripped. If the
        // radio still can't take it, the detector will simply trip again. (#80) This is screen-only intent;
        // the continuous-capture path does NOT reset the fallback (it's a passive background want).
        marginalRadio.reset()
        standardHRFallback = false
        state.standardHRMode = nil
        enableLiveNotifications(reason: "start realtime")
        send(.sendR10R11Realtime, payload: [0x01])   // the heavy burst rides alongside the toggle on Live
        reconcileRealtime()                          // arms TOGGLE_REALTIME_HR(1) on the off→on edge
        realtimeArmedAt = Date()       // start the arm→drop stopwatch for the marginal-radio detector
    }
    /// Stop the Live-tab realtime streams. The lightweight 0x2A37 HR keeps recording if firmware emits it.
    /// The TOGGLE only actually disarms if the continuous-capture preference no longer wants it either —
    /// the reconciler sends it on the on→off edge of the combined want, so a Live screen closing while
    /// continuous capture is on keeps the dense stream flowing.
    public func stopRealtime() {
        screenWantsRealtime = false
        state.liveFeedActive = false   // flip the menu-bar toggle back to "Start live feed"
        // Always stop the heavy R10/R11 burst when the Live screen leaves — it's the battery-hungry part
        // and is only ever wanted while a live screen is up. The lightweight TOGGLE/0x2A37 R-R stream is
        // what continuous capture keeps; the reconciler decides whether to disarm that.
        send(.sendR10R11Realtime, payload: [0x00])
        reconcileRealtime()
    }

    /// The "Continuous HRV capture" preference flipped: hold the realtime stream open with no Live screen
    /// visible (true) or release it (false), then reconcile. Driven from the app model. Mirrors the
    /// Android `setKeepStreamForData`. #927: also called with the UNCHANGED preference when "overnight
    /// only" flips, purely to re-run the reconciler with the fresh window gate.
    public func setKeepRealtimeForData(_ keep: Bool) {
        keepRealtimeForData = keep
        reconcileRealtime()
    }

    /// #477 (Settings): battery-% at/below which the offload cadence stretches while discharging (0 = off).
    /// Applies on the next re-arm; a live sync in flight is never interrupted.
    public func setLowBatteryOffloadThrottle(_ thresholdPct: Int) {
        lowBatteryOffloadPct = thresholdPct
    }

    /// #477 (Settings): pause the background continuous-HRV stream when the strap is low. Keyed on the
    /// STRAP's battery like the offload lever — pass the same threshold; engages at/below it (0 = off).
    /// Reconciles now.
    public func setPauseCaptureOnPowerSave(_ enabled: Bool, thresholdPct: Int) {
        pauseCaptureBatteryPct = enabled ? thresholdPct : 0
        reconcileRealtime()
    }


    /// #477: the connected STRAP's (battery-%, isCharging) — WHOOP, and the same for Oura/Fitbit. Power
    /// saving keys off the strap, not the phone, because the levers reduce how much the STRAP transmits
    /// (fewer offloads, no continuous stream) and so extend the strap's life when it wasn't charged in
    /// time. Unknown (disconnected / not yet read) → (100, false), so it fails SAFE (never throttles
    /// without a real low reading; a disconnected strap has nothing to throttle anyway).
    private func batteryPctAndCharging() -> (pct: Int, charging: Bool) {
        (state.batteryPct.map { Int($0.rounded()) } ?? 100, state.charging == true)
    }

    /// The next periodic-offload interval — normally `backfillIntervalSeconds`, stretched when low on
    /// power (#477). Reads the battery snapshot only when the lever is armed (threshold > 0).
    /// #battery: a 5/MG whose history offload is known-empty (`whoop5EmptyOffload.historyEmpty`, crossed
    /// after 2 consecutive empty offloads) is stretched to the low-battery cadence (45 min) regardless of
    /// battery % — history sync is experimental on 5.0 and such a strap banks nothing per pass, so a 15-min
    /// periodic kick just holds the link ~60 s for zero data. The BackfillPolicy empty-backoff also
    /// stretches (after 3 empties, doubling to a 1-hr cap), but this engages one cycle earlier (the
    /// tracker's quietThreshold is 2) and at a fixed 45-min floor that stacks with it. Twin of Android
    /// `nextBackfillDelayMs`. Resets with `whoop5EmptyOffload` on disconnect (a fresh connect re-probes).
    private func nextBackfillInterval() -> Int {
        // #battery: known-empty-history 5/MG → stretch to the 45-min floor before any battery lever.
        if selectedModel.deviceFamily == .whoop5 {
            let stretched = BLEManager.whoop5EmptyHistoryBackfillInterval(
                baseSeconds: BLEManager.backfillIntervalSeconds,
                lowSeconds: BLEManager.lowBatteryBackfillIntervalSeconds,
                historyEmpty: whoop5EmptyOffload.historyEmpty)
            if stretched != BLEManager.backfillIntervalSeconds { return stretched }
        }
        guard lowBatteryOffloadPct > 0 else { return BLEManager.backfillIntervalSeconds }
        let (pct, charging) = batteryPctAndCharging()
        return BLEManager.offloadInterval(
            baseSeconds: BLEManager.backfillIntervalSeconds,
            lowSeconds: BLEManager.lowBatteryBackfillIntervalSeconds,
            batteryPct: pct, charging: charging, thresholdPct: lowBatteryOffloadPct)
    }

    /// #927: the continuous-capture side of the realtime want, window-gated. True while the "Continuous
    /// HRV capture" preference wants the stream held open AND, when "overnight only" is on, the local
    /// wall clock sits inside the nightly window (the reused quiet-hours window, 22:00 → 07:00 by
    /// default). RE-DERIVED at every arm site (reconcile / keep-alive tick / post-bond arm) instead of
    /// precomputed, so a reconnect outside the window can never arm the flood from a stale value.
    /// Mirrors the Android `continuousCaptureWantsNow`.
    private func continuousCaptureWantsNow(now: Date = Date()) -> Bool {
        guard keepRealtimeForData else { return false }
        // #477: while the STRAP's battery is low (≤ threshold, discharging), release the held-open
        // background stream — via the shared lowPowerThrottleActive gate. A Live screen still arms it via
        // screenWantsRealtime (checked separately in reconcileRealtime). The keep-alive re-derives this,
        // so it re-arms automatically once the strap is charged.
        if pauseCaptureBatteryPct > 0 {
            let (pct, charging) = batteryPctAndCharging()
            if BLEManager.lowPowerThrottleActive(batteryPct: pct, charging: charging,
                                                 thresholdPct: pauseCaptureBatteryPct) {
                return false
            }
        }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let d = UserDefaults.standard
        return ContinuousHrvSchedule.streamWanted(
            continuousHrv: true,
            overnightOnly: PuffinExperiment.continuousHrvOvernightOnlyEnabled,
            minuteOfDay: minuteOfDay,
            startMin: d.object(forKey: ContinuousHrvSchedule.quietStartKey) as? Int ?? ContinuousHrvSchedule.defaultStartMinutes,
            endMin: d.object(forKey: ContinuousHrvSchedule.quietEndKey) as? Int ?? ContinuousHrvSchedule.defaultEndMinutes)
    }

    /// Single reconciler for the realtime-HR TOGGLE. The stream should be armed while EITHER a screen
    /// wants it (`screenWantsRealtime`) OR the continuous-capture preference wants it
    /// (`keepRealtimeForData`, window-gated by #927 overnight-only via `continuousCaptureWantsNow()`).
    /// We arm (TOGGLE_REALTIME_HR 1) / disarm (TOGGLE_REALTIME_HR 0) ONLY on the
    /// false↔true edge of that derived want — so a Live screen closing while the preference still wants
    /// it does NOT disarm, and turning the preference off with no screen open DOES disarm. The toggle only
    /// reaches the strap once it's a WHOOP4 (custom channels open immediately) or a bonded 5/MG (puffin
    /// framing); otherwise the want is remembered and the post-bond branch arms it. Mirrors the Android
    /// `reconcileRealtime`.
    private func reconcileRealtime() {
        let want = screenWantsRealtime || continuousCaptureWantsNow()
        wantsRealtime = want   // keep-alive + post-bond arm-on-connect read this derived value
        guard want != realtimeArmed else { return }                      // no edge — nothing to send
        guard selectedModel.deviceFamily == .whoop4 || state.bonded else { return }   // can't reach the strap yet
        realtimeArmed = want
        send(.toggleRealtimeHR, payload: [want ? 0x01 : 0x00])
    }

    /// EXPERIMENTAL R22 telemetry (#174): give the user (and us) live proof of what the strap is doing.
    /// (1) Every `COMMAND_RESPONSE` (type 0x24) to a `SET_CONFIG` (0x78) is the strap ACKing one
    ///     `enable_r22_*` flag — hardware-confirmed in sebastianwoo's capture. 15 ACKs = full acceptance.
    /// (2) A type-0x2F record arriving OUTSIDE our own history offload is NOT a separate live stream.
    ///     #494 showed these are historical-offload data: they appear when a SECOND BLE client pulls
    ///     the strap's history (`SendHistoricalData`) — the burst scales with the disconnect/backlog
    ///     time, not wall-clock — and the SET_CONFIG `enable_r22_*` sequence (accepted 15/15) starts no
    ///     separate stream. type-0x2F is only ever the historical offload (confirmed across #344's v20/v21
    ///     captures too). We still surface these as a diagnostic, but as what they are — another client's
    ///     backlog reaching us over the shared notify channel — not a live R22 "unlock".
    /// Frame layout (5/MG puffin envelope): packet_type @ byte 8, the responded-to cmd @ byte 10.
    ///
    /// #174 cooldown: when our own offload ENDS, the strap can keep flushing a few trailing type-0x2F
    /// records AFTER `backfilling` has already flipped false. So we stamp `lastOffloadFrameAt` on every
    /// offload frame (and at HISTORY_COMPLETE) and skip a non-offload 0x2F within
    /// `deepPacketLiveCooldownSeconds` of it. The flag-ACK counting (1) is unchanged.
    private func noteWhoop5R22Telemetry(_ frame: [UInt8], duringOffload: Bool) {
        // R22 deep-data is a WHOOP 5/MG concept only. On a WHOOP 4 a type-0x2F frame is something else
        // entirely, so counting it as a "deep packet" gave 4.0 owners a bogus deep-data counter (#346).
        guard selectedModel.deviceFamily == .whoop5 else { return }
        guard frame.count > 10 else { return }
        // #174: a SET_CONFIG ack means "one enable_r22_* flag accepted" ONLY when we are enabling. A disable
        // run writes through the same opcode, so without this guard turning R22 OFF would tick the
        // "Strap accepted N/16 R22 flags" counter upwards — the exact opposite of what happened. The
        // disable run scores its own acks (and does not trust them; the 128 read-back is its proof).
        if frame[8] == 0x24, frame[10] == WhoopCommand.setConfig.rawValue, r22DisableRun == nil {
            state.r22FlagsAccepted += 1
            let total = Whoop5Config.enableR22Sequence.count
            if state.r22FlagsAccepted == total {
                log("Deep-data: strap ACCEPTED all \(total)/\(total) R22 flags ✓ — keep it on; watching for deep packets.")
            }
        }
        if frame[8] == 0x2F {
            if duringOffload {
                // Trailing-history reference point: a 0x2F arriving during the offload is banked
                // history (handled by the Backfiller). Remember when it landed so the cooldown below
                // can discount the few that dribble in just after the session ends.
                lastOffloadFrameAt = Date()
                return
            }
            // Cooldown guard: a 0x2F within deepPacketLiveCooldownSeconds of our own last offload
            // frame/HISTORY_COMPLETE is a trailing historical record from that session.
            if let last = lastOffloadFrameAt,
               Date().timeIntervalSince(last) < BLEManager.deepPacketLiveCooldownSeconds {
                return
            }
            // A 0x2F outside our offload is historical-offload data, not a live R22 stream (#494) —
            // typically another BLE client pulling the strap's backlog over the shared notify channel.
            // Surface it as a diagnostic, but don't claim a live-stream "unlock".
            state.deepPacketsThisSession += 1
            if state.deepPacketsThisSession == 1 {
                log("Deep-data: type-0x2F received outside our offload — this is historical-offload data (another BLE client pulling the strap's history, or a trailing flush), not a live R22 stream (#494).")
            } else if state.deepPacketsThisSession.isMultiple(of: 50) {
                log("Deep-data: \(state.deepPacketsThisSession) type-0x2F historical-offload frames seen outside our session.")
            }
        }
    }

    /// EXPERIMENTAL (#174): write the official app's `enable_r22_*` SET_CONFIG sequence to a bonded
    /// WHOOP 5/MG, to switch on the deep biometric (type-0x2F "R22") streams the strap withholds from a
    /// fresh third-party connection. The exact 15-flag sequence + values are documented by judes.club
    /// and Asherlc/dofek and built byte-for-byte by `Whoop5Config` (golden-frame unit-tested).
    ///
    /// Safety: only ever runs when the deep-data experiment is explicitly opted in AND the strap is a
    /// bonded, worn 5/MG. The R22 stream is on-wrist gated, so an off-wrist strap is refused with a hint.
    /// Each flag is one `.setConfig` write WITH RESPONSE, spaced ~80 ms (the official app pauses between
    /// writes). Reversible — it only changes which data the strap emits. After it runs, the user should
    /// wear + sync and share their strap log so we can confirm the deeper records start flowing.
    public func enableWhoop5DeepData() {
        guard selectedModel.deviceFamily == .whoop5 else {
            log("Deep-data: needs a WHOOP 5.0/MG strap selected — ignored."); return
        }
        guard PuffinExperiment.deepDataEnabled else {
            log("Deep-data: the deep-data experiment is off — enable it in Settings → Experimental first."); return
        }
        guard state.connected, state.encryptedBond else {
            // The R22 SET_CONFIG writes go over the encrypted command channel, so the live-HR-only
            // shortcut (`bonded` true, `encryptedBond` false on a 5/MG still owned by the official app,
            // #69/#266) can't carry them. Require the genuine bond, or the writes silently fail (#269).
            log("Deep-data: needs the full encrypted bond, not the live-HR-only link. Close the official WHOOP app, put the strap in pairing mode, and bond it to NOOP first — ignored."); return
        }
        guard state.worn else {
            log("Deep-data: the R22 stream is on-wrist only — put the strap ON, then try again."); return
        }
        state.r22FlagsAccepted = 0   // fresh attempt — count this send's ACKs from zero
        let frames = Whoop5Config.enableR22Sequence
        log("Deep-data: sending the \(frames.count)-flag enable_r22 sequence (experimental, reversible)…")
        for (i, flag) in frames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80 * i)) { [weak self] in
                guard let self else { return }
                self.send(.setConfig,
                          payload: [0x01] + Whoop5Config.payloadBody(name: flag.name, value: flag.value),
                          writeType: .withResponse)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80 * frames.count + 200)) { [weak self] in
            self?.log("Deep-data: sequence sent. Keep the strap on, let it sync, then share your strap log — we're looking for new deep records (type-0x2F) to start arriving. To undo it later, use \"Turn deep data back off\" — disableWhoop5DeepData() writes '0' to the same sixteen keys and reads each one back. (#174)")
        }
    }

    // MARK: - R22 disable (#174)

    /// Per-step reply window for the disable run. Each step is only sent once the previous reply lands (or
    /// times out), so this bounds one round-trip, not the whole run.
    private static let r22DisableStepTimeout: TimeInterval = 8

    /// The in-flight disable run's accumulating report; nil when none is running. Doubles as the send()
    /// allowlist's in-flight gate for the 128 read-back.
    private var r22DisableRun: R22DisableReport?
    /// The step whose reply we are waiting for, nil between steps.
    private var r22DisableAwaiting: R22DisableReport.Step?
    /// Monotonic step counter so a late timeout from an earlier step cannot cancel a live run.
    private var r22DisableStep = 0

    /// EXPERIMENTAL (#174): the undo of `enableWhoop5DeepData()` — write `'0'` to the sixteen `enable_r22_*`
    /// feature flags and report, per key, the value the strap actually stores afterwards.
    ///
    /// **Why this exists.** The Settings copy has promised since #174 that the R22 unlock is "reversible",
    /// and that was true about the hardware and false about the app: NOOP shipped an enable button and no
    /// way back, so the only routes out were the official WHOOP app or a factory reset. This closes that.
    ///
    /// **Why it is staged rather than sixteen writes.** `'0'` is the confirmed off value in the
    /// device-config namespace (#181, hardware-validated on the Broadcast-HR flag) and that namespace shares
    /// this one's entire wire idiom — but no *feature* flag has ever been observed holding `'0'`, and the two
    /// namespaces are proven separate at the verb level. So the run writes ONE flag, reads it back, and only
    /// touches the other fifteen if the strap actually stopped reporting the old value. A firmware that
    /// refuses `'0'` costs the user one round-trip and yields a publishable answer instead of fifteen mystery
    /// writes. See `Whoop5Config.featureFlagOffValue` and `R22DisableReport` for the full reasoning.
    ///
    /// **The ack is never the proof.** Every write's COMMAND_RESPONSE is recorded and not believed —
    /// `SELECT_WRIST` returns SUCCESS for a no-op and FAILURE for a real mutation on this firmware — so only
    /// the value a `GET_FF_VALUE(128)` read returns is reported as state (#907/#891).
    ///
    /// Same guards as the enable: 5/MG family, explicit opt-in, full encrypted bond. `worn` is deliberately
    /// NOT required — the on-wrist gate exists because the R22 STREAM is on-wrist-only, and a user turning
    /// the feature off should not have to put the strap back on to do it. Result goes to
    /// `LiveState.r22DisableReport` and the strap log; no new storage. Twin of Android
    /// `disableWhoop5DeepData()`.
    public func disableWhoop5DeepData() {
        guard selectedModel.deviceFamily == .whoop5 else {
            log("Deep-data disable: needs a WHOOP 5.0/MG strap selected — ignored."); return
        }
        // NOTE there is deliberately NO `PuffinExperiment.deepDataEnabled` guard here. There was one, and it
        // made this entire function unreachable from the control users actually use: the Settings switch is
        // @AppStorage-bound, so flipping it OFF writes the pref false immediately, THEN raises the "Clear the
        // R22 flags on your strap?" dialog. By the time the user taps "Clear flags on strap" the pref is
        // already false, so the guard returned at the top and nothing happened — the same shape of defect
        // this PR exists to fix (UI promising an undo that never runs). The send allowlist now gates the
        // off-value writes on `r22DisableRun != nil` instead, which is the state that is actually about this
        // operation. (#174)
        guard state.connected, state.encryptedBond else {
            log("Deep-data disable: needs the full encrypted bond, not the live-HR-only link. Close the official WHOOP app, put the strap in pairing mode, and bond it to NOOP first — ignored."); return
        }
        guard r22DisableRun == nil else {
            log("Deep-data disable: a disable run is already walking its plan — ignored."); return
        }
        r22DisableRun = R22DisableReport()
        state.r22DisableReport = BLEManager.deviceConfigProbeWaiting
        log("Deep-data disable (#174): clearing the \(Whoop5Config.disableR22Sequence.count)-flag R22 sequence — writing '0' via SET_FF_VALUE(120), each verified with GET_FF_VALUE(128). Probing \(R22DisableReport.probeKey) first; the other flags are only written if that one moves.")
        advanceR22Disable()
    }

    /// Send the next planned step, or finish when the plan is done.
    private func advanceR22Disable() {
        guard let step = r22DisableRun?.nextStep() else {
            finishR22Disable()
            return
        }
        guard let command = WhoopCommand(rawValue: step.opcode) else {
            log("Deep-data disable: refusing to send unknown opcode \(step.opcode)")
            finishR22Disable()
            return
        }
        let payload: [UInt8]
        if step.isWrite {
            payload = [0x01] + Whoop5Config.payloadBody(name: step.key, value: Whoop5Config.featureFlagOffValue)
            // Fail closed: the same predicate the send path consults, asked here too, so a future edit that
            // widened the plan cannot put an unrecognised key or value on the wire. `disableRunInFlight` is
            // true by construction here (this is only called from inside a run) — it is passed rather than
            // hardcoded so this and the send path evaluate the identical predicate.
            guard FeatureFlagWriteGate.admitsDisableWrite(opcode: step.opcode, payload: payload,
                                                          disableRunInFlight: r22DisableRun != nil) else {
                log("Deep-data disable: refusing to write \(step.key) — not admitted by the feature-flag gate")
                finishR22Disable()
                return
            }
        } else {
            guard FeatureFlagWriteGate.isReadBackOpcode(step.opcode) else {
                log("Deep-data disable: refusing to read with opcode \(step.opcode)")
                finishR22Disable()
                return
            }
            payload = DeviceConfigReadProbe.requestBody(key: step.key)
        }
        r22DisableStep &+= 1
        r22DisableAwaiting = step
        let armed = r22DisableStep
        send(command, payload: payload, writeType: .withResponse)
        // BLE callbacks and this timer both run on the main queue, so guard-then-advance is race-free: a
        // reply that already landed advanced `r22DisableStep`, and this stale closure no-ops.
        DispatchQueue.main.asyncAfter(deadline: .now() + BLEManager.r22DisableStepTimeout) { [weak self] in
            guard let self, self.r22DisableRun != nil, self.r22DisableStep == armed,
                  self.r22DisableAwaiting != nil else { return }
            self.r22DisableAwaiting = nil
            self.r22DisableRun?.noteTimeout(for: step, seconds: Int(BLEManager.r22DisableStepTimeout))
            self.advanceR22Disable()
        }
    }

    /// Render + publish + log the report and end the run (which also re-closes the 128 send allowlist).
    private func finishR22Disable() {
        guard let report = r22DisableRun else { return }
        r22DisableRun = nil
        r22DisableAwaiting = nil
        // The "Strap accepted N/16 R22 flags" line reports the last ENABLE send. If this run cleared even one
        // key that claim is stale, so retire it rather than leaving the card asserting the strap is unlocked
        // while the report below says it was just cleared. A run that changed nothing leaves it alone.
        if report.outcomes.values.contains(where: { $0.isSuccess }) {
            state.r22FlagsAccepted = 0
        }
        let text = report.render()
        log("Deep-data disable (#174):\n\(text)")
        state.r22DisableReport = text
    }

    /// Clear the #174 disable result (Settings card dismissed). Twin of Android clearR22DisableReport().
    public func clearR22DisableReport() { state.r22DisableReport = nil }

    /// #174: one COMMAND_RESPONSE belonging to a disable run — either a `SET_FF_VALUE(120)` write ack or a
    /// `GET_FF_VALUE(128)` read-back. Guarded on a run being IN-FLIGHT so a stray byte match can never
    /// surface a result. Parsing — including the CRC gate — lives in the pure `DeviceConfigReadProbe`.
    private func handleR22DisableResponse(_ frame: [UInt8], isWhoop5: Bool) {
        guard r22DisableRun != nil, let step = r22DisableAwaiting else { return }
        r22DisableAwaiting = nil
        if step.isWrite {
            // The ack is recorded for the transcript and decides nothing. `pay[1]` is the 5/MG result code:
            // puffin envelope puts the type @8 and the cmd @10, so the payload starts at 11 and the result
            // byte is at 12.
            let resultCode: Int? = frame.count > 12 ? Int(frame[12]) : nil
            r22DisableRun?.noteWriteAck(resultCode: resultCode, for: step)
        } else {
            switch DeviceConfigReadProbe.parse(frame: frame, family: isWhoop5 ? .whoop5 : .whoop4,
                                               expecting: step.opcode) {
            case .success(let r): r22DisableRun?.noteReadBack(r, for: step)
            case .failure(let f): r22DisableRun?.noteReadFailure(f, for: step)
            }
        }
        advanceR22Disable()
    }

    /// Abandon a disable run the link interrupted, re-closing the 128 send allowlist. Called from the
    /// disconnect path alongside the probe teardowns.
    private func abandonR22DisableRun(_ why: String) {
        guard r22DisableRun != nil else { return }
        r22DisableRun?.noteAbandoned(why)
        finishR22Disable()
    }

    /// EXPERIMENTAL (#181): make a bonded WHOOP 5/MG advertise its heart rate as a standard BLE HR
    /// sensor (0x180D + the live HR in its manufacturer data) by writing the device-config flag
    /// `whoop_live_hr_in_adv_ind_pkt` = "1" (on) / "0" (off) via SET_DEVICE_CONFIG (0x77). With it on, a
    /// Garmin (Edge/watch), Zwift or gym HR client can pair to the WHOOP directly during a workout.
    /// Validated on real hardware (paired on a Garmin Edge 840). Opt-in, reversible; unlike R22 it is NOT
    /// on-wrist gated. Re-applied on each 5/MG connection. iOS/Android only (macOS can't bond a 5/MG).
    public func setBroadcastHr(_ on: Bool) {
        guard selectedModel.deviceFamily == .whoop5 else {
            log("Broadcast HR: needs a WHOOP 5.0/MG strap selected — ignored."); return
        }
        guard state.connected, state.bonded else {
            log("Broadcast HR: connect and bond a 5/MG strap first — ignored."); return
        }
        let value: UInt8 = on ? 0x31 : 0x30   // ASCII '1' / '0'
        send(.setDeviceConfig,
             payload: [0x01] + Whoop5Config.deviceConfigBody(name: "whoop_live_hr_in_adv_ind_pkt", value: value),
             writeType: .withResponse)
        log("Broadcast HR: wrote whoop_live_hr_in_adv_ind_pkt=\(on ? "1" : "0")")
    }

    /// Read the strap's current BLE advertising name (WHOOP 4.0 / Harvard). The reply lands as a
    /// GET_ADVERTISING_NAME COMMAND_RESPONSE and FrameRouter publishes it to `LiveState.advertisingName`.
    /// Also sent automatically in the connect handshake; this is the manual refresh the Settings card
    /// fires after a rename. No-op on a 5/MG (the Harvard name command isn't part of its framing).
    public func requestAdvertisingName() {
        guard selectedModel.deviceFamily == .whoop4 else {
            log("Strap name: WHOOP 4.0 only — ignored on a 5/MG."); return
        }
        guard state.connected else { log("Strap name: not connected — ignored."); return }
        send(.getAdvertisingNameHarvard, payload: [0x00])
    }

    /// Rename the strap's BLE advertising name (WHOOP 4.0 / Harvard) via SET_ADVERTISING_NAME (cmd 77).
    /// Writes `[0x00,0x00] + UTF-8 name + [0x00]` (see `WhoopCommand.advertisingNamePayload`) over the
    /// confirmed command channel; the strap reboots to apply, so the new name appears on the next connect
    /// (the connect handshake re-reads it). The result ack is surfaced via `LiveState.renameStatus`.
    /// WHOOP 4.0 only — a 5/MG uses puffin framing and a different device-config path. Reversible.
    public func renameStrap(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedModel.deviceFamily == .whoop4 else {
            state.renameStatus = "Renaming is WHOOP 4.0 only."
            log("Strap rename: WHOOP 4.0 only — ignored on a 5/MG."); return
        }
        guard state.connected, state.bonded else {
            state.renameStatus = "Connect and pair your strap first."
            log("Strap rename: connect + bond first — ignored."); return
        }
        guard !name.isEmpty else {
            state.renameStatus = "Enter a name first."; return
        }
        state.renameStatus = "Renaming…"
        send(.setAdvertisingNameHarvard,
             payload: WhoopCommand.advertisingNamePayload(name),
             writeType: .withResponse)
        log("Strap rename: wrote advertising name=\(name.debugDescription)")
        // Re-read shortly after so the card reflects the change if the strap applies it without dropping
        // the link; if it reboots instead, the connect handshake re-reads the name on reconnect anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.requestAdvertisingName()
        }
        // Timeout so the card can't hang on "Renaming…" forever. Some WHOOP 4.0 firmware never returns the
        // SET_ADVERTISING_NAME COMMAND_RESPONSE that clears this status (it just reboots, or swallows the
        // command) — the reporter on #428 sat on a permanent "Renaming…". If nothing has updated the status
        // by now, surface an honest fallback instead of an endless spinner. A real ack or the reconnect
        // re-read overwrites this the moment it arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(8)) { [weak self] in
            guard let self, self.state.renameStatus == "Renaming…" else { return }
            self.state.renameStatus = "Rename sent - reconnect your strap to confirm the new name."
            self.log("Strap rename: no ack within 8s — firmware may apply it on reboot/reconnect.")
        }
    }

    // MARK: Reboot (user-initiated, confirmation-gated) — see docs/PROTOCOL.md "Destructive commands"

    /// Monotonic timestamp of the last user-requested reboot, or nil. Set when `rebootStrap()` sends the
    /// command; consumed by `didDisconnectPeripheral` (to log how long the link stayed up = the strap acting
    /// on the reboot) and by the connect handshake (to log the reconnect round-trip). Cleared on reconnect
    /// or by the no-disconnect timeout. The whole point is a self-contained strap-log trail for a reboot,
    /// so a "restart did nothing" report — especially on the unverified 5/MG framing — is triageable.
    private var rebootRequestedAt: DispatchTime?
    private var rebootTimeoutWork: DispatchWorkItem?
    private var rebootSettleWork: DispatchWorkItem?

    /// Clear all reboot-in-flight state: the pending timestamp, both timers, and the `rebootInProgress`
    /// flag that drives the Devices "Reconnecting…" pill. Called from every terminal path (reconnect,
    /// no-disconnect, settle backstop) so the pill can never wedge.
    private func clearRebootState() {
        rebootRequestedAt = nil
        rebootTimeoutWork?.cancel(); rebootTimeoutWork = nil
        rebootSettleWork?.cancel(); rebootSettleWork = nil
        if state.rebootInProgress { state.rebootInProgress = false }
    }

    /// Restart the connected strap (REBOOT_STRAP / opcode 29, empty body). Non-destructive: the strap keeps
    /// its stored data and re-advertises after boot, but the BLE link drops and NOOP auto-reconnects. Gated
    /// to a connected + bonded strap; user-initiated and confirmation-gated at the call site (DevicesView).
    ///
    /// Emits a full debug trail to the strap log so a reboot is diagnosable end to end:
    ///   `reboot: request …`  — family / firmware / link state at send time
    ///   `reboot: sent …`     — opcode, framing (harvard-crc8 vs puffin-crc16), payload, seq
    ///   `reboot: strap acked result=0x…` — the COMMAND_RESPONSE (FrameRouter), the accept/reject signal
    ///                                        that caught 5/MG haptics rejection (result=0x03)
    ///   `reboot: link dropped …` — didDisconnectPeripheral, proves the strap acted
    ///   `reboot: no disconnect within …` — strap ignored it (esp. an unverified 5/MG frame)
    ///   `reboot: reconnected …` — the connect handshake, round-trip complete
    public func rebootStrap() {
        // Production Restart: opcode 29 REBOOT_STRAP, empty body per the official app's builder
        // (rh0.C45476d0). Confirmed on WHOOP 5.0 (#227); ignored on 4.0 (#235 — see rebootProbe).
        sendRebootFrame(command: .rebootStrap, payload: [], probe: nil)
    }

    /// Send one candidate reboot frame from the WHOOP 4.0 reboot probe (Test Centre → Connection).
    /// WHOOP 4.0 only — a 5.0 already reboots on the production frame (#227), so there is nothing to
    /// probe there. Reuses the full reboot watchdog/trail, so the strap log shows whether THIS candidate
    /// dropped the link (`reboot: link dropped …` = it worked) or was ignored (`reboot: no disconnect
    /// within 12s …`). Confirmation-gated at the call site (DevicesView). See `RebootProbeVariant`.
    public func rebootProbe(_ variant: RebootProbeVariant) {
        guard selectedModel.deviceFamily == .whoop4 else {
            log("reboot: probe is WHOOP 4.0 only — ignored (family=\(selectedModel.deviceFamily))")
            return
        }
        sendRebootFrame(command: variant.command, payload: variant.payload, probe: variant)
    }

    /// #592: sentinel value of `LiveState.extendedBatteryProbe` between sending the probe and its reply
    /// landing (or the no-reply timeout). The result dialog shows a "waiting…" line for this value.
    public static let extendedBatteryProbeWaiting = "__waiting__"
    private static let extendedBatteryProbeTimeout: TimeInterval = 8
    private static let extendedBatteryPrevPayloadKey = "noop.592.prevPayload"

    // #690 body-location probe (twins of the #592 constants above).
    public static let bodyLocationProbeWaiting = "__waiting__"
    private static let bodyLocationProbeTimeout: TimeInterval = 8
    private static let bodyLocationPrevPayloadKey = "noop.690.prevPayload"

    /// #592 opcode probe: send the read-only GET_EXTENDED_BATTERY_INFO(98) and surface the strap's reply
    /// (raw hex + payload triage + capture diff) on `LiveState.extendedBatteryProbe` for the Devices dialog.
    /// The number is disputed (an APK decompile reads 87); a battery-shaped payload confirms 98 on this
    /// firmware. Works on both families (the 4.0 is the discriminating device). User-initiated only.
    public func probeExtendedBatteryInfo() {
        guard state.connected else {
            log("Extended-battery probe (#592) ignored — not connected")
            return
        }
        state.extendedBatteryProbe = BLEManager.extendedBatteryProbeWaiting
        log("Extended-battery probe (#592): sending GET_EXTENDED_BATTERY_INFO(98, read-only) on family=\(selectedModel.deviceFamily); the raw COMMAND_RESPONSE is surfaced when it lands")
        send(.getExtendedBatteryInfo)
        // No-reply timeout: if no COMMAND_RESPONSE for 98 arrives, the silence is itself the verdict (98 not
        // served → toward the decompile's 87). BLE callbacks + this timer both run on the main queue, so the
        // guard-then-set is race-free (no CAS needed): a real reply already overwrote the sentinel.
        DispatchQueue.main.asyncAfter(deadline: .now() + BLEManager.extendedBatteryProbeTimeout) { [weak self] in
            guard let self, self.state.extendedBatteryProbe == BLEManager.extendedBatteryProbeWaiting else { return }
            let secs = Int(BLEManager.extendedBatteryProbeTimeout)
            let msg = "Extended-battery probe (#592): no COMMAND_RESPONSE for opcode 98 within \(secs)s — the strap served no reply. That silence is evidence AGAINST 98 on this firmware (toward the decompile's 87); a gated 87 probe is the follow-up. (If a sync/offload was mid-flight the response can be delayed — retry idle.)"
            self.log(msg)
            self.state.extendedBatteryProbe = msg
        }
    }

    /// Clear the #592 probe result (Devices dialog dismissed). Twin of Android clearExtendedBatteryProbe().
    public func clearExtendedBatteryProbe() { state.extendedBatteryProbe = nil }

    /// #592: format a GET_EXTENDED_BATTERY_INFO COMMAND_RESPONSE and publish it, diffing against the
    /// persisted previous payload. Called from the inbound frame handler for both families.
    private func handleExtendedBatteryProbeResponse(_ frame: [UInt8], isWhoop5: Bool) {
        let prev = UserDefaults.standard.string(forKey: BLEManager.extendedBatteryPrevPayloadKey)
        let (text, payHex) = ExtendedBatteryProbe.format(
            frame: frame, cmdOff: isWhoop5 ? 10 : 6, isWhoop5: isWhoop5, prevPayloadHex: prev)
        log("Extended-battery probe (#592):\n\(text)")
        state.extendedBatteryProbe = text
        if let payHex { UserDefaults.standard.set(payHex, forKey: BLEManager.extendedBatteryPrevPayloadKey) }
    }

    /// #690 opcode probe: send the read-only GET_BODY_LOCATION_AND_STATUS(84) and surface the strap's reply
    /// (raw hex + payload triage + capture diff) on `LiveState.bodyLocationProbe` for the Devices dialog.
    /// READ-ONLY: never changes wear detection, sleep gating, or scoring. User-initiated only. Twin of
    /// Android WhoopBleClient.probeBodyLocationAndStatus().
    public func probeBodyLocationAndStatus() {
        guard state.connected else {
            log("Body-location probe (#690) ignored — not connected")
            return
        }
        state.bodyLocationProbe = BLEManager.bodyLocationProbeWaiting
        log("Body-location probe (#690): sending GET_BODY_LOCATION_AND_STATUS(84, read-only) on family=\(selectedModel.deviceFamily); the raw COMMAND_RESPONSE is surfaced when it lands")
        send(.getBodyLocationAndStatus)
        // No-reply timeout: silence is itself the verdict (the strap doesn't serve 0x54 on this firmware).
        // BLE callbacks + this timer both run on the main queue, so the guard-then-set is race-free.
        DispatchQueue.main.asyncAfter(deadline: .now() + BLEManager.bodyLocationProbeTimeout) { [weak self] in
            guard let self, self.state.bodyLocationProbe == BLEManager.bodyLocationProbeWaiting else { return }
            let secs = Int(BLEManager.bodyLocationProbeTimeout)
            let msg = "Body-location probe (#690): no COMMAND_RESPONSE for opcode 84 within \(secs)s — the strap served no reply (it may not implement 0x54 on this firmware). Retry idle if a sync/offload was mid-flight."
            self.log(msg)
            self.state.bodyLocationProbe = msg
        }
    }

    /// Clear the #690 probe result (Devices dialog dismissed). Twin of Android clearBodyLocationProbe().
    public func clearBodyLocationProbe() { state.bodyLocationProbe = nil }

    // MARK: #761 feature-flag enumeration probe (READ-ONLY)

    /// Sentinel while the enumeration is walking, so the dialog shows "waiting…" (twin of the #592/#690
    /// constants above).
    public static let featureFlagProbeWaiting = "__waiting__"
    /// Per-step reply window. Each 118 is only sent after the previous reply lands, so this bounds one
    /// round-trip, not the whole walk.
    private static let featureFlagProbeTimeout: TimeInterval = 8

    /// The in-flight probe's accumulating report; nil when no probe is running. Doubles as the send()
    /// allowlist's in-flight gate — 117/118 cannot leave the app unless this is non-nil.
    private var featureFlagReport: FeatureFlagProbeReport?
    /// Monotonic step counter so a late timeout from an earlier step can't cancel a live walk.
    private var featureFlagStep = 0
    /// The opcode whose reply we are waiting for (117 or 118), nil between steps.
    private var featureFlagAwaiting: UInt8?

    /// #761 read-only probe: ask the strap to ENUMERATE the feature-flag key names its firmware knows —
    /// `START_FF_KEY_EXCHANGE(117)` for the count, then `SEND_NEXT_FF(118)` repeatedly (its body is a
    /// cursor, not an index) until the strap's own end marker. NOTHING is written: no `SET_FF_VALUE(120)`,
    /// no `SET_DEVICE_CONFIG_VALUE(119)`, no value of any kind — this writes command frames purely to read,
    /// exactly like the Oura `spo2_status` / `realsteps_status` probes NOOP already ships
    /// (`Packages/OuraProtocol/…/Commands.swift`). `GET_FF_VALUE(128)` is deliberately NOT sent (its reply's
    /// value field is reported unreliable — see `FeatureFlagProbe`).
    ///
    /// The strap's own key list is the direct evidence #103 lacks: if a 5/MG names no oxygen-related flag,
    /// Blood Oxygen is not client-writable; if it names one, that is the answer outright. Result goes to
    /// `LiveState.featureFlagProbe` (the Devices dialog) and to the strap log — no new storage.
    /// User-initiated only, Test Centre → Connection gated. Twin of Android `probeFeatureFlags()`.
    public func probeFeatureFlags() {
        guard state.connected else {
            log("Feature-flag probe (#761) ignored — not connected")
            return
        }
        // Defence in depth: the menu entry is already Test-Centre gated, but the sender re-checks so no
        // other path can start a probe on a default install.
        //
        // On WHOOP 4.0 this check is the ONLY thing standing between a default install and 117/118 on the
        // wire: the send() allowlist that also gates them lives inside the `deviceFamily == .whoop5`
        // branch, and 4.0 has no allowlist. So this guard is not merely belt-and-braces on every family —
        // for the family most likely to run this first, it is the belt.
        guard TestCentre.active(.connection) else {
            log("Feature-flag probe (#761) ignored — Test Centre → Connection is off")
            return
        }
        guard featureFlagReport == nil else {
            log("Feature-flag probe (#761) ignored — a probe is already walking the list")
            return
        }
        featureFlagReport = FeatureFlagProbeReport(family: selectedModel.deviceFamily)
        state.featureFlagProbe = BLEManager.featureFlagProbeWaiting
        log("Feature-flag probe (#761): sending START_FF_KEY_EXCHANGE(117, read-only) on family=\(selectedModel.deviceFamily); no value is written (SET_FF_VALUE/120 is never sent from this path)")
        sendFeatureFlagStep(.startFeatureFlagKeyExchange)
    }

    /// Send one read-only enumeration command and arm the per-step reply window.
    private func sendFeatureFlagStep(_ command: WhoopCommand) {
        featureFlagStep &+= 1
        featureFlagAwaiting = command.rawValue
        let step = featureFlagStep
        send(command, payload: FeatureFlagProbe.requestBody)
        // BLE callbacks + this timer both run on the main queue, so the guard-then-finish is race-free: a
        // reply that already landed advanced `featureFlagStep`, and this stale closure no-ops.
        DispatchQueue.main.asyncAfter(deadline: .now() + BLEManager.featureFlagProbeTimeout) { [weak self] in
            guard let self, self.featureFlagReport != nil, self.featureFlagStep == step,
                  self.featureFlagAwaiting != nil else { return }
            self.featureFlagReport?.noteTimeout(command: Int(command.rawValue),
                                                seconds: Int(BLEManager.featureFlagProbeTimeout))
            self.finishFeatureFlagProbe()
        }
    }

    /// Render + publish + log the report and end the probe (which also re-closes the send() allowlist).
    private func finishFeatureFlagProbe() {
        guard let report = featureFlagReport else { return }
        featureFlagReport = nil
        featureFlagAwaiting = nil
        let text = report.render()
        log("Feature-flag probe (#761):\n\(text)")
        state.featureFlagProbe = text
    }

    /// Clear the #761 probe result (Devices dialog dismissed). Twin of Android clearFeatureFlagProbe().
    public func clearFeatureFlagProbe() { state.featureFlagProbe = nil }

    // MARK: #103 device-config read probe (READ-ONLY)

    /// Sentinel while the probe is walking its plan, so the dialog shows "waiting…".
    public static let deviceConfigProbeWaiting = "__waiting__"
    /// Per-step reply window. Each read is only sent after the previous reply lands (or times out), so
    /// this bounds one round-trip, not the whole walk.
    private static let deviceConfigProbeTimeout: TimeInterval = 8

    /// The in-flight probe's accumulating report; nil when no probe is running. Doubles as the send()
    /// allowlist's in-flight gate — 121/128 cannot leave the app unless this is non-nil.
    private var deviceConfigReport: DeviceConfigReadProbeReport?
    /// The step whose reply we are waiting for, nil between steps.
    private var deviceConfigAwaiting: DeviceConfigReadProbeReport.Step?
    /// Monotonic step counter so a late timeout from an earlier step can't cancel a live walk.
    private var deviceConfigStep = 0

    /// #103 read-only probe: ask the strap for config VALUES — `GET_DEVICE_CONFIG_VALUE(121)` and
    /// `GET_FF_VALUE(128)`, one key per round-trip. The #761 probe asked the strap for key NAMES in the
    /// feature-flag namespace; this asks for a named key's VALUE, and reaches the DEVICE-CONFIG namespace
    /// (the one `SET_DEVICE_CONFIG_VALUE`/119 writes) that 117/118 never covered.
    ///
    /// NOTHING is written: no `SET_FF_VALUE(120)`, no `SET_DEVICE_CONFIG_VALUE(119)`, no value of any
    /// kind — this writes command frames purely to read, exactly like the Oura `spo2_status` /
    /// `realsteps_status` probes NOOP already ships (`Packages/OuraProtocol/…/Commands.swift`).
    ///
    /// **Both target opcodes may simply be unimplemented.** The probe spends one round-trip per verb
    /// establishing that before it does anything else, and a clean "neither verb is served" is a useful
    /// result. Only a verb that answers goes on to read the sixteen known flag values and the short list
    /// of guessed oxygen key names. Result goes to `LiveState.deviceConfigProbe` (the Devices dialog) and
    /// to the strap log — no new storage. User-initiated only, Test Centre → Connection gated. Twin of
    /// Android `probeDeviceConfigValues()`.
    public func probeDeviceConfigValues() {
        guard state.connected else {
            log("Device-config read probe (#103) ignored — not connected")
            return
        }
        // Defence in depth: the menu entry is already Test-Centre gated, but the sender re-checks so no
        // other path can start a probe on a default install.
        guard TestCentre.active(.connection) else {
            log("Device-config read probe (#103) ignored — Test Centre → Connection is off")
            return
        }
        guard deviceConfigReport == nil else {
            log("Device-config read probe (#103) ignored — a probe is already walking its plan")
            return
        }
        deviceConfigReport = DeviceConfigReadProbeReport(
            family: selectedModel.deviceFamily,
            // The flag names come from NOOP's own R22 sequence — never restated here.
            knownFlagKeys: Whoop5Config.enableR22Sequence.map(\.name),
            candidateKeys: DeviceConfigReadProbe.oxygenCandidateKeys)
        state.deviceConfigProbe = BLEManager.deviceConfigProbeWaiting
        log("Device-config read probe (#103): asking for config VALUES via GET_DEVICE_CONFIG_VALUE(121) + GET_FF_VALUE(128) on family=\(selectedModel.deviceFamily); read-only (SET_FF_VALUE/120 and SET_DEVICE_CONFIG_VALUE/119 are never sent from this path)")
        advanceDeviceConfigProbe()
    }

    /// Send the next planned read, or finish when the plan is done.
    private func advanceDeviceConfigProbe() {
        guard let step = deviceConfigReport?.nextStep() else {
            finishDeviceConfigProbe()
            return
        }
        guard let command = WhoopCommand(rawValue: step.opcode),
              DeviceConfigReadProbe.isReadOnlyOpcode(step.opcode) else {
            // Unreachable with the plan as written; failing closed here means a future edit that widened
            // the plan cannot put a non-read opcode on the wire.
            log("Device-config read probe (#103): refusing to send opcode \(step.opcode) — not a read verb")
            finishDeviceConfigProbe()
            return
        }
        deviceConfigStep &+= 1
        deviceConfigAwaiting = step
        let armed = deviceConfigStep
        send(command, payload: DeviceConfigReadProbe.requestBody(key: step.key))
        // BLE callbacks + this timer both run on the main queue, so the guard-then-advance is race-free:
        // a reply that already landed advanced `deviceConfigStep`, and this stale closure no-ops.
        DispatchQueue.main.asyncAfter(deadline: .now() + BLEManager.deviceConfigProbeTimeout) { [weak self] in
            guard let self, self.deviceConfigReport != nil, self.deviceConfigStep == armed,
                  self.deviceConfigAwaiting != nil else { return }
            self.deviceConfigAwaiting = nil
            self.deviceConfigReport?.noteTimeout(for: step,
                                                 seconds: Int(BLEManager.deviceConfigProbeTimeout))
            // A silent verb is retired by the report, so the plan skips its remaining steps rather than
            // spending another eight seconds on each of them.
            self.advanceDeviceConfigProbe()
        }
    }

    /// Render + publish + log the report and end the probe (which also re-closes the send() allowlist).
    private func finishDeviceConfigProbe() {
        guard let report = deviceConfigReport else { return }
        deviceConfigReport = nil
        deviceConfigAwaiting = nil
        let text = report.render()
        log("Device-config read probe (#103):\n\(text)")
        state.deviceConfigProbe = text
    }

    /// Clear the #103 probe result (Devices dialog dismissed). Twin of Android clearDeviceConfigProbe().
    public func clearDeviceConfigProbe() { state.deviceConfigProbe = nil }

    /// #103: one COMMAND_RESPONSE for 121/128. Guarded on a probe being IN-FLIGHT (like #690/#761) so a
    /// stray byte match can never surface a result. Parsing — including the CRC gate — lives in the pure
    /// `DeviceConfigReadProbe`; a frame that fails any check retires that verb with a named reason
    /// instead of being decoded.
    private func handleDeviceConfigProbeResponse(_ frame: [UInt8], isWhoop5: Bool) {
        guard deviceConfigReport != nil, let step = deviceConfigAwaiting else { return }
        deviceConfigAwaiting = nil
        let family: DeviceFamily = isWhoop5 ? .whoop5 : .whoop4
        switch DeviceConfigReadProbe.parse(frame: frame, family: family, expecting: step.opcode) {
        case .success(let r): deviceConfigReport?.noteReply(r, for: step)
        case .failure(let f): deviceConfigReport?.noteFailure(f, for: step)
        }
        advanceDeviceConfigProbe()
    }

    /// #761: one COMMAND_RESPONSE for 117/118. Guarded on a probe being IN-FLIGHT (like #690) so a stray
    /// byte match can never surface a result. Parsing — including the CRC gate — lives in the pure
    /// `FeatureFlagProbe`; a frame that fails any check ends the walk with a named reason instead of
    /// being decoded.
    private func handleFeatureFlagProbeResponse(_ frame: [UInt8], isWhoop5: Bool) {
        guard featureFlagReport != nil, let awaiting = featureFlagAwaiting else { return }
        let family: DeviceFamily = isWhoop5 ? .whoop5 : .whoop4
        featureFlagAwaiting = nil
        if awaiting == WhoopCommand.startFeatureFlagKeyExchange.rawValue {
            switch FeatureFlagProbe.parseStart(frame: frame, family: family) {
            case .success(let r):
                featureFlagReport?.noteStart(r)
                sendFeatureFlagStep(.sendNextFeatureFlag)
            case .failure(let f):
                featureFlagReport?.noteFailure(f, command: Int(awaiting))
                finishFeatureFlagProbe()
            }
            return
        }
        switch FeatureFlagProbe.parseNext(frame: frame, family: family) {
        case .success(let r):
            if featureFlagReport?.noteNext(r) == true {
                sendFeatureFlagStep(.sendNextFeatureFlag)
            } else {
                finishFeatureFlagProbe()
            }
        case .failure(let f):
            featureFlagReport?.noteFailure(f, command: Int(awaiting))
            finishFeatureFlagProbe()
        }
    }

    /// #690: format a GET_BODY_LOCATION_AND_STATUS COMMAND_RESPONSE and publish it, diffing against the
    /// persisted previous payload. Called from the inbound frame handler for both families. Guarded on a
    /// probe being IN-FLIGHT (parity with Android): 0x54 could coincide with a data frame's cmd-offset byte,
    /// and this is a strictly user-triggered diagnostic, so a stray match must never surface a result.
    private func handleBodyLocationProbeResponse(_ frame: [UInt8], isWhoop5: Bool) {
        guard state.bodyLocationProbe == BLEManager.bodyLocationProbeWaiting else { return }
        let prev = UserDefaults.standard.string(forKey: BLEManager.bodyLocationPrevPayloadKey)
        let (text, payHex) = BodyLocationProbe.format(
            frame: frame, cmdOff: isWhoop5 ? 10 : 6, isWhoop5: isWhoop5, prevPayloadHex: prev)
        log("Body-location probe (#690):\n\(text)")
        state.bodyLocationProbe = text
        if let payHex { UserDefaults.standard.set(payHex, forKey: BLEManager.bodyLocationPrevPayloadKey) }
    }

    // MARK: - WHOOP MG ECG ("Labrador") experimental probe
    //
    // A gated, user-initiated attempt to switch on an MG strap's ECG subsystem, plus the instrumentation
    // that answers the one gating question the client cannot: whether the strap's firmware refuses the
    // feature. NOTHING here runs automatically, and every send passes the double gate in `send()`
    // (Experimental opt-in AND an attested MG). See `Whoop5Ecg` / `Whoop5EcgProbe`.
    //
    // This is NOT a medical feature. The strap's on-board classifier byte is logged RAW (a number, not
    // the token name) precisely so no log line reads like a diagnosis, and the user-facing report says so
    // in words. See DISCLAIMER.md.

    /// Sentinel shown while a probe run is in flight (twin of the #592/#690 constants).
    public static let ecgProbeWaiting = "__waiting__"
    /// How long the probe listens for ECG-shaped packets before rendering its verdict.
    private static let ecgProbeWindow: TimeInterval = 30
    /// Cap on recorded candidate-frame lines, so a chatty stream can't grow the report without bound.
    private static let ecgProbeMaxCandidates = 12
    /// Cap on recorded steps. A run sends at most three, so the headroom is for UNSOLICITED replies —
    /// which are inbound-driven and therefore need the same bound as the candidate list.
    private static let ecgProbeMaxSteps = 12
    /// How many candidate frames get their full raw hex dumped to the strap log (they are large).
    private static let ecgProbeRawDumpLimit = 2

    /// The four ECG opcodes, in ONE place — the allowlist clause and the response matcher must never
    /// disagree about which commands belong to this family.
    func isEcgCommand(_ command: WhoopCommand) -> Bool {
        command == .selectWrist || command == .toggleLabradorDataGeneration
            || command == .toggleLabradorRawSave || command == .toggleLabradorFiltered
    }

    /// True while a probe run is listening. Guards the per-frame triage so it costs nothing otherwise.
    private var ecgProbeArmed: Bool { ecgProbeDeadline != nil }

    /// Set for the duration of `ecgStopCapture()` only, so the OFF path is reachable even after the
    /// Experimental opt-in has been switched back off.
    ///
    /// Turning a feature off must never be gated behind the switch that turned it on: without this, a
    /// user who flipped the toggle off while the strap was streaming would have no way to tell the strap
    /// to stop. The override widens the allowlist for exactly three commands carrying exactly the OFF
    /// values (`stop`/0), for the length of one synchronous call — it can never send an ON value.
    private var ecgStopOverride = false

    /// True when the ECG opcodes are allowed through the 5/MG allowlist right now.
    var ecgCommandsAllowed: Bool { PuffinExperiment.ecgEnabled || ecgStopOverride }

    /// Latched by `ecgStartCapture()`, cleared by a completed `ecgStopCapture()`.
    ///
    /// Keeps the Devices "Stop" control reachable after the Experimental opt-in has been switched off:
    /// without it, turning the toggle off while DISCONNECTED silently no-ops (the stop needs a live MG
    /// link) and then the menu entry vanishes with the opt-in, leaving no route to stop a strap that may
    /// still be streaming. Deliberately NOT persisted — the claim that the strap forgets these toggles
    /// across a disconnect is unverified, so this survives only as long as the process, and the honest
    /// remedy after a relaunch is to re-enable the opt-in and hit Stop.
    private(set) var ecgMayBeRunning = false

    /// The conditions an ECG action needs, checked BEFORE a run is opened so a rejected action leaves no
    /// "waiting…" sheet sitting for the length of the listen window. `send()` re-checks independently —
    /// this is the friendly early-out, not the safety gate.
    ///
    /// `requiresOptIn: false` is the OFF path, which stays available once the toggle is off.
    private func ecgGatesAllow(requiresOptIn: Bool = true) -> Bool {
        guard !requiresOptIn || PuffinExperiment.ecgEnabled else {
            log("ECG probe: ignored — the Experimental ECG opt-in is off")
            return false
        }
        guard isWhoop5MG else {
            log("ECG probe: ignored — strap is not a positively identified WHOOP MG (variant=\(whoop5Variant.label))")
            return false
        }
        guard state.connected else {
            log("ECG probe: ignored — not connected")
            return false
        }
        return true
    }

    /// Send one ECG command and register it as a step whose outcome starts at `.noReply`; a matching
    /// COMMAND_RESPONSE overwrites it.
    private func sendEcgCommand(_ command: WhoopCommand, arg: UInt8) {
        let label = "\(command.label)(\(command.rawValue))"
        // Recorded AT SEND TIME, from the opcode AND the argument: the reply carries neither, so this is
        // the only point where "could this command have produced data" is knowable. Every verdict that
        // reads silence as evidence depends on it.
        let requestsData = Whoop5Ecg.requestsRealtimeData(cmd: command.rawValue, arg: arg)
        ecgProbeSteps.append(Whoop5EcgProbe.Step(label: label,
                                                 outcome: .noReply,
                                                 requestsRealtimeData: requestsData))
        log("ECG probe: → \(label) payload=\(hex(Whoop5Ecg.commandPayload(arg: arg)))")
        send(command, payload: Whoop5Ecg.commandPayload(arg: arg))
    }

    /// Write the PERSISTENT wrist selection. Deliberately its own entry point, never folded into
    /// `ecgStartCapture()`: it is the only command in this family that changes strap state which outlives
    /// the session, so the user chooses the wrist explicitly and confirms it on its own.
    ///
    /// The raw values are inferred from the client enum's ORDER, not attested — the UI says so, and
    /// re-sending with the other wrist is the whole remedy if the inference is backwards.
    public func ecgSelectWrist(_ wrist: Whoop5Ecg.WristSelection) {
        guard ecgGatesAllow() else { return }
        beginEcgProbeRun(clearingSteps: true)
        log("ECG probe: SELECT_WRIST=\(wrist.token) (raw \(wrist.rawValue)) — PERSISTENT strap write; the "
            + "right=0/left=1 mapping is inferred from the client enum order, not confirmed on hardware")
        sendEcgCommand(.selectWrist, arg: wrist.rawValue)
        scheduleEcgProbeVerdict()
    }

    /// The documented turn-on sequence MINUS `selectWrist` (which the user runs separately, above):
    /// toggleRealtimeFilteredECG(on) → toggleSaveRawECG(on) → mainControlECGDataGeneration(start).
    public func ecgStartCapture() {
        guard ecgGatesAllow() else { return }
        ecgMayBeRunning = true      // latched BEFORE the sends, so a mid-sequence drop still leaves Stop offered
        beginEcgProbeRun(clearingSteps: true)
        log("ECG probe: starting the ECG turn-on sequence on an MG (experimental, unvalidated instrumentation)")
        sendEcgCommand(.toggleLabradorFiltered, arg: 1)
        sendEcgCommand(.toggleLabradorRawSave, arg: 1)
        sendEcgCommand(.toggleLabradorDataGeneration, arg: Whoop5Ecg.ControlSignal.start.rawValue)
        scheduleEcgProbeVerdict()
    }

    /// The explicit OFF path: stop generation first, then drop both streams.
    ///
    /// `reportsResult: false` is the Settings-toggle path — it must not pop the Devices result sheet from
    /// a different screen, and it must not queue a verdict 30 s after the user simply switched something
    /// off. The bytes sent are identical either way.
    public func ecgStopCapture(reportsResult: Bool = true) {
        // requiresOptIn: false — see `ecgStopOverride`. The OFF path outlives the opt-in.
        guard ecgGatesAllow(requiresOptIn: false) else {
            // Do NOT clear `ecgMayBeRunning` here: the stop did not reach the strap, so whatever state it
            // is in is unchanged and the Stop control has to stay offered.
            if ecgMayBeRunning {
                log("ECG probe: stop could not be sent (needs a connected MG) — the strap may still be "
                    + "streaming, so Stop stays available on the Devices card")
            }
            return
        }
        ecgStopOverride = true
        defer { ecgStopOverride = false }
        if reportsResult { beginEcgProbeRun(clearingSteps: true) } else { ecgProbeSteps = [] }
        log("ECG probe: stopping ECG data generation and both streams")
        sendEcgCommand(.toggleLabradorDataGeneration, arg: Whoop5Ecg.ControlSignal.stop.rawValue)
        sendEcgCommand(.toggleLabradorRawSave, arg: 0)
        sendEcgCommand(.toggleLabradorFiltered, arg: 0)
        ecgMayBeRunning = false
        if reportsResult { scheduleEcgProbeVerdict() }
    }

    /// Clear the probe result (dialog dismissed).
    public func clearEcgProbe() { state.ecgProbe = nil }

    private func beginEcgProbeRun(clearingSteps: Bool) {
        if clearingSteps {
            ecgProbeSteps = []
            ecgProbeCandidates = []
            ecgProbePacketsSeen = 0
        }
        ecgProbeRunToken &+= 1
        ecgProbeDeadline = Date().addingTimeInterval(BLEManager.ecgProbeWindow)
        state.ecgProbe = BLEManager.ecgProbeWaiting
    }

    /// Render the verdict once the listen window closes. BLE callbacks and this timer both run on the
    /// main queue, so the token check is race-free without a lock.
    private func scheduleEcgProbeVerdict() {
        let token = ecgProbeRunToken
        DispatchQueue.main.asyncAfter(deadline: .now() + BLEManager.ecgProbeWindow) { [weak self] in
            guard let self, self.ecgProbeRunToken == token else { return }
            self.ecgProbeDeadline = nil
            let text = Whoop5EcgProbe.report(steps: self.ecgProbeSteps,
                                             ecgPacketsSeen: self.ecgProbePacketsSeen,
                                             candidateFrames: self.ecgProbeCandidates,
                                             windowSeconds: Int(BLEManager.ecgProbeWindow))
            self.log("ECG probe:\n\(text)")
            self.state.ecgProbe = text
        }
    }

    /// Fold one inbound 5/MG frame into the running probe: either it is a COMMAND_RESPONSE for one of
    /// our four opcodes (which settles that step's outcome), or it is a candidate ECG data packet.
    ///
    /// Called only while a run is armed, and only for non-offload live frames.
    private func noteEcgProbeFrame(_ frame: [UInt8]) {
        // CRC GATE FIRST (safety contract §2: "New inbound paths must do the same"). The verdict this
        // probe produces is its entire output, and a single flipped bit at byte 12 would turn a healthy
        // SUCCESS into "DATA REQUEST REFUSED" — the strongest claim the report can make. So no byte of
        // an unverified frame is read here, on either branch.
        guard verifyFrame(frame, family: .whoop5).ok else { return }
        // Both COMMAND_RESPONSE spellings: 0x24 (36, what the #592/#690 handlers key on) and the puffin
        // alias 38, which `canonicalTypeName` folds onto the same name. Accepting both means a strap that
        // answers on the alias still settles its step instead of being silently triaged as a data packet.
        let isCommandResponse = frame.count > 8
            && (frame[8] == 0x24 || Int(frame[8]) == PuffinPacketType.puffinCommandResponse)
        guard frame.count > 10, isCommandResponse else {
            noteEcgProbeCandidate(frame)
            return
        }
        let respCmd = frame[10]
        guard let command = WhoopCommand(rawValue: respCmd), isEcgCommand(command) else {
            noteEcgProbeCandidate(frame)
            return
        }
        let label = "\(command.label)(\(respCmd))"
        let outcome = Whoop5EcgProbe.outcome(frame: frame) ?? .noReply
        let replyHex = frame.map { String(format: "%02x", $0) }.joined()
        // Settle the FIRST step still awaiting a reply for this command, so a start-then-stop pair keeps
        // its two outcomes distinct instead of both collapsing onto the last one.
        if let idx = ecgProbeSteps.firstIndex(where: { $0.label == label && $0.outcome == .noReply }) {
            // Carry the send-time flag across: the reply does not echo the argument, so re-deriving it
            // here is impossible and dropping it would silently weaken (or, worse, strengthen) the verdict.
            ecgProbeSteps[idx] = Whoop5EcgProbe.Step(
                label: label,
                outcome: outcome,
                requestsRealtimeData: ecgProbeSteps[idx].requestsRealtimeData,
                replyHex: replyHex)
            log("ECG probe: ← \(label) \(outcome.token)")
        } else if ecgProbeSteps.count < BLEManager.ecgProbeMaxSteps {
            // An UNSOLICITED reply for one of our opcodes. Recorded, but capped for the same reason the
            // candidate list is: each Step carries a full-frame hex string that is rendered into both the
            // report and the strap log, and a chatty stream must not be able to grow either without bound.
            //
            // `requestsRealtimeData: false` — nothing here sent it, so the argument behind it is unknown,
            // and an unknown must never be able to unlock a verdict that claims the feature is blocked.
            ecgProbeSteps.append(Whoop5EcgProbe.Step(label: label,
                                                     outcome: outcome,
                                                     requestsRealtimeData: false,
                                                     replyHex: replyHex))
            log("ECG probe: ← \(label) \(outcome.token) (unsolicited)")
        }
    }

    /// Structural triage for the packet TYPE the ECG records arrive under, which no table in this repo
    /// holds. A hit is a CANDIDATE, never a confirmed mapping.
    private func noteEcgProbeCandidate(_ frame: [UInt8]) {
        guard frame.count >= 12, Whoop5Ecg.plausibleFilteredFrame(frame) else { return }
        ecgProbePacketsSeen += 1
        guard ecgProbeCandidates.count < BLEManager.ecgProbeMaxCandidates,
              let packet = Whoop5Ecg.decodeFilteredFrame(frame) else { return }
        let header = packet.header
        // The classifier byte is logged as a NUMBER, never as its token name: a strap log is a shareable
        // artefact, and no line in it should read like a clinical finding. The decoder maps the value
        // offline; the raw byte is lossless.
        let line = String(format: "type=0x%02x len=%d samples=%d quality=%d leadsOn=%d hr=%d hrv=%d "
                          + "classifierRaw=%d statusRaw=%d (unvalidated instrumentation, not a diagnosis)",
                          Int(frame[8]), frame.count, Int(header.numberOfECGSamples),
                          Int(header.signalQualityRaw), header.heartKeyLeadsAreOn ? 1 : 0,
                          Int(header.heartKeyHR), Int(header.heartKeyHRV),
                          Int(header.heartKeyArrhythmiaCheckResultRaw),
                          Int(header.heartKeyArrhythmiaCheckStatusRaw))
        ecgProbeCandidates.append(line)
        log("ECG probe: candidate packet \(line)")
        // Dump the raw bytes of the FIRST few candidates so a plain strap-log export is enough to redo
        // the decode offline — the durable frame recorder is a separate opt-in the user may not have on.
        // Capped hard: these frames are hundreds of bytes and the log is a scrolling UI list.
        if ecgProbeCandidates.count <= BLEManager.ecgProbeRawDumpLimit {
            log("ECG probe: candidate raw (\(frame.count) B): \(hex(frame))")
        }
    }

    /// Shared reboot send + debug trail + watchdog, used by both the production `rebootStrap()` and the
    /// 4.0 `rebootProbe(_:)`. `probe == nil` is the normal restart; a non-nil variant is a probe attempt
    /// (its `logTag` is stamped first so the strap log correlates the attempt with what the strap did).
    private func sendRebootFrame(command: WhoopCommand, payload: [UInt8], probe: RebootProbeVariant?) {
        let family = selectedModel.deviceFamily
        guard state.connected, state.bonded, let p = peripheral, p.state == .connected else {
            log("reboot: connect + bond first — ignored (connected=\(state.connected) bonded=\(state.bonded))")
            return
        }
        // Supersede any still-pending reboot (cancels its timers + resets the flag) so a repeat tap can't
        // leave a stale watchdog/settle timer that fires during this new reboot's window.
        clearRebootState()
        // The logged opcode is always the command's on-wire value — never a separate field that could
        // disagree with the bytes actually sent.
        let opcode = Int(command.rawValue)
        let framing = family == .whoop5 ? "puffin-crc16 (verified on 5.0 fw 50.40.1.0)" : "harvard-crc8 (UNVERIFIED on 4.0)"
        let fw = state.strapFirmware ?? "unknown"
        let payloadDesc = payload.isEmpty ? "empty" : payload.map { String(format: "%02x", $0) }.joined()
        if let probe { log("reboot: PROBE \(probe.logTag) — trying an unconfirmed WHOOP 4.0 reboot frame (#235)") }
        log("reboot: request family=\(family) fw=\(fw) connected=true bonded=true")
        log("reboot: sent opcode=\(opcode) framing=\(framing) payload=\(payloadDesc) writeType=withResponse")
        // .withResponse so the write itself is acknowledged at the ATT layer before the strap drops the link.
        send(command, payload: payload, writeType: .withResponse)
        rebootRequestedAt = .now()
        // Drive the Devices "Reconnecting…" pill: true from here until the strap reconnects (or a terminal
        // path clears it). The pill only shows it once the link actually drops (it gates on !connected).
        state.rebootInProgress = true
        // No-disconnect watchdog: if the link is still up after 12 s the strap didn't act on the command —
        // the key signal that a 5/MG puffin reboot frame was silently rejected. A real reboot drops within
        // ~1-2 s when idle; a strap mid-offload finishes the transfer first (observed ~9 s on 5.0
        // fw 50.40.1.0), so 12 s is the cutoff, not the expected latency. Cancelled by
        // didDisconnectPeripheral when the reboot takes.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.rebootRequestedAt != nil, self.state.connected else { return }
            self.log("reboot: no disconnect within 12s — strap may have ignored the command"
                     + (self.selectedModel.deviceFamily == .whoop5 ? " (5/MG reboot is verified on 5.0 fw 50.40.1.0; if your firmware differs, please share this log on #166)" : " (the WHOOP 4.0 reboot frame is NOT confirmed yet — please share this log on #235)"))
            self.clearRebootState()
        }
        rebootTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(12), execute: work)
        // Absolute settle backstop: if the reboot never resolves (link dropped but the strap never comes
        // back), clear the pill after 60 s so it can't wedge on "Reconnecting…". A normal reboot+reconnect
        // completes well inside this and clears it earlier via noteRebootReconnectIfNeeded.
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.state.rebootInProgress else { return }
            self.log("reboot: not settled within 60s — clearing the reconnecting state")
            self.clearRebootState()
        }
        rebootSettleWork = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(60), execute: settle)
    }

    /// Closes the reboot trail: when the connect handshake completes and a reboot was in flight, log the
    /// full round-trip (send → reboot → reconnect) and clear the pending state. No-op otherwise.
    private func noteRebootReconnectIfNeeded() {
        guard let t = rebootRequestedAt else { return }
        let s = Double(DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds) / 1_000_000_000
        log(String(format: "reboot: reconnected %.1fs after send — round trip complete", s))
        clearRebootState()   // clears the "Reconnecting…" pill → back to "Active · Live"
    }

    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let s = BLEManager.keepAliveIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        // Kept EXACT (no leeway): this tick isn't just a liveness check — `keepAliveFire` re-arms the
        // WHOOP 4 realtime burst (R10/R11) and re-subscribes notifications every cycle so streaming can't
        // lapse. Coalescing it up to a few seconds late risks a brief realtime-stream gap, for a battery
        // gain that rounds to nothing on a 30 s timer. The real coalescing win is the offload timer's 60 s
        // leeway (#1052), which is genuinely loose because the strap banks to flash between syncs.
        t.schedule(deadline: .now() + .seconds(s), repeating: .seconds(s))
        t.setEventHandler { [weak self] in self?.keepAliveFire() }
        t.resume()
        keepAliveTimer = t
    }

    private func keepAliveFire() {
        guard state.connected, didBond else { return }
        enableLiveNotifications(reason: "keepalive")
        // Liveness watchdog: if NOTHING has arrived for a while, the stream/link stalled.
        // Bounce the connection — the auto-rescan on disconnect re-bonds and resumes streaming.
        // #580: a known history-empty 5/MG (firmware serves no offload) gets a far longer fuse. The
        // standard 0x2A37 HR profile keeps the link genuinely alive, but its packets can lull for >120s
        // when the strap is off-wrist / resting, and an empty offload leaves the data channel quiet — so
        // the old 120s rule disconnected/rescanned a perfectly healthy link every ~2 min (the thrash this
        // fixes). A WHOOP 4 (real "not recording" path) keeps the tight 120s fuse unchanged.
        let bounceFuse: TimeInterval =
            (selectedModel.deviceFamily == .whoop5 && whoop5EmptyOffload.historyEmpty) ? 600 : 120
        if Date().timeIntervalSince(lastDataAt) > bounceFuse {
            log("No data for >\(Int(bounceFuse))s — bouncing link to resume streaming")
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        guard !backfilling else { return }            // never poke the strap mid-offload
        // #927: continuous capture can be overnight-only, which makes the want TIME-dependent; nothing
        // else re-evaluates it while the app just sits connected, so the keep-alive tick re-derives it.
        // A window-close tick DISARMS (stop the heavy R10/R11 burst, then the reconciler sends TOGGLE 0
        // on the true→false edge; the same stop shape as stopRealtime). A window-open tick re-arms on
        // the false→true edge. Ticks with no transition cost one predicate evaluation. This runs BEFORE
        // the WHOOP4-only guard below so a 5/MG stream also disarms/re-arms on the window edges (send()
        // routes the 5/MG toggle and drops the WHOOP4-framed R10/R11 stop for it).
        let captureWantNow = screenWantsRealtime || continuousCaptureWantsNow()
        if wantsRealtime != captureWantNow, keepRealtimeForData, !screenWantsRealtime {
            if captureWantNow {
                log("Continuous HRV: overnight window opened; arming the realtime stream (#927)")
            } else {
                send(.sendR10R11Realtime, payload: [0x00])   // stop the heavy burst, like stopRealtime
                log("Continuous HRV: overnight window closed; realtime stream disarmed until tonight (#927)")
            }
        }
        reconcileRealtime()   // recomputes wantsRealtime from the fresh predicate; toggles only on an edge
        // The command pings below are WHOOP4-framed; a 5/MG link drops them at the send() guard, so
        // skip them for 5/MG (it keeps the experimental strap log clean — re-subscribe + the 120s
        // bounce above are what keep a 5/MG link healthy).
        guard selectedModel.deviceFamily == .whoop4 else { return }
        // Never re-arm the heavy R10/R11 burst once the marginal-radio fallback has tripped (#80) — that
        // would just re-trigger the drop the keep-alive is meant to prevent. 0x2A37 keeps the HR flowing.
        if wantsRealtime && !standardHRFallback {
            realtimeArmed = true   // keep reconcileRealtime()'s edge tracking in sync with the re-arm
            send(.sendR10R11Realtime, payload: [0x01])
            send(.toggleRealtimeHR, payload: [0x01])
        }   // re-arm so it can't lapse
        keepAliveTick += 1
        if keepAliveTick % 2 == 0 { send(.getBatteryLevel, payload: []) }  // ~every 60s
    }

    private func startBackfillTimer() {
        backfillTimer?.cancel()
        // #477: one-shot, re-armed by triggerPeriodicBackfill() with a fresh (battery-adaptive) interval
        // each tick — so the cadence can stretch/relax as power state changes (was a fixed repeating timer).
        let interval = nextBackfillInterval()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(interval),
                   leeway: .seconds(BLEManager.backfillTimerLeewaySeconds))
        t.setEventHandler { [weak self] in self?.triggerPeriodicBackfill() }
        t.resume()
        backfillTimer = t
    }

    /// The single gated entry point for every historical-offload kick. Applies the connection/state
    /// gate AND the BackfillPolicy rate-limiter for the trigger. On a go: records the attempt time
    /// (persisted) and starts the offload.
    func requestSync(_ trigger: BackfillTrigger) {
        guard BLEManager.shouldRunPeriodicBackfill(
            connected: state.connected, bonded: state.bonded, backfilling: backfilling) else { return }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
        // #160: a future-dated-clock strap's recurring automatic offloads (#928/#1012) are near-useless
        // AND each ~60s session blocks the WHOOP4 realtime-HR keep-alive re-arm (guard !backfilling), so
        // live HR lapses. Feed the already-tracked future-dated signal into BackfillPolicy, which SKIPS
        // the .strap/.periodic triggers entirely for such a strap (the .connect pass still re-checks it).
        let clockUntrusted = BackfillContinuation.isFutureDatedNewest(strapNewestTs, wallNowUnix: Int(now))
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last,
                                       // #battery: back off on EITHER a console-only streak (clock-lost) OR a
                                       // plain empty-offload streak incl. idle-timeout stalls — the latter is
                                       // what stops the 15-min poll spinning on a caught-up strap.
                                       emptyStreak: max(emptySyncTracker.consecutiveEmptySyncs, consecutiveEmptyOffloads),
                                       clockUntrusted: clockUntrusted) else {
            log("Backfill: \(trigger) skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
            return
        }
        if beginBackfill() {
            UserDefaults.standard.set(now, forKey: BLEManager.backfillLastAtKey)
        }
    }

    /// Periodic-timer callback: routes through the rate-limited requestSync entry point.
    private func triggerPeriodicBackfill() {
        requestSync(.periodic)
        startBackfillTimer()   // #477: re-arm with a fresh battery-adaptive interval (one-shot timer)
    }

    /// User-tappable "Sync now" (#364): kick a historical offload IMMEDIATELY, bypassing the 15-min
    /// periodic floor. Routes through the SAME gated `requestSync` as every other trigger with the
    /// `.manual` tier — so it always passes the BackfillPolicy floor but still honours the
    /// connected+bonded+not-already-backfilling gate (a no-op, honestly, when there's no strap or a
    /// sync is already running). The caller (Health screen) only enables the control while connected, so
    /// a tap is meaningful; this guard is the belt-and-braces. Mirrors the Android `WhoopBleClient.syncNow`.
    public func syncNow() {
        guard state.connected, state.bonded else {
            log("Sync now: no strap connected — ignored.")
            return
        }
        if backfilling {
            log("Sync now: a sync is already in progress.")
            return
        }
        log("Sync now: manual sync requested by user.")
        requestSync(.manual)
    }

    // MARK: Helpers
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func log(_ s: String) {
        state.append(log: "[\(timestamp())] \(s)")
    }
    private func timestamp() -> String {
        BLEManager.logTimeFormatter.string(from: Date())
    }

    /// Emit one Connection & Sync test-mode bond-state line, gated zero-cost behind TestCentre.active(.connection).
    /// The gate (one UserDefaults bool) is read BEFORE the tagged string is appended, so this is a no-op when
    /// the mode is off. Diagnostic only - it never changes the bond path; it just records the transition.
    private func emitConnectionBondState(_ detail: String) {
        guard TestCentre.active(.connection) else { return }
        state.append(log: "bondState \(detail)", domain: .connection)
    }
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func preparePeripheral(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        resetCharacteristics()
    }

    private func discoverPrimaryServices(on p: CBPeripheral) {
        p.discoverServices([
            selectedModel.scanService, BLEManager.heartRateService, BLEManager.batteryService,
            BLEManager.disService,
        ])
    }

    private func resetCharacteristics() {
        cmdCharacteristic = nil
        cmdNotifyCharacteristic = nil
        eventNotifyCharacteristic = nil
        dataNotifyCharacteristic = nil
        heartRateCharacteristic = nil
        batteryCharacteristic = nil
        disSerialCharacteristic = nil
        disHwRevCharacteristic = nil
        disRead = false
        disSerial = nil
        disHwRev = nil
        whoop5NotifyCharacteristics.removeAll()
    }

    /// Start a service-filtered scan for `model`, re-framing the inbound stream for its family (so a
    /// fallback rotation decodes the strap it actually finds, not the family we started from). When
    /// `allowFallback` is true, schedule a one-shot rotation to the other WHOOP family after
    /// `scanFallbackDelaySeconds` of no discovery — recovers reconnect when the persisted preference is
    /// stale after an update/restore. Discovery/connect cancels the pending rotation. (PR#195)
    private func startScan(for model: WhoopModel, allowFallback: Bool) {
        cancelScanFallback()
        selectedModel = model
        reassembler = Reassembler(family: model.deviceFamily)
        router.family = model.deviceFamily
        configureCollectorFamily()
        central.stopScan()
        log("Scanning for \(model.displayName)…")
        let diagnosticServices = [model.scanService] + WhoopGattServiceFamily.unsupportedServiceUUIDStrings
            .map { CBUUID(string: $0) }
        central.scanForPeripherals(
            withServices: diagnosticServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        guard allowFallback else { return }
        let fallback = model.fallbackScanModel
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.central.isScanning, !self.state.connected else { return }
            self.log("No \(model.displayName) found yet — trying \(fallback.displayName)")
            self.startScan(for: fallback, allowFallback: true)
        }
        scanFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BLEManager.scanFallbackDelaySeconds,
            execute: work
        )
    }

    /// Human-readable `CBPeripheralState`, so a strap log says what the peripheral actually was at
    /// connect time rather than a bare enum ordinal (#730).
    private func peripheralStateName(_ s: CBPeripheralState) -> String {
        switch s {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    /// Issue a direct connect to a restored peripheral, logging that it actually happened and arming the
    /// #730 pending-connect probe. Both restore entry points funnel through here so the two paths can be
    /// told apart in a strap log.
    private func connectRestored(_ p: CBPeripheral, reason: String) {
        log("Connecting to restored peripheral (\(reason)) — peripheral state=\(peripheralStateName(p.state))")
        central.connect(p, options: nil)
        pendingConnectProbe?.cancel()
        let probe = DispatchWorkItem { [weak self] in
            guard let self, !self.state.connected, self.peripheral?.state != .connected else { return }
            self.log("Still not connected \(Int(BLEManager.pendingConnectProbeSeconds))s after the restored "
                     + "connect (\(reason)) — CoreBluetooth connect has no timeout, so it is still PENDING "
                     + "(no didFailToConnect). The strap is likely out of range, asleep, or bonded elsewhere.")
        }
        pendingConnectProbe = probe
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BLEManager.pendingConnectProbeSeconds, execute: probe)
    }

    private func cancelPendingConnectProbe() {
        pendingConnectProbe?.cancel()
        pendingConnectProbe = nil
    }

    private func cancelScanFallback() {
        scanFallbackWorkItem?.cancel()
        scanFallbackWorkItem = nil
    }

    private func enableLiveNotifications(reason: String) {
        guard let p = peripheral, p.state == .connected else { return }
        let chars = [
            cmdNotifyCharacteristic,
            eventNotifyCharacteristic,
            dataNotifyCharacteristic,
            heartRateCharacteristic,
            batteryCharacteristic,
        ].compactMap { $0 }
        // #613: normally skip already-notifying chars (requestNotify would just log "already active" on
        // every keep-alive tick). On a restored session also pass them through so requestNotify can force a
        // real re-subscribe on the inherited-but-dead subscriptions.
        for c in chars where !c.isNotifying || restoreNeedsResubscribe {
            requestNotify(c, on: p, reason: reason)
        }
        // #490: a 5/MG's 0x2A19 battery READ is refused pre-bond (it fires in didDiscoverCharacteristicsFor,
        // before the link is encrypted) and is never retried, so `batteryPct` stays nil from connect — and
        // the 5/MG sends NO unsolicited battery notification (so the notify subscription above never fills
        // it on its own). Re-issue the read here: every caller is post-bond (CLIENT_HELLO-ack, post-bond,
        // keep-alive), so the link is encrypted and the read succeeds. #battery: THROTTLED to
        // `whoop5BatteryReadMinIntervalSeconds` (~60 s) so the 30 s keep-alive tick no longer re-reads it
        // every cycle — matching the Android twin's `keepAliveTick % 2 == 0` ~60 s cadence and the
        // BatteryEstimator's 600 s same-% throttle (a 30 s poll was 20× finer than the estimator uses).
        // The first read of a connection (`lastBatteryReadAt == nil`, reset on disconnect) always fires,
        // so the post-bond / CLIENT_HELLO-ack callers still seed the reading promptly. 4.0 is EXCLUDED —
        // its 0x2A19 is a stub constant 100 (real value = GET_BATTERY_LEVEL; re-reading the stub would
        // revert the true reading, #77). The 600 s same-% throttle in LiveState guards the estimator.
        if let b = batteryCharacteristic, b.properties.contains(.read),
           selectedModel.deviceFamily != .whoop4,
           BLEManager.shouldPollWhoop5Battery(lastReadAt: lastBatteryReadAt) {
            p.readValue(for: b)
            lastBatteryReadAt = Date()
        }
        // #520 DIS identity read — same post-bond reasoning as the #490 battery read above: on a 5/MG the
        // link must be encrypted first. Gated to 5/MG (a 4.0 issues NO new reads, exactly like the battery
        // re-read excludes it) and fired ONCE per connection: serial + hardware revision are immutable, so
        // unlike the battery they are never re-polled on the keep-alive tick.
        // NOTE: `disRead` is set only once a read is actually ISSUED — never merely because this ran.
        // `enableLiveNotifications` fires from several callers (CLIENT_HELLO-ack, post-bond, keep-alive),
        // and the earliest can land before DIS discovery has completed. Setting the flag unconditionally
        // would burn the one-shot on a call where the characteristics were still nil, and the variant
        // would never resolve. Leaving it unset lets a later caller (the keep-alive tick) pick it up.
        if !disRead, selectedModel.deviceFamily != .whoop4,
           let serialChar = disSerialCharacteristic, serialChar.properties.contains(.read) {
            disRead = true
            p.readValue(for: serialChar)
            if let c = disHwRevCharacteristic, c.properties.contains(.read) { p.readValue(for: c) }
        }
    }

    /// Resolve + log the 5/MG hardware variant once a DIS string lands (#520). Both characteristics
    /// arrive as SEPARATE async callbacks, so this runs on each and re-resolves — the contradiction rule
    /// in `Whoop5Variant` needs both before it can disagree. Diagnostic only: nothing gates on it yet.
    ///
    /// The serial is a device identifier, so ONLY its 3-character prefix is logged (that is the entire
    /// information content here) — never the full string, which would land in a shareable strap log.
    private func noteWhoop5VariantFromDIS() {
        let variant = Whoop5Variant.from(serial: disSerial, hardwareRevision: disHwRev)
        let prefix = (disSerial?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
            .map { String($0.prefix(3)) } ?? "?"
        log("DIS: serialPrefix=\(prefix) hwRev=\(disHwRev ?? "?") -> variant=\(variant.label)")
        // Publish it so an MG-only capability can gate on attested hardware. Still diagnostic for every
        // existing consumer — nothing about framing or decode reads this.
        state.whoop5Variant = variant.label
    }

    private func requestNotify(_ c: CBCharacteristic, on p: CBPeripheral, reason: String) {
        guard c.properties.contains(.notify) || c.properties.contains(.indicate) else {
            log("Notify unavailable \(c.uuid) (\(reason))")
            return
        }
        if c.isNotifying {
            // #613: after CoreBluetooth state restoration the inherited subscription is reported active but
            // no longer delivers, and `setNotifyValue(true)` on an already-notifying char yields NO callback
            // (no state change). Force one real off→on cycle so delivery is re-established AND
            // `didUpdateNotificationStateFor` fires — the only path that latches `cmdNotifyConfirmedActive`
            // → `connectSettled` → the alarm re-arm. One-shot: `restoreNeedsResubscribe` clears at settle.
            if restoreNeedsResubscribe {
                log("Notify re-arming after restore \(c.uuid) (\(reason))")
                p.setNotifyValue(false, for: c)
                p.setNotifyValue(true, for: c)
                return
            }
            log("Notify already active \(c.uuid) (\(reason))")
            return
        }
        p.setNotifyValue(true, for: c)
        log("Notify requested \(c.uuid) (\(reason))")
    }

    // MARK: Alarm API (M6 — additive; does NOT touch connect/offload/sync flows)

    /// Arm the strap's firmware alarm for `date` (UTC).
    ///
    /// WHOOP 4.0 sequence: SET_CLOCK first to ensure the strap RTC is UTC-correct, then the
    /// rev-1 SET_ALARM_TIME. WHOOP 5/MG sends the REVISION_4 body alone — the strap maintains
    /// its RTC (set during the connect handshake / history sync) and the official app's alarm
    /// path doesn't re-set it (wire observation; mirrors Android WhoopBleClient.armStrapAlarm).
    /// Either way the strap will buzz at `date` even if the app is backgrounded or force-quit
    /// (event STRAP_DRIVEN_ALARM_EXECUTED=57). This is the only alarm path: the strap fires at
    /// the fixed time — NOOP has no light-sleep early-wake layer.
    ///
    /// EXPERIMENTAL / UNCONFIRMED on 5/MG (same posture as the Android client): the byte-identical
    /// Android rev-4 frame has been ACKed by a real 5/MG when arming, but a strap-driven wake fire
    /// has NOT been captured on our side (no STRAP_DRIVEN_ALARM_EXECUTED event observed yet) — do
    /// not present the 5/MG alarm as guaranteed until one is.
    func armStrapAlarm(at date: Date) {
        // Log the wake time in the user's LOCAL zone. `Date` prints in UTC by default, so an alarm
        // for (say) 07:00 in New York logged as "11:00:00 +0000" reads like a timezone bug — but it
        // isn't: SET_ALARM_TIME carries the absolute instant of the chosen local time, and the strap
        // fires at that instant regardless of how its UTC RTC is labelled.
        let localFmt = DateFormatter()
        localFmt.dateFormat = "EEE HH:mm zzz"
        if selectedModel.deviceFamily == .whoop5 {
            // The 5/MG firmware alarm is unconfirmed (arming ACKs, but the wake actually FIRING is not
            // verified), so only arm it when the user has opted into Experimental — matching the Android
            // client, which refuses to arm it otherwise. Without this a normal 5/MG user is silently
            // armed onto an alarm that may never fire.
            guard PuffinExperiment.isEnabled else {
                log("Alarm: 5/MG firmware alarm needs the Experimental toggle (unconfirmed) — not armed")
                return
            }
            // 5/MG SET_ALARM_TIME is REVISION_4: [04][id][u32 sec][u16 subsec][12-byte 47/152
            // pattern, overallLoop 7, 30 s]. No SET_CLOCK preamble (see doc comment above).
            let wakeMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
            send(.setAlarmTime, payload: AlarmPayload.setAlarmRev4(wakeEpochMs: wakeMs))
            recordAlarmArm(sentEpoch: Int(wakeMs / 1000))
            // #34: don't claim "armed" when the strap isn't connected (the send was dropped) — the arm
            // re-fires on the next connect.
            log(commandChannelReady   // #613: reflect whether send() actually reached the strap, not just a non-nil uuid
                ? "Alarm: armed 5/MG rev4 for \(localFmt.string(from: date)) — your local wake time"
                : "Alarm: queued 5/MG rev4 for \(localFmt.string(from: date)) — strap not connected; will send on next connect")
            return
        }
        // Clamp rather than trap: an out-of-range alarm date (pre-1970 / post-2106) must not crash.
        let epochSec = UInt32(clamping: Int64(date.timeIntervalSince1970))
        sendSetClockBothForms()
        send(.setAlarmTime, payload: WhoopCommand.setAlarmPayload(epochSec: epochSec))
        recordAlarmArm(sentEpoch: Int(epochSec))
        // #34: only claim "armed" when the strap is connected (the send actually went out); otherwise it's
        // queued and re-sent on the next connect.
        if commandChannelReady {   // #613: reflect whether send() actually reached the strap, not just a non-nil uuid
            log("Alarm: armed for \(localFmt.string(from: date)) — your local wake time (sent as UTC epoch \(epochSec))")
        } else {
            log("Alarm: queued for \(localFmt.string(from: date)) — strap not connected; will send on next connect")
        }
        // Arm READBACK (#401 close-out): ask the strap what it now has armed (GET_ALARM_TIME, cmd 67) so
        // the strap log carries armed + strap-reports + fired as one decidable sequence in any future
        // "didn't buzz" report. WHOOP 4.0 ONLY: cmd 67 is allowlisted for 5/MG but its puffin readback
        // semantics are unverified, and this lands unacknowledged in the arm burst (trivial airtime).
        // Log-only: FrameRouter parses the cmd-67 COMMAND_RESPONSE defensively and NEVER gates behaviour
        // on it (the 4.0 response layout is undocumented; unparseable replies log raw hex).
        send(.getAlarmTime, payload: [0x01])
    }

    /// #34: persist the last alarm arm for the debug export's Alarm block (sent epoch + when + whether the
    /// strap was connected when we sent it), so a "didn't buzz" report shows sent-vs-strap-reports at a glance.
    private func recordAlarmArm(sentEpoch: Int) {
        let d = UserDefaults.standard
        d.set(sentEpoch, forKey: "alarm.lastArmSentEpoch")
        d.set(Date().timeIntervalSince1970, forKey: "alarm.lastArmAt")
        d.set(commandChannelReady, forKey: "alarm.lastArmConnected")   // #613: true only if the arm actually went out
        // #34: the strap-clock skew (its own RTC minus wall, seconds) AT THE MOMENT we armed. A wrong RTC
        // is a top cause of the firmware alarm never firing, and knowing the clock state at arm — not just
        // now — tells whether the arm even had a chance (skew ~0 but the strap still rejects ⇒ a corrupted
        // alarm register, not a clock problem).
        d.set(strapClockNow - Int(Date().timeIntervalSince1970), forKey: "alarm.lastArmClockSkew")
        // #34: live HR at the moment of the arm, purely to test a hypothesis raised on a reporter's log —
        // morning wake-up and morning short-horizon arms have fired reliably since v9.0.0, but an identical
        // evening short-horizon arm (same code path, same commands, no day/night branch anywhere in this
        // function) did not. One firmware-side explanation that would fit every reported case: the
        // physical alarm haptic might only fire while the strap's OWN sleep/rest detection considers the
        // wearer sleep-adjacent, independent of anything NOOP sends. This doesn't prove or fix that — it's
        // a free read of state already tracked live, logged so the next reported failure (ideally an
        // evening one) can be compared against the resting HR of the successful arms already on file. `nil`
        // (no key written) means no HR had streamed yet at arm time, not zero.
        d.set(state.heartRate, forKey: "alarm.lastArmHeartRate")
    }

    /// Disarm the currently-armed firmware alarm.
    func disableStrapAlarm() {
        // #34: clear the "strap keeps rejecting the alarm" streak/warning — it's about an ACTIVE arm being
        // refused, and there's nothing armed to refuse once disarmed.
        UserDefaults.standard.set(0, forKey: "alarm.rejectStreak")
        // #730: report the OUTCOME, not the intent — using the SAME `commandChannelReady` gate the arm
        // path already uses (it reports "queued" rather than a false "armed"). The disarm never adopted
        // it: `send` drops the write when the link isn't up and logs "ignored — not connected", then this
        // logged "Alarm: disarmed" anyway, telling the user the firmware alarm was cleared when the
        // command never reached the strap — so a strap that IS armed would still buzz. (`applySmartAlarm`
        // now re-runs on connectSettled, so a deferred disarm is re-issued once the link is really up.)
        let willReach = commandChannelReady
        // Latch a dropped disarm so the connect-settle hook can re-issue exactly this case, WITHOUT
        // making every connect send a DISABLE_ALARM for the many users who never armed one.
        disarmPending = !willReach
        if selectedModel.deviceFamily == .whoop5 {
            // 5/MG DISABLE_ALARM is REVISION_2 [0x02, 0xFF]; the rev-1 [0x01] form below is WHOOP4.
            send(.disableAlarm, payload: AlarmPayload.disableRev2())
            log(willReach ? "Alarm: disarmed (5/MG rev2)"
                          : "Alarm: disarm NOT sent — not connected; will retry on connect (strap may still be armed)")
            return
        }
        send(.disableAlarm, payload: [0x01])
        log(willReach ? "Alarm: disarmed"
                      : "Alarm: disarm NOT sent — not connected; will retry on connect (strap may still be armed)")
    }

    /// Request the currently-armed alarm time from the strap (response arrives on cmd-notify char).
    /// Parsing the reply is optional/bonus — the raw bytes will appear in the BLE log.
    func getStrapAlarm() {
        send(.getAlarmTime, payload: [0x01])
        log("Alarm: requested current alarm time")
    }

    /// One-shot user buzz (#921): the on-device-confirmed "vibrate the strap now" sequence.
    ///
    /// Uses RUN_HAPTICS_PATTERN (cmd 79) with patternId=2, 3 loops (the same pattern the official
    /// WHOOP app uses for alarms; verified: patternId=2, observed for interoperability), plus RUN_ALARM
    /// (cmd 68) as a belt-and-suspenders. patternId=2 gives the characteristic graduated alarm buzz.
    /// A bare RUN_HAPTICS_PATTERN write is exactly what a WHOOP 4.0 was reported ignoring on the
    /// Siri-shortcut path (#921), so every user-facing one-shot buzz (the Live "Buzz strap" button,
    /// the Buzz Strap App Intent) routes through here instead of composing its own write.
    ///
    /// Both writes are ACKNOWLEDGED (.withResponse): a backgrounded shortcut on a busy link can
    /// silently drop an unacknowledged write, which is how #921 logged "Run Haptics" with no
    /// vibration. On a 5/MG, send() remaps cmd 79 to the maverick 0x13 notify buzz and RUN_ALARM
    /// carries the REVISION_2 body; both are already on the 5/MG command allowlist.
    ///
    /// Alternative waveform form (12-byte):
    ///   [wfe1=47, wfe2=152, 0,0,0,0,0,0, loop u16=0, overall_loop=7, dur=30]
    /// is a note for future refinement; the preset id=2 form is simpler and confirmed to buzz on-device.
    ///
    /// Haptic firing cannot be verified in the simulator (no strap motor). Test on-device only.
    func buzzStrapOnce() {
        send(.runHapticsPattern, payload: [2, 3, 0, 0, 0], writeType: .withResponse)  // patternId=2, 3 loops (5/MG: send() remaps to the maverick notify buzz)
        if selectedModel.deviceFamily == .whoop5 {
            send(.runAlarm, payload: AlarmPayload.runAlarmRev2(), writeType: .withResponse)   // REVISION_2 [0x02, alarmId]
            log("Buzz: one-shot fired (5/MG maverick buzz + runAlarm rev2, acked)")
            return
        }
        send(.runAlarm, payload: [0x01], writeType: .withResponse)
        log("Buzz: one-shot fired (patternId=2 loops=3 + runAlarm, acked)")
    }

    /// Haptic Clock (#460): buzz the current wall-clock time out on the strap so the user can read it
    /// off their wrist without a screen. The pure, unit-tested `HapticClock` encoder turns now into an
    /// ordered pulse list (long = a "ten", short = a "unit", in HH-tens / HH-units / MM-tens / MM-units
    /// order); we then schedule each pulse with `DispatchQueue.main.asyncAfter`, firing the EXISTING
    /// maverick notification buzz (`runHapticsPattern`, remapped to the cmd-0x13 notify body in `send`)
    /// at each pulse's start. Only the SCHEDULE is new — the buzz itself is the hardware-confirmed one.
    ///
    /// `is24h` controls 12- vs 24-hour reading; a Settings toggle should supply it (default 12h — see
    /// `concerns`). Public so a Settings button can trigger it. Long-press / double-tap strap input is
    /// hardware-dependent and not wired (no tap event is parsed yet — see `hardwareUnverifiable`).
    ///
    /// Each WHOOP notification buzz is a fixed-length motor pulse, so we can't vary the on-time per
    /// pulse from the app; instead we map a LONG pulse to two stacked buzzes and a SHORT pulse to one,
    /// which the wrist feels as "longer vs shorter". Pulse-feel timing can only be confirmed on a real
    /// strap motor — best-effort here (see `hardwareUnverifiable`).
    public func buzzTimeNow(is24h: Bool = false, at date: Date = Date()) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let pulses = HapticClock.pulses(hour: comps.hour ?? 0, minute: comps.minute ?? 0, is24h: is24h)
        guard !pulses.isEmpty else {
            log("Haptic Clock: nothing to buzz (00:00 in 24h form).")
            return
        }
        log("Haptic Clock: buzzing \(pulses.count) pulses for the current time (\(is24h ? "24h" : "12h")).")
        // Walk the encoder's pulse list, converting each (durationMs,gapMs) into a scheduled buzz.
        // A long pulse is felt as a heavier buzz (2 stacked loops); a short pulse as a light one (1).
        var offsetMs = 0
        for pulse in pulses {
            let loops = pulse.isLong ? 2 : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs)) { [weak self] in
                // patternId/loops payload — send() remaps this to the 5/MG maverick notify buzz; on a
                // WHOOP 4.0 it's the native runHapticsPattern. Same call the inactivity nudge uses.
                self?.send(.runHapticsPattern, payload: [2, UInt8(clamping: loops), 0, 0, 0])
            }
            offsetMs += pulse.durationMs + pulse.gapMs
        }
    }

    /// Inactivity reminder (#419): on each natural offload completion, run the shipped, unit-tested
    /// `SedentaryDetector` over the freshly-arrived gravity window and buzz the wrist if the user has
    /// been seated too long. NO offload-timer change — a read-only hook on an event that already
    /// happens, so the nudge lags the stillness by the offload cadence (~7-15 min). Best-effort.
    ///
    /// All gating + de-dup lives in the engine: we only supply honest inputs (recent gravity, the live
    /// `state.worn` flag, the prefs→`SedentaryConfig`/`SedentaryState`) and persist the engine's
    /// `nextState`. The engine acts only when this offload advanced the newest gravity ts (a replayed /
    /// no-new-rows sync can't re-buzz), only for a bout whose end is still current, only through its
    /// mayBuzz gate (master / quiet hours / worn / active-hours-by-bout-end-time), and either re-nudges a
    /// continuing bout on the user's cadence or alerts a distinct new bout separated by movement.
    ///
    /// Mirrors the async pattern of checkStrapLiveness: the gravity read only the Collector can do (it
    /// owns the concrete store) hops onto a @MainActor Task, then the gated buzz + state save run back on
    /// the main actor. Haptic firing can't be verified in the simulator — test on-device.
    private func maybeBuzzInactivity() {
        guard InactivityPrefs.isEnabled() else { return }   // cheap pre-check before any DB read
        Task { @MainActor in
            let nowSec = Int(Date().timeIntervalSince1970)
            let from = nowSec - BLEManager.inactivityLookbackSeconds
            let gravity = await collector?.recentGravity(from: from, to: nowSec) ?? []
            guard !gravity.isEmpty else { return }
            // Sleep & Rest test mode (Group E): bank the live gravity window for the readout's coverage
            // figure. Gated on the zero-cost active() Bool, so this is a no-op when the mode is off.
            if TestCentre.active(.sleep) { state.recordSleepLiveGravity(gravity) }

            let decision = SedentaryDetector.evaluate(
                gravity, state: InactivityPrefs.loadState(),
                config: InactivityPrefs.loadConfig(),
                worn: state.worn, nowSec: nowSec,
                tzOffsetSec: InactivityPrefs.tzOffsetSec(nowSec))
            // The engine always advances lastProcessedGravityTs when a window arrived, so persist the
            // de-dup state every run — a replayed window then can't re-buzz across a relaunch.
            InactivityPrefs.saveState(decision.nextState)

            if decision.shouldBuzz {
                send(.runHapticsPattern, payload: [2, UInt8(clamping: decision.buzzLoops), 0, 0, 0])
                let mins = Int((decision.bout?.durationS ?? 0) / 60)
                log("Inactivity: nudged after a \(mins)-min sedentary stretch.")
                AppModel.postInactivity(minutes: mins)   // #577 — local notification (iOS-only, self-gated on notif.masterEnabled)
            }
        }
    }

    /// Parse a standard BLE Heart Rate Measurement (0x2A37) via the pure StandardHeartRate parser.
    private func parseStandardHR(_ data: [UInt8]) {
        guard let m = StandardHeartRate.parse(data) else {
            log("HR notify parse failed: \(hex(data))")
            return
        }
        let now = Date()
        if lastStandardHRLogAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            lastStandardHRLogAt = now
            let plausibility = (30...220).contains(m.hr) ? "" : " ignored"
            log("HR notify: \(m.hr) bpm\(plausibility), rr=\(m.rr.count)")
        }
        // R-R: the standard profile is the RELIABLE source (the custom REALTIME_DATA stream
        // usually reports rr_count=0), so always surface intervals when present. setRRIntervals also
        // feeds the Live console's rolling rrRecent buffer.
        if !m.rr.isEmpty { state.setRRIntervals(m.rr) }
        // HR: the standard 0x2A37 profile is the RELIABLE source (BLE-standard, ~1Hz). Let it
        // drive the value whenever it's physiologically plausible; reject 0/garbage (off-wrist).
        // AppModel medians these into a stable display value. live perf: only publish on a real
        // change so a steady resting HR doesn't re-render the whole Live console every second.
        if m.hr >= 30 && m.hr <= 220, state.heartRate != m.hr { state.heartRate = m.hr }
        // Record it continuously — independent of the realtime stream or the open screen.
        collector?.ingestStandardHR(hr: m.hr, rr: m.rr, at: Int(Date().timeIntervalSince1970))
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: @preconcurrency CBCentralManagerDelegate {
    /// What `centralManagerDidUpdateState` should do about an `.unauthorized` central state, decided
    /// from the TCC grant (`CBManager.authorization`) rather than the transient central state alone.
    /// Pure and stateless so the #391 discrimination is pinnable by a unit test without CoreBluetooth
    /// plumbing. Design from digitalerdude's #407; test seam per tigercraft4's #407 review.
    enum UnauthorizedAction: Equatable {
        /// The grant itself reads denied/restricted — a genuine denial; latch the #280/#295 banner now.
        case showRegrantBanner
        /// The grant reads granted (or undecided): the macOS cold-start settling window (#391), or a
        /// first-run prompt still on screen. Wait — but under a settle deadline (see
        /// `armUnauthorizedSettleDeadline`), because a WEDGED grant (#429: an unsigned build's stale
        /// TCC row) presents exactly the same way and never settles.
        case waitForSettle
    }

    static func unauthorizedAction(_ authorization: CBManagerAuthorization) -> UnauthorizedAction {
        switch authorization {
        case .denied, .restricted: return .showRegrantBanner
        default: return .waitForSettle
        }
    }

    /// How long an apparently-transient `.unauthorized` may sit unresolved before it is treated as a
    /// wedged grant (#429) and the re-grant banner shows anyway. The #391 reporter's cold-start settle
    /// took ~40 s (unauthorized 14:51:44 → poweredOn 14:52:25), so 120 s clears the observed case with
    /// a wide margin while still surfacing the wedged case in a bounded time instead of never.
    static let unauthorizedSettleSeconds = 120

    /// The #280/#295 "re-grant Bluetooth" banner, verbatim. One home so the immediate genuine-denial
    /// path and the #391 settle-deadline escalation can never drift apart.
    private func showBluetoothRegrantBanner() {
        // #295: an unsigned/ad-hoc build's code identity changes on every release, so a Bluetooth
        // toggle that already reads "on" from a PRIOR build's grant may not carry over — the
        // message needs to tell the user to re-toggle it, not just check that it's on.
        #if os(macOS)
        state.lastSyncError = "NOOP isn't allowed to use Bluetooth. Open System Settings → Privacy & Security → Bluetooth — if NOOP is already listed there, toggle it off and back on (a new NOOP build needs a fresh grant), then quit and reopen NOOP."
        #else
        state.lastSyncError = "NOOP isn't allowed to use Bluetooth. Open iPhone Settings → NOOP → Bluetooth — if it's already on, toggle it off and back on, then quit and reopen NOOP."
        #endif
        log("Bluetooth permission not granted (unauthorized) — cannot scan or connect")
        radioStateErrorShown = true
    }

    /// #391 escalation: the transient-looking `.unauthorized` gets `unauthorizedSettleSeconds` to
    /// resolve (every real settle produces another state callback, which cancels this). If it fires,
    /// the state is STILL unauthorized with a granted TCC read — the wedged-grant shape (#429), where
    /// staying silent would strand the user with no explanation at all — so show the re-grant banner,
    /// whose off/on-toggle instruction is exactly the wedged case's fix.
    private func armUnauthorizedSettleDeadline() {
        unauthorizedSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.unauthorizedSettleWork = nil
            guard self.central?.state == .unauthorized else { return }
            self.log("Central still unauthorized \(BLEManager.unauthorizedSettleSeconds)s after a granted TCC read — not cold-start settling (#391); treating as a wedged grant (#429) and showing the re-grant banner")
            self.showBluetoothRegrantBanner()
        }
        unauthorizedSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.unauthorizedSettleSeconds), execute: work)
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state: \(central.state.rawValue) (5 = poweredOn)")
        // #391: ANY state update means the cold-start settling window moved on — a pending
        // unauthorized-settle escalation is obsolete whether the new state is good news (poweredOn)
        // or its own banner-worthy case (poweredOff handles itself below).
        unauthorizedSettleWork?.cancel()
        unauthorizedSettleWork = nil
        guard central.state == .poweredOn else {
            // #280: a non-poweredOn radio state used to be a SILENT return — the strap log showed only
            // "Central state: 3" and the UI just read "not connected", so a user whose Mac had denied NOOP
            // Bluetooth (.unauthorized == raw 3) had nothing explaining why no strap was ever found. This is
            // the #280 case: an unsigned universal rebuild (8.4.0) gets a new code identity, so the earlier
            // macOS Bluetooth TCC grant no longer applied and CoreBluetooth reported .unauthorized before
            // any scan/connect. Surface the actionable states via lastSyncError (shown in Live + Today);
            // leave .unknown/.resetting alone — they're transient and the next state update resolves them.
            // Android already surfaces all three (WhoopBleClient: no-LE / off / permission), so this brings
            // iOS+macOS up to that parity rather than adding a new behaviour.
            switch central.state {
            case .unauthorized:
                // #391 (design from digitalerdude's #407): CoreBluetooth on macOS can transiently report
                // `.unauthorized` during the cold-start settling window (before the central finishes
                // connecting to bluetoothd) even when the TCC grant is fine — the state then advances to
                // .poweredOff/.poweredOn on the next callback and the strap connects. The `authorization`
                // property reads the TCC grant DIRECTLY, independent of that transient state, so it can tell
                // a genuine denial (#280/#295) from the settling case — latching the re-grant banner on ANY
                // `.unauthorized` pushed users to toggle Bluetooth off/on to clear a false message. The
                // settle path is NOT unbounded silence: a wedged grant (#429) presents identically and never
                // settles, so it runs under `armUnauthorizedSettleDeadline`'s one-shot escalation.
                // The CLASS property (`CBCentralManager.authorization`), not the `central.authorization`
                // instance property — that one is deprecated on iOS (13.0 → 13.1); both read the same grant.
                switch Self.unauthorizedAction(CBCentralManager.authorization) {
                case .showRegrantBanner:
                    showBluetoothRegrantBanner()
                case .waitForSettle:
                    log("Central reported unauthorized but the Bluetooth grant reads OK — transient cold-start settling (#391); re-grant banner deferred \(Self.unauthorizedSettleSeconds)s")
                    armUnauthorizedSettleDeadline()
                }
            case .poweredOff:
                state.lastSyncError = "Bluetooth is off. Turn it on to connect to your strap."
                log("Bluetooth is off — cannot scan or connect")
                radioStateErrorShown = true
            case .unsupported:
                state.lastSyncError = "This device can't use Bluetooth Low Energy."
                log("Bluetooth LE unsupported on this device")
                radioStateErrorShown = true
            default:
                break
            }
            return
        }
        // #280: radio is back — clear a stale radio-state banner (only one WE set), so a "Bluetooth is off"
        // message doesn't outlive the radio coming on. A genuine sync error is left untouched.
        if radioStateErrorShown {
            state.lastSyncError = nil
            radioStateErrorShown = false
        }
        // Bootstrap the async store once on first poweredOn (idempotent if already set).
        Task { @MainActor in await bootstrapStore() }
        if let p = restoredPeripheral {
            log("poweredOn with restored peripheral — reconnecting \(p.identifier)")
            if p.state != .connected {
                connectRestored(p, reason: "poweredOn")
            } else {
                discoverPrimaryServices(on: p)
            }
        } else {
            // #78 hole-2: poweredOn is SYSTEM-initiated (every Bluetooth toggle / bluetoothd restart
            // lands here), so it must not reset a latched bond-loop give-up - it gets ONE bounded
            // attempt with the give-up intact (Android onBluetoothRadioOn parity), not a fresh hammer.
            connectFromSystem()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "unknown"
        // #716: the seeded "my-whoop" device has model "WHOOP" (no generation). Once a live scan
        // confirms which service family the strap advertises, stamp the correct model so
        // forRegistryModel returns the right DeviceFamily (fixes skin-temp ADC scale + display).
        if !modelStamped, let rs = registryStore,
           let stale = try? rs.all().first(where: { $0.status == .active && $0.model == "WHOOP" }) {
            let correct = selectedModel == .whoop4 ? "WHOOP 4.0" : "WHOOP 5.0 / MG"
            try? rs.setModel(stale.id, model: correct)
            log("Updated device model from \"WHOOP\" to \"\(correct)\" (#716)")
            modelStamped = true
        }
        let advertisedServiceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { $0.uuidString.lowercased() }
        let scanDecision = whoopGattScanDecision(
            selectedServiceUUIDString: selectedModel.scanService.uuidString,
            advertisedServiceUUIDStrings: advertisedServiceUUIDs
        )
        if !scanDecision.shouldConnect {
            if let family = scanDecision.unsupportedFamily {
                log("Discovered \(name) (rssi \(RSSI)) — \(family.diagnosticUnsupportedMessage)")
                return
            }
            log("Discovered \(name) (rssi \(RSSI)) without \(selectedModel.displayName) service — ignoring")
            return
        }
        // Multi-WHOOP present-scan (Add-a-WHOOP wizard): collect the strap, do NOT auto-connect, and
        // return before touching the connect flow. Only reachable when the wizard explicitly turned on
        // `isPresentingScan` via scanForWhoops(); on the default path (false) this branch is skipped
        // entirely and the auto-connect code below runs exactly as before.
        if isPresentingScan {
            let uuid = peripheral.identifier.uuidString
            if let i = discoveredWhoops.firstIndex(where: { $0.uuid == uuid }) {
                discoveredWhoops[i] = (uuid: uuid, name: name, rssi: RSSI.intValue)   // refresh RSSI
            } else {
                discoveredWhoops.append((uuid: uuid, name: name, rssi: RSSI.intValue))
            }
            return
        }
        // Multi-WHOOP preferred-peripheral filter: when the app has pinned a specific strap, ignore any
        // OTHER discovered WHOOP and keep scanning. When `preferredPeripheralUUID == nil` (the single-
        // WHOOP default) this guard is skipped and the original "connect to the first discovered" path
        // below is byte-for-byte unchanged.
        if let preferred = preferredPeripheralUUID, peripheral.identifier != preferred {
            log("Discovered \(name) (\(peripheral.identifier)) — not the preferred strap; ignoring")
            return
        }
        cancelScanFallback()
        persistSelectedModel(selectedModel)
        log("Discovered \(name) (rssi \(RSSI)) — connecting")
        central.stopScan()
        preparePeripheral(peripheral)
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelScanFallback()
        cancelPendingConnectProbe()   // #730: the connect resolved; no pending-connect log needed
        failedConnectAttempts = 0   // a successful connect clears the reconnect backoff (#414)
        restoredPeripheral = nil
        preparePeripheral(peripheral)
        // Clear the per-connection bond BEFORE publishing the connected uuid below. SourceCoordinator's #52
        // re-adoption gate keys off `encryptedBond` at the instant `connectedPeripheralUUID` is observed —
        // an ordinary `didConnect` publish must always read false (only the deliberate post-bond #52
        // handoff republish carries it true), so this clear has to precede the publish, not follow it.
        state.encryptedBond = false   // re-proved per connection at the genuine-bond site (#69)
        // Multi-WHOOP: publish the strap's stable BLE identity so the app can persist it onto the active
        // registry device (it observes this and calls registry.setPeripheralId). Additive observation
        // only — BLEManager stays decoupled from the store and the connect flow below is unchanged.
        connectedPeripheralUUID = peripheral.identifier.uuidString
        state.connected = true
        // A connect succeeded → clear the stale-bond re-pair guide UNLESS we are in a known bond-loop
        // (#617). In that loop the strap "connects" every ~3 s before timing out again, so clearing here
        // wiped the guide on EVERY cycle: it flashed for ~1 s and vanished, so the user could never read it
        // (#711). While tripped, keep the guide up and instead clear it once THIS connection proves healthy,
        // i.e. it survives past the loop's quick-timeout window (below), or on a clean teardown
        // (disconnect() resets the detector and clears the guide too).
        connectGeneration &+= 1
        if postBondLoop.tripped {
            let gen = connectGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + postBondLoop.quickTimeoutWindow + 1) { [weak self] in
                // Clear only if the SAME continuous connection is still up. A reconnect (loop cycle) bumps
                // connectGeneration, so a transient cycle-connect can't satisfy this even though the
                // CBPeripheral object is reused. Without the generation, the timer could fire during a later
                // cycle's brief connect and wrongly wipe the guide, back to flashing.
                guard let self, self.state.connected, self.connectGeneration == gen else { return }
                self.postBondLoop.reset()        // survived the window → the bond-loop is resolved
                self.state.reconnectGuide = nil
            }
        } else {
            state.reconnectGuide = nil
        }
        lastDataAt = Date()
        log("Connected — discovering services")
        // #1020: stamped OUTSIDE the gate below. Test Centre is usually switched on AFTER something looks
        // wrong, so a stamp taken only when the mode happened to be on at connect time would either be
        // missing or, worse, still hold a PREVIOUS session's start - reporting a duration that spans the
        // gap between them. A field assignment, not a log line, so it costs nothing when the mode is off.
        connSessionStartedAt = Date()
        // Connection test mode: report the connect latency + the uptime-start marker the readout reads.
        // Gated zero-cost: the .connection bool is read before any string is built, so this is a no-op
        // when the mode is off. Behaviour-neutral diagnostics only - the connect flow above is unchanged.
        if TestCentre.active(.connection) {
            let nowUnix = Int(Date().timeIntervalSince1970)
            let latencyMs = connectAttemptStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            state.append(log: "connect up gen=\(connectGeneration) "
                + "latencyMs=\(latencyMs.map(String.init) ?? "?") uptimeStart=\(nowUnix)", domain: .connection)
        }
        discoverPrimaryServices(on: peripheral)
    }

    /// Connection test mode: a STABLE, integer-token reason for a BLE error, for parity with Android's
    /// integer GATT status (which emits `status<N>`) and a tighter export surface than a localized,
    /// locale-dependent free-text string. We emit the `CBError`/`CBATTError` raw enum value (an Int), so
    /// the token is locale-independent and carries no free text. A nil error reads "unknown"; an error
    /// from neither CoreBluetooth domain reads "code?" (no localizedDescription, which could carry text).
    private func connErrorToken(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        if let cb = error as? CBError { return "cbError\(cb.code.rawValue)" }
        if let att = error as? CBATTError { return "cbAttError\(att.code.rawValue)" }
        return "code?"
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        Task { @MainActor in await collector?.flush() }
        // Reboot trail: if a user reboot is in flight, this drop is the strap acting on it. Log how long
        // the link stayed up (a real reboot drops within ~1-2 s) and cancel the no-disconnect watchdog. The
        // reconnect time is logged separately once the handshake completes. `rebootRequestedAt` stays set so
        // the handshake can compute the round-trip; it's cleared there (or by the watchdog).
        if let t = rebootRequestedAt {
            let ms = Int(Double(DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds) / 1_000_000)
            rebootTimeoutWork?.cancel(); rebootTimeoutWork = nil
            // #275: a dropped LINK only proves a reboot on WHOOP 5.0 (verified fw). On WHOOP 4.0 the frame
            // is unconfirmed — opcode 29/payload01 was observed to drop the BLE link WITHOUT power-cycling
            // the strap (the sensor stayed on) — so don't claim a reboot; report the drop honestly. Twin of
            // Kotlin handleDisconnect.
            if selectedModel.deviceFamily == .whoop5 {
                log("reboot: link dropped \(ms)ms after send — reboot took effect; awaiting reconnect")
            } else {
                log("reboot: link dropped \(ms)ms after send — but a WHOOP 4.0 reboot isn't confirmed; a dropped link alone isn't proof (a real reboot also switches the sensor light off). Awaiting reconnect")
            }
        }
        // #80 marginal-radio detection: judge this drop BEFORE the state resets below clobber the
        // arm timestamp. A drop that is unintentional, error-bearing, and lands shortly after we armed
        // the R10/R11 burst is the marginal-radio tell. Feed the detector; if it trips, the NEXT connect
        // skips the heavy arm (the flag is intentionally NOT reset on disconnect so it survives rescan).
        let timedOut = !intentionalDisconnect && error != nil
        let sinceArm = realtimeArmedAt.map { Date().timeIntervalSince($0) }
        if marginalRadio.connectionEnded(wasArmed: realtimeArmedAt != nil,
                                         secondsSinceArm: sinceArm,
                                         timedOut: timedOut) {
            standardHRFallback = true
            log("Marginal radio (#80): \(marginalRadio.consecutiveArmTimeouts) arm-then-timeout cycles — next connect uses standard-HR mode (0x2A37 only)")
        }
        // #617 bond-loop detection: same pre-reset read. The bond-loop tell is a CONNECTION TIMEOUT that
        // lands within seconds of a genuine bond — bond → drop → rescan → bond → drop, forever. We require
        // the OS to classify the drop as a connection timeout (`CBError.connectionTimeout`), not merely any
        // error, so a one-off radio blip or a different failure doesn't get mistaken for the loop. Once it
        // trips, surface the EXISTING re-pair guide (the same forget-and-re-pair steps the #74/firmware-reset
        // path shows) rather than letting the link loop silently and drain the battery.
        let connTimedOut: Bool = (error as? CBError)?.code == .connectionTimeout
        let sinceBond = bondedAt.map { Date().timeIntervalSince($0) }
        if postBondLoop.connectionEnded(wasBonded: bondedAt != nil,
                                        secondsSinceBond: sinceBond,
                                        timedOut: connTimedOut && !intentionalDisconnect) {
            log("Bond-loop (#617): \(postBondLoop.consecutiveBondTimeouts) bond-then-timeout cycles — surfacing the re-pair guide and pausing auto-reconnect")
            // #844 — the loop is bond → drop → 3s rescan → bond → drop, forever, draining the battery.
            // Surfacing the guide alone left the involuntary-drop rescan (below) running. Pause auto-reconnect
            // too: the disconnect rescan and didFailToConnect both already skip while this is set, and a user
            // Connect (connect()) or a genuine bond re-arms it. We do NOT touch the bond/parse path — the bond
            // is real; the stale OS pairing is the problem, which the guide tells the user how to clear.
            autoReconnectPausedForBondLoop = true
            bondLoopPausedAt = Date()   // the #78 hole-4 salvage probe covers this pause too (one bounded cycle)
            if TestCentre.active(.connection) {
                state.append(log: "reconnect paused=bondLoop (#617: \(postBondLoop.consecutiveBondTimeouts) bond-then-timeout cycles)", domain: .connection)
            }
            if state.reconnectGuide == nil {
                state.reconnectGuide = """
                Your strap keeps connecting and then dropping a second later. This is almost always a stale Bluetooth pairing - usually after a WHOOP firmware update, or the official WHOOP app holding the strap. NOOP works fine once it's re-paired:

                1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
                2. Open System Settings → Bluetooth and Forget your WHOOP if it's listed.
                3. Tap the strap repeatedly until its LEDs flash blue (pairing mode).
                4. Come back here and reconnect.
                """
            }
        }
        bondedAt = nil   // cleared after the bond-loop detector above read it (#617)
        state.connected = false
        state.encryptedBond = false   // cleared with didBond; next session must re-prove the bond (#69)
        state.charging = nil          // a stale charging flag must not outlive the link
        state.batteryMv = nil         // #592: a stale pack voltage must not outlive the link
        state.strapFirmware = nil     // a stale firmware version must not outlive the link
        state.extendedBatteryProbe = nil  // #592: drop a stale probe result on disconnect
        state.bodyLocationProbe = nil     // #690: drop a stale probe result on disconnect
        state.featureFlagProbe = nil      // #761: drop a stale probe result on disconnect
        // …and abandon a walk the link interrupted, which also re-closes the 117/118 send() allowlist.
        featureFlagReport = nil
        featureFlagAwaiting = nil
        state.ecgProbe = nil          // MG ECG: drop a stale probe result on disconnect
        // Close any open ECG listen window. The strap forgets the ECG toggles across a disconnect, and a
        // half-finished run must not fold its steps into the next one or render a verdict for a link that
        // is already gone.
        ecgProbeDeadline = nil
        ecgProbeRunToken &+= 1
        ecgProbeSteps = []
        ecgProbeCandidates = []
        ecgProbePacketsSeen = 0
        // The DIS strings belong to the link that just dropped; a stale variant must not keep an MG-only
        // capability unlocked for whatever connects next.
        state.whoop5Variant = nil
        state.deviceConfigProbe = nil     // #103: drop a stale probe result on disconnect
        // …and abandon a plan the link interrupted, re-closing the 121/128 send() allowlist.
        deviceConfigReport = nil
        deviceConfigAwaiting = nil
        // #174: a disable run interrupted mid-plan is RENDERED rather than dropped — unlike the read-only
        // probes above it has already written to the strap, so the user must be told exactly how far it got
        // and which keys are still set. This publishes the partial report and re-closes the 128 allowlist.
        abandonR22DisableRun("the strap disconnected mid-run")
        state.clearBiometrics()       // and a stale HR / R-R must not outlive the link either
        state.liveFeedActive = false  // a drop while Live is open must not leave a stale "Stop live feed"
        didBond = false
        whoop5RealtimeArmed = false
        // The strap forgets the realtime-HR toggle across a disconnect; the post-bond branch re-arms it
        // from `wantsRealtime`. Clear only the "what we last sent" flag — `screenWantsRealtime` /
        // `keepRealtimeForData` (and thus `wantsRealtime`) are intent and must survive a reconnect so the
        // stream comes back automatically.
        realtimeArmed = false
        whoop5SessionStarted = false
        clockRequested = false
        clockRetries = 0
        connectHandshakeDone = false
        cmdNotifyConfirmedActive = false   // #34: a fresh connection needs its own notify-confirm + settle
        connectSettledSignaled = false
        restoreNeedsResubscribe = false    // #613: a real reconnect isn't a restore — never force-toggle here
        realtimeArmedAt = nil   // cleared after the marginal-radio detector above read it (#80)
        // Reset backfill state so the next connect starts a fresh offload (incl. the syncing pill —
        // a dropped link mid-offload must not leave "Syncing strap history…" stuck on, #77).
        backfillStarted = false
        // #364: the auto-continue streak + spin-detector are per-connection — a fresh connection earns a
        // fresh budget of back-to-back re-kicks and starts its trim-advance comparison from scratch.
        consecutiveAutoContinues = 0
        lastSessionEndTrim = nil
        backfilling = false
        state.backfilling = false
        state.syncChunksThisSession = 0
        // A mid-sync disconnect bypasses exitBackfilling, so clear the reject counters here too —
        // otherwise a stale non-zero count survives until the next beginBackfill. (#77/#91)
        state.rejectedFramesThisSession = 0
        state.rejectedFramesUnarchived = 0
        state.decodedChunksThisSession = 0
        state.consoleChunksThisSession = 0
        state.r22FlagsAccepted = 0
        state.deepPacketsThisSession = 0
        lastOffloadFrameAt = nil   // #174: don't carry a stale cooldown reference into the next session
        // #580: a fresh connection earns a fresh empty-offload streak — a strap that was history-empty last
        // session might bank this time (or vice-versa). Clear the experimental note too; the next offload
        // re-derives it. (The honest flag is per-link, like the syncing pill / reject counters above.)
        whoop5EmptyOffload.reset()
        state.historySyncExperimental = false
        lastBatteryReadAt = nil   // #battery: next connect's first enableLiveNotifications re-seeds the 5/MG battery reading
        // #612: the display flag only, not the underlying emptySyncTracker streak (that counter
        // deliberately survives a reconnect — unchanged, existing behaviour). A fresh link re-derives
        // this from its own next HISTORY_COMPLETE.
        state.sustainedEmptyOffload = false
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        backfillDraining = false
        uploadTimer?.cancel()
        uploadTimer = nil
        backfillTimer?.cancel()
        backfillTimer = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        resetCharacteristics()
        puffinRecorder.flush()   // persist any buffered puffin capture frames before reconnect
        puffinEventLog.close()   // release the event-log handle so the file is safe to export
        puffinDeepBufferLog.close()   // same for the high-rate deep-buffer log (#423)
        Task { @MainActor in await collector?.flushStandardHR() }   // persist any buffered 0x2A37 HR
        if autoReconnectPausedForBondLoop {
            // #747: the bond keeps being refused, so auto-reconnect is paused: we stop hammering a strap that
            // can't bond (the epitaph + paused hint were already surfaced when the give-up tripped). The user
            // re-arms it by tapping Connect. We do NOT schedule a rescan here.
            log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ""); auto-reconnect paused (strap keeps refusing to pair; tap Connect once it's free)")
            if TestCentre.active(.connection) {
                state.append(log: "connect down (uptime ends)", domain: .connection)
                state.append(log: "reconnect paused=bondLoop (strap refusing bond)", domain: .connection)
            }
        } else if !intentionalDisconnect {
            log("Disconnected\(error.map { " — \($0.localizedDescription)" } ?? ""); rescanning in 3s")
            // Connection test mode: count + describe the involuntary reconnect churn, and mark the link
            // down for the uptime readout. Gated zero-cost (the .connection bool is read before any string
            // is built). Diagnostic only - the rescan above is unchanged. The count increments only on an
            // INVOLUNTARY drop, mirroring an actual reconnect cycle.
            connReconnectCount += 1
            if TestCentre.active(.connection) {
                let reason = (error as? CBError)?.code == .connectionTimeout
                    ? "connectionTimeout" : connErrorToken(error)
                // #1020: the session's length separates the causes of a drop at a glance. Same suffix the
                // Android twin emits, so the shared ConnectionReadout parser sees one format.
                let held = ConnectionTrace.sessionHeldSuffix(
                    millis: connSessionStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1)
                state.append(log: "connect down (uptime ends\(held))", domain: .connection)
                state.append(log: "reconnect n=\(connReconnectCount) reason=\(reason)", domain: .connection)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                // #78 hole-3: a timer in flight when the give-up trips must not fire an extra attempt
                // (and, via connectFromSystem, can never reset the pause the way the old connect() did).
                guard let self, !self.intentionalDisconnect, !self.autoReconnectPausedForBondLoop else { return }
                self.connectFromSystem()
            }
        } else {
            log("Disconnected (intentional)")
            // A user-initiated teardown ends the churn count for the run and marks the link down so the
            // uptime readout reads "not connected" rather than a stale uptime. Gated zero-cost.
            connReconnectCount = 0
            if TestCentre.active(.connection) {
                state.append(log: "connect down (intentional)", domain: .connection)
            }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        cancelPendingConnectProbe()   // #730: it FAILED rather than pending — this log is the answer
        log("Failed to connect\(error.map { " — \($0.localizedDescription)" } ?? "")")
        // The strap wiped its bond (a firmware update, or the official WHOOP app re-bonding it). macOS keeps
        // re-presenting the now-stale pairing key, so every reconnect loops on this same error with no
        // recovery and no user guidance. Surface an actionable re-pair guide instead of failing silently —
        // NOOP itself works fine on the new firmware once the stale bond is cleared. (5/MG firmware reset, 2026-06)
        // Connection test mode: a failed connect is part of the reconnect churn the tester is chasing.
        // Gated zero-cost; diagnostic only - the backoff/guide logic below is unchanged.
        if TestCentre.active(.connection) {
            let reason: String
            if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
                reason = "peerRemovedPairing"   // stable token (strap re-bonded elsewhere or firmware reset)
            } else {
                reason = connErrorToken(error)
            }
            state.append(log: "reconnect n=\(connReconnectCount) failedConnect reason=\(reason)", domain: .connection)
        }
        if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
            state.reconnectGuide = """
            Your strap's Bluetooth pairing was reset - usually by a WHOOP firmware update, or the official WHOOP app reconnecting. NOOP works fine on the new firmware; you just need to re-pair:

            1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
            2. Open System Settings → Bluetooth and Forget “WHOOP MG” if it's listed.
            3. Tap the strap repeatedly until its LEDs flash blue (pairing mode).
            4. Come back here and reconnect.
            """
            return
        }
        // Any other connect failure (e.g. a weak-signal encrypted-handshake timeout on a 5/MG at the
        // edge of range — #414). The disconnect path reschedules a rescan, but didFailToConnect never
        // did, so the loop died here until a manual reconnect. Reschedule with a capped exponential
        // backoff (3, 6, 12, 24, 48, 60s…) so a strap that's genuinely out of range doesn't hammer BLE.
        // #747: don't reschedule while the bond-loop pause is active; the user must free the strap first.
        guard !intentionalDisconnect, !autoReconnectPausedForBondLoop else { return }
        failedConnectAttempts += 1
        let delay = min(60.0, 3.0 * pow(2.0, Double(failedConnectAttempts - 1)))
        log("Reconnecting in \(Int(delay))s (attempt \(failedConnectAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // #78 hole-3: a backoff timer in flight when the give-up trips must not fire an extra
            // attempt (and connectFromSystem never resets the pause the way the old connect() did).
            guard let self, !self.intentionalDisconnect, !self.autoReconnectPausedForBondLoop else { return }
            self.connectFromSystem()
        }
    }

    /// State restoration entry point (M3 background collection).
    /// Stores the restored peripheral and — if already connected — immediately
    /// re-discovers services so `cmdCharacteristic` is re-acquired and
    /// notifications are re-routed without user interaction.
    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first else {
            log("Restore: no peripherals in state dict")
            return
        }
        self.peripheral = p
        self.restoredPeripheral = p
        p.delegate = self
        resetCharacteristics()
        // Re-derive the inbound-decode family from the persisted model. connect()/startScan() set the
        // reassembler + router family, but NEITHER runs on the restore path — so without this a restored
        // WHOOP 5/MG would decode its puffin notify frames with the default .whoop4 framing (different
        // length offset + constant), producing corrupt/empty data for the whole unattended session until
        // the user manually taps connect.
        selectedModel = .persisted
        reassembler = Reassembler(family: selectedModel.deviceFamily)
        router.family = selectedModel.deviceFamily
        configureCollectorFamily()
        // Collection only runs post-bond, so a restored link was already bonded;
        // seed those flags now. `didWriteValueFor` won't re-fire on its own.
        state.bonded = true
        didBond = true
        // #613: didConnect never fires for an ALREADY-connected restored peripheral, so publish the strap
        // identity HERE — BEFORE encryptedBond flips true — so SourceCoordinator sees the ordinary
        // (encryptedBond == false) identity semantics `didConnect` uses (adopt-if-unknown / never clobber a
        // different registered strap), NOT the #52 post-bond re-adoption seam. Without it
        // connectedPeripheralUUID stays nil the whole session: no identity to SourceCoordinator, and the
        // alarm diagnostics read "strap not connected" though the link is up.
        if p.state == .connected { connectedPeripheralUUID = p.identifier.uuidString }
        state.encryptedBond = true   // a restored link was genuinely encrypted-bonded before (#69)
        noteGenuineBond(of: p)   // #52: a restored link was genuinely bonded; eligible as a re-adopt target
        // clockRef is nil in the fresh process after restore, so we must re-request it.
        // Reset the flag so the post-restore didWriteValueFor issues exactly one getClock.
        clockRequested = false
        clockRetries = 0
        // Ensure the store is ready before restored BLE data arrives (idempotent; no-op if already built).
        Task { @MainActor in await bootstrapStore() }
        if p.state == .connected {
            state.connected = true
            // #613: the inherited notify subscriptions come back reported-active but dead. Force one real
            // off→on re-subscribe this session (see `requestNotify`) so live HR/R-R resume AND
            // `didUpdateNotificationStateFor` fires → `cmdNotifyConfirmedActive` → `connectSettled` → the
            // alarm re-arm. Cleared when `connectSettled` bumps.
            restoreNeedsResubscribe = true
            log("Restored CONNECTED peripheral \(p.identifier) — re-discovering services")
            discoverPrimaryServices(on: p)
        } else {
            state.connected = false
            log("Restored DISCONNECTED peripheral \(p.identifier) — reconnect on poweredOn")
            if central.state == .poweredOn {
                connectRestored(p, reason: "willRestoreState")
            } else {
                log("Restore: central not poweredOn yet (state=\(central.state.rawValue)) — deferring to poweredOn")
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: @preconcurrency CBPeripheralDelegate {
    /// Persist the WHOOP family we are actually talking to, so the next launch scans the right service —
    /// what makes a one-time fallback rotation stick (PR#195) — and, on a genuine family switch, untick the
    /// 5/MG-only probes so none carries over to a strap that cannot support it.
    ///
    /// Compares `deviceFamily`, not the raw value: if MG ever splits from plain 5.0 into its own case the
    /// two would share `.whoop5`, and a raw-value compare would then reset on a same-family switch. Mirrors
    /// the Kotlin `persistSelectedModel` service compare.
    private func persistSelectedModel(_ model: WhoopModel) {
        let previous = UserDefaults.standard.string(forKey: "selectedWhoopModel")
        UserDefaults.standard.set(model.rawValue, forKey: "selectedWhoopModel")
        guard let previous,
              let previousModel = WhoopModel(rawValue: previous),
              previousModel.deviceFamily != model.deviceFamily else { return }
        PuffinExperiment.resetFiveMGGatedProbes()
        log("Strap family switched (\(previous) → \(model.rawValue)) — reset 5/MG-only experimental toggles to off.")
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        log("Services discovered: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
        // Record the family from the services the strap ACTUALLY exposes, not just from a scan. The adopt
        // paths in connectCore (`retrieveConnectedPeripherals` / `retrievePeripherals`) reach didConnect
        // WITHOUT ever passing through didDiscover, so a strap attached that way never persisted its family
        // and the next launch scanned the wrong service until the fallback rotation recovered. This is the
        // Apple analogue of the Android fix in WhoopBleClient's connect-time family resolution. Checked
        // once here rather than inside the loop so a strap exposing both services can't thrash the pref.
        if services.contains(where: { $0.uuid == BLEManager.whoop5Service }) {
            persistSelectedModel(.whoop5mg)
        } else if services.contains(where: { $0.uuid == BLEManager.customService }) {
            persistSelectedModel(.whoop4)
        }
        for s in services {
            switch s.uuid {
            case BLEManager.customService:
                peripheral.discoverCharacteristics(
                    [BLEManager.cmdWriteChar, BLEManager.cmdNotifyChar,
                     BLEManager.eventNotifyChar, BLEManager.dataNotifyChar], for: s)
            case BLEManager.heartRateService:
                peripheral.discoverCharacteristics([BLEManager.heartRateChar], for: s)
            case BLEManager.batteryService:
                peripheral.discoverCharacteristics([BLEManager.batteryChar], for: s)
            case BLEManager.disService:
                // #520: read-only identity strings. Discovered here, but READ post-bond (below).
                peripheral.discoverCharacteristics(
                    [BLEManager.disSerialChar, BLEManager.disHwRevChar], for: s)
            case BLEManager.whoop5Service:
                // EXPERIMENTAL WHOOP 5.0/MG path: discover the puffin command + notify characteristics
                // so we can send CLIENT_HELLO and receive frames. Live HR/battery still arrive over the
                // standard 0x2A37/0x2A19 profiles (discovered alongside this); this custom path is
                // unverified on MG hardware.
                log("WHOOP 5/MG detected — discovering puffin characteristics (experimental).")
                peripheral.discoverCharacteristics(
                    [BLEManager.whoop5CmdWriteChar] + BLEManager.whoop5NotifyChars, for: s)
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        if let error {
            log("Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case BLEManager.cmdWriteChar:
                cmdCharacteristic = c
                // THE BONDING TRICK: one confirmed write triggers just-works bonding.
                // GET_BATTERY_LEVEL is benign and what the Mac prototype uses.
                seq = seq &+ 1
                let bondFrame = WhoopCommand.getBatteryLevel.frame(seq: seq, payload: [0x00])
                log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
                peripheral.writeValue(Data(bondFrame), for: c, type: .withResponse)
            case BLEManager.whoop5CmdWriteChar:
                // EXPERIMENTAL WHOOP 5.0/MG: a 5/MG strap starts a session with the static CLIENT_HELLO
                // frame, not the WHOOP4 confirmed-write bond. We write it UNacknowledged (it is a
                // complete framed command), so the WHOOP4 didWriteValueFor bond+handshake path never
                // fires for a 5/MG strap. Live HR/battery come from the standard profiles; this just
                // opens the puffin session. Unverified on real MG hardware.
                cmdCharacteristic = c
                if let hello = selectedModel.deviceFamily.clientHello {
                    // CONTRIBUTOR FIX (issue #17 — diagnosed from the logs, unverified on hardware here):
                    // write CLIENT_HELLO with .withResponse so CoreBluetooth runs just-works bonding when
                    // the link needs authenticating, AND so didWriteValueFor fires. That callback is where
                    // we mark the link established and (re)subscribe the puffin notify chars — the strap
                    // rejects them with "Authentication is insufficient" until the connection is encrypted,
                    // and the old .withoutResponse write never triggered bonding, so it hung forever at
                    // "Finishing the secure pairing handshake…".
                    log("WHOOP 5/MG: writing CLIENT_HELLO to fd4b0002 with response (to trigger bonding, experimental).")
                    state.pairingHint = nil   // fresh attempt; clear any stale pairing-mode guidance
                    peripheral.writeValue(Data(hello), for: c, type: .withResponse)
                }
                // The realtime-HR stream is armed POST-bond (in didWriteValueFor / startRealtime) with
                // puffin framing — not here. Writing it pre-bond on an unauthenticated link did nothing.
            case BLEManager.cmdNotifyChar,
                 BLEManager.eventNotifyChar,
                 BLEManager.dataNotifyChar,
                 BLEManager.heartRateChar,
                 BLEManager.batteryChar:
                switch c.uuid {
                case BLEManager.cmdNotifyChar: cmdNotifyCharacteristic = c
                case BLEManager.eventNotifyChar: eventNotifyCharacteristic = c
                case BLEManager.dataNotifyChar: dataNotifyCharacteristic = c
                case BLEManager.heartRateChar: heartRateCharacteristic = c
                case BLEManager.batteryChar:
                    batteryCharacteristic = c
                    if c.properties.contains(.read) {
                        peripheral.readValue(for: c)
                    }
                default: break
                }
                requestNotify(c, on: peripheral, reason: "discovery")
            case BLEManager.disSerialChar, BLEManager.disHwRevChar:
                // #520: CAPTURE ONLY — the read is issued post-bond (a 5/MG refuses standard reads on an
                // unencrypted link, see #490). These are read-only identity strings: never subscribed
                // (no notify property) and never written. Must be handled BEFORE `default`, or they'd be
                // retained as puffin notify characteristics.
                if c.uuid == BLEManager.disSerialChar {
                    disSerialCharacteristic = c
                } else {
                    disHwRevCharacteristic = c
                }
            default:
                // WHOOP 5.0/MG puffin notify characteristics (fd4b0003/0004/0005/0007). Retain them but DO
                // NOT subscribe yet — on an unauthenticated link the strap rejects them with "Authentication
                // is insufficient", which (per a 5/MG owner's verified flow, issue #17) also wedges the bond.
                // didWriteValueFor subscribes them once the CLIENT_HELLO .withResponse write confirms.
                if BLEManager.whoop5NotifyChars.contains(c.uuid) {
                    whoop5NotifyCharacteristics.append(c)
                }
            }
        }
    }

    /// Confirmed-write completion = bonding succeeded (no error).
    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Confirmed write failed: \(error.localizedDescription)")
            // #78 hole-1: classify by ATT code first (locale-proof), English string fallback second.
            // This one change repairs the pairing hint (streak>=2), the #747 give-up (5) AND the #52
            // stale-pin handoff below for non-English devices, which all key off this same flag.
            let insufficient = BLEManager.isInsufficientAuthError(error)
            // Connection test mode: surface the failed-encrypt / "held by another central" hint as an
            // upfront tagged line (the strap is still bonded to the official WHOOP app or a stale OS
            // pairing, so the just-works bond is refused). Gated zero-cost; diagnostic only.
            if TestCentre.active(.connection) {
                state.append(log: insufficient
                    ? "otherCentral bondWrite refused=insufficient (strap likely held by the WHOOP app or a stale pairing; cannot start a fresh encrypted bond)"
                    : "otherCentral bondWrite failed=\(connErrorToken(error))", domain: .connection)
            }
            // WHOOP 5/MG first connect: CoreBluetooth won't start a fresh just-works bond against a strap
            // still bonded to the official WHOOP app, so the CLIENT_HELLO .withResponse write fails with
            // "Encryption/Authentication is insufficient" and the link never authenticates. Surface
            // actionable pairing-mode guidance instead of failing silently (issue #17).
            if selectedModel.deviceFamily == .whoop5, !didBond, insufficient {
                bondRefusalStreak += 1
                // #78: surface the pairing-mode guidance once refusals are PERSISTENT — the strap is
                // genuinely refusing the encrypted bond (held by the official WHOOP app, or iOS holds a
                // stale/half pairing it can't re-encrypt, e.g. after a "Restored CONNECTED peripheral").
                // A SINGLE refusal right after a known-good bond (#74) is a transient reconnect race, so we
                // stay quiet on streak 1; from streak 2 we tell the user how to make the strap pairable.
                // (Earlier 5.2.3 logic keyed this off lastBondedPeripheralUUID and wrongly hid the guidance
                // for users whose strap had bonded in a PRIOR session but won't now — exactly #78.)
                if bondGiveUp.gaveUp {
                    // #78 hole-4: a refusal during a paused-state salvage probe must not stomp the paused
                    // hint back to the pairing hint (or flap the banner per probe). The streak keeps
                    // counting silently; recordRefusal() below stays false (latched), so no epitaph spam.
                    log("WHOOP 5/MG: bond still refused during a paused-state probe (streak \(bondRefusalStreak)) - the give-up stays latched")
                } else if bondRefusalStreak >= 2 {
                    state.pairingHint = "NOOP can see your strap but it's refusing to pair - it's likely still bonded to the official WHOOP app, or your phone is holding an old pairing. To fix it: (1) fully close the WHOOP app, (2) on a 5.0/MG, tap the band repeatedly until the LEDs flash blue (pairing mode), (3) if your strap is listed under iPhone Settings → Bluetooth, tap it and choose Forget This Device, then reconnect in NOOP."
                    log("WHOOP 5/MG: bond refused \(bondRefusalStreak)× with no successful bond — the strap is refusing the encrypted link (WHOOP app holds it, or a stale iOS pairing). Surfacing pairing-mode + forget-device guidance (#78).")
                } else {
                    log("WHOOP 5/MG: bond write refused (insufficient) — retrying once; will surface pairing-mode guidance if it persists (#78).")
                }
                // #747 / #750: feed the same refusal into the give-up tracker. Once it crosses the higher
                // threshold (the pairing hint has had several cycles to be acted on), pause auto-reconnect so
                // we stop hammering a strap that can't bond, write the one-line epitaph (opaque id only, no
                // PII), and surface the honest paused hint. A genuine bond or a manual reconnect re-arms it.
                if bondGiveUp.recordRefusal() {
                    autoReconnectPausedForBondLoop = true
                    bondLoopPausedAt = Date()   // starts the #78 hole-4 salvage-probe floor
                    let opaque = BondRefusalGiveUp.opaqueId(fromLocalUUID: peripheral.identifier.uuidString)
                    log(BondRefusalGiveUp.epitaphLine(refusals: bondGiveUp.refusals, opaqueId: opaque))
                    state.pairingHint = BondRefusalGiveUp.pausedHint()
                    if TestCentre.active(.connection) {
                        state.append(log: "bond gaveUp refusals=\(bondGiveUp.refusals) id=\(opaque) (auto-reconnect paused)", domain: .connection)
                    }
                }
            }
            // Multi-WHOOP stale-pin recovery (#52). When a stale registry pin points at a strap that keeps
            // refusing the encrypted bond ("Encryption/Authentication is insufficient") but a DIFFERENT
            // strap has bonded fine this run, connect() otherwise drops the working strap and loops forever
            // on the dead pin — encryptedBond never turns true (which also kills buzz/haptics that gate on
            // it). Count consecutive refusals on the PINNED peripheral; after `pinBondRefusalLimit`, hand
            // the pin off to the live-bonding strap so the registry re-adopts it (handoff republishes the
            // working uuid on the connectedPeripheralUUID seam SourceCoordinator already observes).
            if insufficient, !didBond,
               let pinned = preferredPeripheralUUID, peripheral.identifier == pinned {
                pinnedBondRefusals += 1
                if pinnedBondRefusals >= pinBondRefusalLimit,
                   let working = lastBondedPeripheralUUID, working != pinned {
                    readoptWorkingStrap(working, awayFrom: pinned)
                }
            }
            return
        }

        // EXPERIMENTAL WHOOP 5.0/MG (issue #17): the CLIENT_HELLO is now a .withResponse write, so this
        // fires once the strap acks it — after just-works bonding if the link needed authenticating.
        // Treat that as the link being established: mark bonded (which clears the "Finishing the secure
        // pairing handshake…" status) and re-subscribe the puffin notify chars + standard HR/battery,
        // which the strap refused before the link was encrypted. Do NOT run the WHOOP4 command handshake
        // below — a 5/MG strap rejects WHOOP4-framed commands (the send() guard drops them anyway).
        if selectedModel.deviceFamily == .whoop5 {
            if !didBond {
                didBond = true
                state.bonded = true
                state.encryptedBond = true   // genuine encrypted bond (not the live-HR shortcut) — #69
                bondedAt = Date()            // #617: start the bond→drop stopwatch for the bond-loop detector
                state.pairingHint = nil
                bondRefusalStreak = 0         // #78: a genuine bond resets the refusal streak
                bondGiveUp.reset()            // #747/#750: a genuine bond clears the give-up + re-arms auto-reconnect
                autoReconnectPausedForBondLoop = false
                bondLoopPausedAt = nil
                noteGenuineBond(of: peripheral)   // #52: this strap bonds fine; clears any pin-refusal streak
                emitConnectionBondState("encryptedBond family=whoop5 (CLIENT_HELLO acked)")
                log("WHOOP 5/MG: CLIENT_HELLO acked — link established; subscribing notify chars (experimental).")
            }
            for c in whoop5NotifyCharacteristics where !c.isNotifying || restoreNeedsResubscribe {
                requestNotify(c, on: peripheral, reason: "post-bond puffin")   // #613: force re-arm on restore
            }
            enableLiveNotifications(reason: "post-bond 5/MG")   // standard HR/battery that failed pre-bond
            // Arm realtime HR with puffin framing — the verified step that makes a bonded 5/MG strap start
            // streaming (issue #17). Once per connection; keep-alive skips 5/MG, so this is the trigger.
            // (Opening Live later also arms it via startRealtime(), now that send() routes the 5/MG toggle.)
            // #927: RE-DERIVE the want at arm time, never the precomputed `wantsRealtime`: that value can
            // be up to a keep-alive tick (30 s) stale, and a reconnect just OUTSIDE the overnight window
            // would re-arm the flood from it and stay armed until the next tick.
            let realtimeWantNow = screenWantsRealtime || continuousCaptureWantsNow()
            wantsRealtime = realtimeWantNow
            if realtimeWantNow && !whoop5RealtimeArmed {
                whoop5RealtimeArmed = true
                realtimeArmed = true   // keep reconcileRealtime()'s edge tracking in sync with the arm
                log("WHOOP 5/MG: arming realtime HR (puffin TOGGLE_REALTIME_HR)")
                send(.toggleRealtimeHR, payload: [0x01])
            }
            startKeepAlive()                                    // re-subscribe + liveness watchdog
            // Kick the historical offload ONCE per connection — this is the 5/MG edition of the WHOOP4
            // connect-handshake (lines below). didWriteValueFor re-enters this `.whoop5` branch on EVERY
            // .withResponse ack during the offload (each HISTORY_END ack), so the trigger work MUST fire
            // once or it would re-issue SEND_HISTORICAL_DATA mid-stream and storm the strap. The notify
            // re-subscribe + realtime-arm above are idempotent and intentionally run on every re-entry;
            // only this block is gated. `whoop5SessionStarted` resets on disconnect.
            if !whoop5SessionStarted {
                whoop5SessionStarted = true
                connectHandshakeDone = true     // unblocks beginBackfill()'s guard
                log("WHOOP 5/MG: connect handshake done — backfill unblocked")
                noteRebootReconnectIfNeeded()
                // Re-apply the Broadcast-HR device-config flag if the user opted in (#181).
                if PuffinExperiment.broadcastHrEnabled { setBroadcastHr(true) }
                // Clock the strap BEFORE history: an un-clocked WHOOP 5 discards sensor data ("RTC
                // timestamp … is invalid; not saving data to flash") and history offloads "succeed"
                // with metadata only. Same 8-byte payload as the WHOOP4 handshake, puffin-framed;
                // GET_CLOCK's reply rides the puffin notify chars and never touches the WHOOP4
                // clockRef correlation path. The 1.5s deferral below keeps clock-before-history.
                // Hardware-validated ordering (#78 fork).
                send(.setClock, payload: BLEManager.setClockPayload())
                send(.getClock, payload: [])
                log("WHOOP 5/MG: clock synced (set/get) — strap can persist history now")
                log("WHOOP 5/MG: scheduling first historical offload (connect)")
                // Deferred ~1.5s so the puffin notify subscriptions settle before SEND_HISTORICAL_DATA,
                // mirroring the WHOOP4 kick. requestSync → beginBackfill is itself gated on
                // connectHandshakeDone, so a racing foreground/restore trigger can't fire it early.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
                startBackfillTimer()            // re-offload the type-47 store every backfillIntervalSeconds
                // #34: signal settled directly (skip the cmd-notify gate `maybeSignalConnectSettled()`
                // uses) — armStrapAlarm's 5/MG branch never sends GET_ALARM_TIME (log-only readback is
                // WHOOP4-only, and the 5/MG alarm itself stays behind the Experimental toggle), so there's
                // no reply-channel race to wait out here; this just keeps the re-arm-on-bond signal firing
                // for 5/MG the way it did before `connectSettled` replaced raw `bonded`.
                if !connectSettledSignaled {
                    connectSettledSignaled = true
                    state.connectSettled &+= 1
                    restoreNeedsResubscribe = false   // #613: forced re-subscribe pass is done (5/MG path)
                }
            }
            return
        }

        if !didBond {
            didBond = true
            state.bonded = true
            state.encryptedBond = true   // WHOOP 4 confirmed-write bond is always genuine — #69
            bondedAt = Date()            // #617: start the bond→drop stopwatch for the bond-loop detector
            noteGenuineBond(of: peripheral)   // #52: this strap bonds fine; clears any pin-refusal streak
            emitConnectionBondState("encryptedBond family=whoop4 (confirmed write acked)")
            log("BONDED (confirmed write acknowledged) — custom channels should now flow")
        }
        // Run the connect handshake EXACTLY ONCE per connection. didWriteValueFor re-fires on EVERY
        // .withResponse write — the bond write, every SEND_HISTORICAL, every HISTORY_END ack. Without
        // this guard those re-entries re-sent hello/SET_CLOCK at the strap *during* the offload and
        // stopped it from streaming type-47. This was THE iOS-side root cause: the Mac prototype pulls
        // type-47 fine because it runs the sequence once on a stable connection; the app stormed it.
        guard !connectHandshakeDone else { return }
        connectHandshakeDone = true
        noteRebootReconnectIfNeeded()
        backfillStarted = true

        // WHOOP-faithful connect lifecycle: hello → set RTC,
        // then offload. Hello is NOT strictly required to serve — verified on this strap via the Mac
        // ground-truth test: plain SEND_HISTORICAL_DATA serves type-47 with no hello and no high-freq-sync
        // (PHASE A = 50 records; PHASE B high-freq = 0). We still exchange hello to mirror WHOOP exactly.
        send(.getHelloHarvard)
        send(.getAdvertisingNameHarvard)
        // One-shot firmware-version read for the Devices card. These are read-only commands (not
        // firmware-load opcodes); send the one this family answers and let the other be ignored. The
        // reply decodes to fw_harvard (4.0) / fw_version (5/MG) and FrameRouter posts it to LiveState.
        switch selectedModel.deviceFamily {
        case .whoop4: send(.reportVersionInfo)
        case .whoop5: send(.getHello)
        }
        sendSetClockBothForms()
        if clockRef == nil && !clockRequested {
            clockRequested = true
            // GET_CLOCK's payload length is firmware-specific, exactly like SET_CLOCK's: newer
            // firmware answers the EMPTY form and ignores [0x00], while fw 41.17.x answers [0x00] and
            // ignores the empty form (#120). Send both — the strap answers whichever its firmware
            // accepts, and the `clockRef == nil` correlation guard makes a second reply a no-op.
            // Without the [0x00] form, correlation never establishes on 41.17.x, so a lost RTC (the
            // 1971 clock behind #120) stays invisible and ClockPolicy can never re-fix it. Both
            // GET_CLOCKs ride behind both SET_CLOCKs above, so the reply reflects the corrected clock.
            // (Offload doesn't depend on this — Backfiller falls back to an identity clockRef — but a
            // real correlation drives realtime decode and the drift re-set.)
            send(.getClock, payload: [])
            send(.getClock, payload: [0x00])
        }
        send(.sendR10R11Realtime, payload: [0x00])   // stop the type-43 realtime flood (BLE airtime/battery)
        send(.getDataRange)                          // refresh the strap's stored range for the watchdog
        // Plain offload (no high-freq-sync), rate-limited (first connect always runs; reconnect-flaps are
        // throttled by BackfillPolicy). Deferred ~1.5s so SET_CLOCK/GET_DATA_RANGE round-trip first and
        // SEND_HISTORICAL runs on a settled link, like the paced Mac prototype. beginBackfill is itself
        // gated on connectHandshakeDone so a racing foreground/restore trigger can't fire it early.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
        startBackfillTimer()   // re-offload the type-47 store every backfillIntervalSeconds
        startKeepAlive()       // always-ping: re-arm realtime, poll battery, watchdog the link
        enableLiveNotifications(reason: "post-bond")   // includes 0x2A37 standard HR — the fallback path
        // #927: RE-DERIVE the want at arm time (same reasoning as the 5/MG branch above): a reconnect
        // outside the overnight window must not arm the flood from a stale precomputed `wantsRealtime`
        // (up to a keep-alive tick stale); the keep-alive would then hold it armed for another 30 s.
        let realtimeWantNow = screenWantsRealtime || continuousCaptureWantsNow()
        wantsRealtime = realtimeWantNow
        if realtimeWantNow {
            if standardHRFallback {
                // #80: this radio repeatedly dropped the link the instant we armed the R10/R11 burst.
                // Skip the heavy stream entirely; live HR rides the already-subscribed low-bandwidth
                // 0x2A37 standard profile (subscribed by enableLiveNotifications above). SAFE either way:
                // if 0x2A37 emits the user gets live HR on a radio that otherwise died; if it doesn't, at
                // least the arm→die loop stops.
                log("Realtime HR: standard-HR mode (low bandwidth) — skipping R10/R11 arm (#80)")
                state.standardHRMode = "Standard HR mode (low bandwidth) - your Bluetooth radio couldn't sustain the full stream; live heart rate via the standard profile."
            } else {
                log("Realtime HR: arming after bond")
                realtimeArmed = true   // keep reconcileRealtime()'s edge tracking in sync with the arm
                send(.sendR10R11Realtime, payload: [0x01])
                send(.toggleRealtimeHR, payload: [0x01])
                realtimeArmedAt = Date()   // start the arm→drop stopwatch for the marginal-radio detector
            }
        }
        // #34: the handshake body above (hello, SET_CLOCK, notify-resubscribe requests) has now been
        // fully ISSUED — check whether the cmd-notify characteristic has also CONFIRMED (the other half
        // may already have landed, e.g. from the discovery-phase subscribe, or may still be in flight and
        // land via didUpdateNotificationStateFor below).
        maybeSignalConnectSettled()
    }

    /// #34: bump `state.connectSettled` once, per connection, the first moment BOTH `connectHandshakeDone`
    /// (hello + SET_CLOCK sent) AND `cmdNotifyConfirmedActive` (cmd-notify characteristic confirmed
    /// subscribed) are true — whichever lands second. Called from the tail of the WHOOP4 handshake and
    /// from `didUpdateNotificationStateFor` on a cmd-notify confirmation; a no-op until both are true, and
    /// latched by `connectSettledSignaled` so it can't double-bump on a second call. This is the signal
    /// the alarm re-arm (AppModel's `live.$connectSettled` sink) waits on instead of raw `bonded`, so
    /// SET_ALARM_TIME/GET_ALARM_TIME go out on a link whose reply channel is confirmed live (#34).
    private func maybeSignalConnectSettled() {
        guard connectHandshakeDone, cmdNotifyConfirmedActive, !connectSettledSignaled else { return }
        connectSettledSignaled = true
        state.connectSettled &+= 1
        restoreNeedsResubscribe = false   // #613: forced re-subscribe pass is done — keep-alive resumes normal
        log("Connect settled: handshake done + cmd-notify confirmed — alarm re-arm (if due) can fire now")
    }

    /// SET_CLOCK(10) payload — the 8-byte form `[seconds u32 LE][subseconds u32 LE]`, subseconds in
    /// 1/32768 s (0 is fine). The payload LENGTH is firmware-specific and LOAD-BEARING: newer WHOOP 4
    /// firmware latches this form, but fw 41.17.x ignores it outright — no COMMAND_RESPONSE, RTC
    /// unchanged — and latches only the legacy 9-byte form below. A strap that misses the set keeps an
    /// invalid RTC and stops banking sensor data to flash entirely, which surfaces as endless
    /// console-only syncs and no sleep/recovery (#120). Send WHOOP 4 through sendSetClockBothForms()
    /// so either firmware latches.
    static func setClockPayload(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0]
    }

    /// SET_CLOCK(10) payload — the legacy 9-byte form `[seconds u32 LE][5 zero]` required by WHOOP 4
    /// fw 41.17.x, which ignores the 8-byte form. On a strap whose RTC was stuck in the past, days of
    /// 8-byte sends drew no response; the 9-byte form was ack'd (COMMAND_RESPONSE cmd 10), the clock
    /// latched and ticked, and the strap resumed banking history to flash (#120). On newer firmware
    /// this form is ack'd but NOT latched, so sending it after the 8-byte form is a no-op there — both
    /// forms carry the same seconds, so whichever one latches sets the same time.
    static func setClockPayloadLegacy(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0, 0]
    }

    /// Send SET_CLOCK in every payload form the WHOOP 4 firmware family is known to accept (8-byte for
    /// newer firmware, 9-byte for 41.17.x — each a no-op on the other). Both carry the same `now`, so
    /// double-latching is harmless. WHOOP 5/MG keeps its single hardware-validated 8-byte send (its
    /// connect path calls setClockPayload() directly; the 9-byte form is unverified on that family), so
    /// the legacy form is gated to WHOOP 4. (#120)
    func sendSetClockBothForms() {
        let now = UInt32(Date().timeIntervalSince1970)
        send(.setClock, payload: BLEManager.setClockPayload(now: now))
        if selectedModel.deviceFamily == .whoop4 {
            send(.setClock, payload: BLEManager.setClockPayloadLegacy(now: now))
        }
    }

    /// Newest plausible-unix marker in a GET_DATA_RANGE COMMAND_RESPONSE = the strap's newest stored
    /// record. Mirrors re/diagnose_biometrics.py: scan u32 LE words in the response body (data starts at
    /// frame[7], after [type,seq,cmd]), keep those in the unix range, return the max. nil if none.
    static func dataRangeNewestUnix(from frame: [UInt8],
                                    wallNowUnix: Int = Int(Date().timeIntervalSince1970)) -> Int? {
        // #286 follow-up: delegate to the pure, twin-tested WhoopProtocol.DataRange (byte-identical to the
        // Kotlin com.noop.protocol.DataRange) so this parity-critical read — it gates auto-sync via
        // isFutureDatedNewest → BackfillPolicy — is CI-pinned on BOTH platforms, not the Kotlin side only.
        DataRange.newestUnix(from: frame, wallNowUnix: wallNowUnix,
                             futureSkewSeconds: BackfillContinuation.defaultFutureSkewSeconds)
    }

    /// The OLDEST plausible record timestamp in a GET_DATA_RANGE frame — the start of the strap's stored
    /// history. Same scan as `dataRangeNewestUnix` but keeps the minimum, so one connect can report the
    /// full banked SPAN (oldest…newest). For the recurring "last night didn't sync" reports (#364) that
    /// span is the backlog DEPTH at a glance: a strap that banked weeks of un-synced history has a wide
    /// span and simply needs time to drain oldest-first, vs. a narrow span that should clear quickly.
    // #286 follow-up: delegate to the pure, twin-tested WhoopProtocol.DataRange (byte-identical Swift/Kotlin).
    static func dataRangeOldestUnix(from frame: [UInt8]) -> Int? {
        DataRange.oldestUnix(from: frame)
    }

    /// #695: process a GET_DATA_RANGE COMMAND_RESPONSE — the #451 raw dump, the #689 pagesBehind backlog, and
    /// the strap's newest/oldest banked window. Shared by the WHOOP4 case (cmdOff 6, `feedsSync: true`) and the
    /// 5/MG case (cmdOff 10, `feedsSync: false`); previously only WHOOP4 ran it (the handler keyed on frame[6]).
    /// `dataRangeNewestUnix`/`dataRangeOldestUnix` SCAN the frame (offset-agnostic), so they work on either
    /// family; only pagesBehind uses cmdOff.
    ///
    /// `feedsSync` gates the SYNC-affecting side-effects (strapNewestTs liveness watchdog, #547 backfill
    /// session window, LiveState range) — WHOOP4 only for now. The 5/MG path passes `false`: it LOGS the
    /// dump/backlog/newest/oldest/clock-drift (so a strap log can VALIDATE the decode) but leaves sync
    /// UNCHANGED, so 5/MG behaviour is byte-identical to before + the new diagnostic lines. Flip the 5/MG call
    /// to `feedsSync: true` once a real 5.0/MG strap confirms the newest/oldest decode is correct.
    private func handleDataRangeResponse(_ frame: [UInt8], cmdOff: Int, feedsSync: Bool) {
        // #451: the decoded "newest" can latch a stale/wrong-epoch field (claypilat saw 2024 when the real
        // newest was 2026). To tell a genuinely-stale strap apart from a frame-alignment bug in
        // dataRangeNewestUnix WITHOUT guessing, dump the raw GET_DATA_RANGE response bytes (logged
        // unconditionally, even if decode returns nil) so the field offsets are inspectable from a strap log.
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        log("Get Data Range raw frame (#451 — for offset analysis): \(hex)")
        // #689: ring-buffer page backlog, DIAGNOSTIC ONLY — never gates sync/backfill.
        // BOTH branches log, deliberately. Until #818 the offsets were two bytes early, so ring capacity
        // always read 0, the `t > 0` guard rejected every real frame, and this logged NOTHING — a strap
        // log was indistinguishable from one where the strap never answered, which is why a broken decode
        // survived unnoticed. The raw-frame dump above is unconditional for the same reason. If a firmware
        // revision ever shifts these fields again, the rejection must be visible rather than silent.
        if let pages = DataRange.pagesBehind(from: frame, cmdOff: cmdOff) {
            log("Strap backlog pages behind: \(pages) (#689 — GET_DATA_RANGE ring backlog, diagnostic only)")
        } else {
            log("Strap backlog pages behind: not decodable from this frame (#689 — offsets may have moved; "
                + "the raw frame above is the input). Diagnostic only, sync is unaffected.")
        }
        if let newest = BLEManager.dataRangeNewestUnix(from: frame) {
            // #695: the sync-affecting side-effects (strapNewestTs, backfill window, LiveState range) only
            // apply when feedsSync — WHOOP4 today. The 5/MG path passes feedsSync=false: it LOGS the newest/
            // oldest/backlog (so a strap log validates the decode) but leaves sync UNCHANGED until confirmed
            // on hardware, so 5/MG behaviour is byte-identical to before + the new diagnostic lines.
            if feedsSync { strapNewestTs = newest }   // feeds the liveness watchdog
            // #928: flag an implausibly FUTURE "newest" (strap clock set ahead) right where it lands, so a
            // Test Centre export shows WHY auto-continue refused to trust the range.
            let wallNowForSkew = Int(Date().timeIntervalSince1970)
            if newest > wallNowForSkew + BackfillContinuation.defaultFutureSkewSeconds {
                log("Strap newest banked record reads \((newest - wallNowForSkew) / 3600)h AHEAD of the wall clock (implausible; strap clock set in the future, #928). Auto-continue will not trust this range.")
            }
            // #547 SESSION-RELATIVE gate: publish the strap's banked-record window to the Backfiller so the
            // historical ingest gate can reject a record dated months outside THIS strap's own [oldest,
            // newest]. The gate ignores a half/malformed window, so setting newest before oldest is safe.
            if feedsSync { backfiller?.sessionNewestUnix = newest }
            // Observability for "last night didn't sync" (#364): print the NEWEST record the strap holds.
            let d = ISO8601DateFormatter()
            d.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
            log("Strap newest banked record: \(d.string(from: Date(timeIntervalSince1970: TimeInterval(newest)))) (from data range)")
            // Also surface the OLDEST banked record so one connect shows the full backlog SPAN (#364).
            let oldest = BLEManager.dataRangeOldestUnix(from: frame)
            if let oldest, oldest < newest {
                if feedsSync { backfiller?.sessionOldestUnix = oldest }   // #547: closes the session-relative window
                let spanDays = (newest - oldest) / 86_400
                log("Strap banked history span: \(d.string(from: Date(timeIntervalSince1970: TimeInterval(oldest)))) → newest (~\(spanDays) day\(spanDays == 1 ? "" : "s") of backlog, drained oldest-first)")
            }
            // UNIVERSAL clock-drift snapshot (RTC cluster #531/#767/#804/#812): bank the [oldest, newest]
            // window onto LiveState UNCONDITIONALLY (observability, not gated) for the export assembler.
            if feedsSync { state.setStrapRange(newestUnix: newest, oldestUnix: (oldest.map { $0 < newest } ?? false) ? oldest : nil) }
            // Connection test mode: promote the CLOCK-DRIFT picture to one upfront tagged line (#767/#754).
            if TestCentre.active(.connection) {
                let line = ConnectionTrace.clockDriftLine(
                    oldestUnix: (oldest.map { $0 < newest } ?? false) ? oldest : nil,
                    newestUnix: newest,
                    wallNowUnix: Int(Date().timeIntervalSince1970))
                state.append(log: line, domain: .connection)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error {
            log("Notify update failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        lastDataAt = Date()   // feed the liveness watchdog on every notification

        switch characteristic.uuid {
        case BLEManager.heartRateChar:
            parseStandardHR(bytes)
            // EXPERIMENTAL WHOOP 5.0/MG: there is no confirmed-write bond for a 5/MG strap, so once
            // live HR actually streams over the standard profile we treat the link as established —
            // otherwise the UI sits on "Connecting…" forever even though data is flowing (issue #8).
            if selectedModel.deviceFamily == .whoop5, !state.bonded {
                state.bonded = true
                log("WHOOP 5/MG: live HR streaming — marking the link established (experimental).")
            }
        case BLEManager.batteryChar:
            // 0x2A19 = percent — 5/MG ONLY. The WHOOP 4.0's 0x2A19 is a stub constant 100 (real value =
            // GET_BATTERY_LEVEL response, u16/10) and it's subscribed, so an unsolicited stub
            // notification was reverting the true reading back to 100% (#77).
            if selectedModel.deviceFamily != .whoop4, let pct = bytes.first {
                state.setBattery(Double(pct))
            }
        case BLEManager.disSerialChar:
            // #520: NUL-terminated ASCII per the DIS spec; trim any padding before resolving.
            disSerial = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
            noteWhoop5VariantFromDIS()
        case BLEManager.disHwRevChar:
            disHwRev = String(decoding: bytes, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
            noteWhoop5VariantFromDIS()
        case BLEManager.dataNotifyChar,
             BLEManager.cmdNotifyChar,
             BLEManager.eventNotifyChar:
            // Reassemble (no-op for already-complete frames) then route each complete frame.
            for frame in reassembler.feed(bytes) {
                if backfilling, BLEManager.isOffloadFrame(frame, family: .whoop4) {
                    // Historical replay is bulk sync traffic, not live UI traffic. Feed it only to
                    // the Backfiller; parsing every record through FrameRouter updates SwiftUI for
                    // no user-visible benefit and can make the app feel hung during long offloads.
                    armBackfillTimeout()
                    routeBackfillFrame(frame)
                    // …but a REAL-TIME physical gesture (double-tap / wrist) must still fire even mid-
                    // offload (#69). Gated on ts≈now so replayed historical EVENTs (old ts) are ignored.
                    router.dispatchLiveGestureIfFresh(frame: frame, now: strapClockNow)
                    continue
                }
                // #47: decode this live WHOOP4 frame ONCE here and thread the result to every consumer
                // (router / clock-correlation / collector) instead of each re-parsing it — steady-state
                // drops 2→1 parse per frame, pre-clock 3→1. This is the WHOOP4 custom-notify case (5/MG has
                // its own case), so parse with `.whoop4` explicitly — the same family this loop already uses
                // for isOffloadFrame, and byte-identical to all three original parses (router.family /
                // collector.family / the no-family clock parse all resolve to .whoop4 here; a DEBUG assert in
                // the router + collector re-checks the invariant).
                let parsed = parseFrame(frame, family: .whoop4)
                router.handle(parsed: parsed, frame: frame)       // live/UI path
                // #592: the read-only extended-battery probe's COMMAND_RESPONSE — format + publish it for the
                // Devices dialog (raw hex + payload triage + capture diff). Sibling of the #451 dump below.
                if frame.count > 6, frame[6] == WhoopCommand.getExtendedBatteryInfo.rawValue {
                    handleExtendedBatteryProbeResponse(frame, isWhoop5: false)
                }
                // #690: the read-only body-location probe's COMMAND_RESPONSE (in-flight-guarded inside).
                if frame.count > 6, frame[6] == WhoopCommand.getBodyLocationAndStatus.rawValue {
                    handleBodyLocationProbeResponse(frame, isWhoop5: false)
                }
                // #761: a reply to the read-only feature-flag enumeration (117/118) — in-flight-guarded
                // inside, so this is a byte compare on every other frame.
                if frame.count > 6, frame[6] == WhoopCommand.startFeatureFlagKeyExchange.rawValue
                    || frame[6] == WhoopCommand.sendNextFeatureFlag.rawValue {
                    handleFeatureFlagProbeResponse(frame, isWhoop5: false)
                }
                // #103: a reply to the read-only device-config READ probe (121/128) — in-flight-guarded
                // inside, so this is a byte compare on every other frame. The COMMAND_RESPONSE type gate
                // (@4 on 4.0) is checked HERE as well as in the parser: a data frame that happens to
                // carry 121/128 at the cmd offset would otherwise abort a live walk with an envelope
                // failure instead of being ignored.
                if frame.count > 6, frame[4] == 0x24, DeviceConfigReadProbe.isReadOnlyOpcode(frame[6]) {
                    handleDeviceConfigProbeResponse(frame, isWhoop5: false)
                }
                // #695: WHOOP4 data-range reply — cmd byte @6. The 5/MG reply (puffin envelope, cmd @10) is
                // handled in the 5/MG case below; both call handleDataRangeResponse so 5/MG now gets the same
                // newest/oldest window (strapNewestTs / #547 backfill gate) + diagnostics it previously missed.
                if frame.count > 6, frame[6] == WhoopCommand.getDataRange.rawValue {
                    handleDataRangeResponse(frame, cmdOff: 6, feedsSync: true)
                }
                // Clock correlation runs in both live and backfill modes. Once established it
                // unblocks both the Collector (live path) and the Backfiller (chunk decoding).
                if clockRef == nil {
                    // #47: reuse the single decode above (byte-identical for WHOOP4) instead of re-parsing.
                    if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                        clockRef = ref
                        collector?.clockRef = ref                  // unblocks buffered persistence
                        backfiller?.clockRef = ref                 // unblocks historical chunk decode
                        log("Clock correlated: device=\(ref.device) wall=\(ref.wall)\(clockRetries > 0 ? " (after retry \(clockRetries))" : "")")
                        // Conditional SET_CLOCK (mirrors WHOOP): only when the strap RTC has drifted /
                        // is frozen — not blindly every connect. Offload doesn't depend on this (it uses
                        // clockRef for decoding); SET_CLOCK only keeps FUTURE logging timestamps sane.
                        if ClockPolicy.shouldSetClock(deviceClock: ref.device, wallNow: ref.wall) {
                            log("Clock drift detected — issuing SET_CLOCK")
                            sendSetClockBothForms()
                        }
                    }
                }
                if !backfilling {
                    // Live path: synchronous ingest preserves delegate arrival order. #47: thread the
                    // single parse so the collector's flush doesn't re-decode the batch.
                    collector?.ingest(frame: frame, parsed: parsed)
                }
            }
        default:
            // EXPERIMENTAL WHOOP 5.0/MG puffin notify chars (fd4b0003/0004/0005/0007): reassemble with
            // the family-aware reassembler and route through the family-aware FrameRouter so the UI
            // reflects arriving frames. The historical offload uses the WHOOP4 backfill machinery
            // (family-aware), and live puffin frames are now persisted too — see below. (Clock: the
            // Collector runs an identity ref for 5/MG via configureCollectorFamily, since live puffin
            // timestamps are already real-unix seconds.) Live HR/battery still also come from the
            // standard 0x2A37 / 0x2A19 profiles handled above.
            if BLEManager.whoop5NotifyChars.contains(characteristic.uuid) {
                for frame in reassembler.feed(bytes) {
                    let isOffload = backfilling && BLEManager.isOffloadFrame(frame, family: .whoop5)
                    noteWhoop5R22Telemetry(frame, duringOffload: isOffload)   // #174 deep-data telemetry
                    // Durable EVENT-frame log for deep-data research (#103) — BEFORE the offload
                    // branch, so it sees both live events and their history replays (either path
                    // may be the only one that delivers a given record). Single byte compare when
                    // the frame is not an EVENT; no-op unless the capture toggle is on.
                    puffinEventLog.appendIfEvent(frame: frame, char: characteristic.uuid)
                    // Durable log of the big high-rate R22 deep buffers (type-0x2F ≥ 1 KB) for #423
                    // reverse-engineering — its own file the bulk-capture eviction never churns.
                    // BEFORE the offload branch so it catches the burst; no-op unless capture is on.
                    puffinDeepBufferLog.appendIfDeepBuffer(frame: frame, char: characteristic.uuid, isOffload: isOffload)
                    // #423: the queryable twin of that diagnostics line — persist the decoded 100 Hz 6-axis
                    // IMU samples into the rawImuSample table when raw capture is on (same gate, gated inside).
                    collector?.storeRawImu(frame: frame)
                    if isOffload {
                        // Same policy as WHOOP4: historical offload frames are bulk sync traffic.
                        // Keep them out of the live UI parser during backfill and let Backfiller
                        // preserve/order/process them in the sliced drain.
                        armBackfillTimeout()
                        routeBackfillFrame(frame)
                        // A real-time double-tap / wrist gesture still fires during a 5/MG offload (which
                        // runs for minutes, #69); the ts≈now gate rejects replayed historical EVENTs.
                        router.dispatchLiveGestureIfFresh(frame: frame, now: strapClockNow)
                        continue
                    }
                    router.handle(frame: frame)
                    // #592: a 5/MG extended-battery probe COMMAND_RESPONSE (puffin envelope: type @8, cmd
                    // @10). Format + publish it for the Devices dialog, exactly like the 4.0 path above.
                    if frame.count > 10, frame[8] == 0x24, frame[10] == WhoopCommand.getExtendedBatteryInfo.rawValue {
                        handleExtendedBatteryProbeResponse(frame, isWhoop5: true)
                    }
                    // #690: a 5/MG body-location probe COMMAND_RESPONSE (puffin envelope: type @8, cmd @10).
                    if frame.count > 10, frame[8] == 0x24, frame[10] == WhoopCommand.getBodyLocationAndStatus.rawValue {
                        handleBodyLocationProbeResponse(frame, isWhoop5: true)
                    }
                    // #761: a 5/MG reply to the read-only feature-flag enumeration (117/118), same puffin
                    // envelope offsets. In-flight-guarded inside.
                    if frame.count > 10, frame[8] == 0x24,
                       frame[10] == WhoopCommand.startFeatureFlagKeyExchange.rawValue
                        || frame[10] == WhoopCommand.sendNextFeatureFlag.rawValue {
                        handleFeatureFlagProbeResponse(frame, isWhoop5: true)
                    }
                    // #103: a 5/MG reply to the read-only device-config READ probe (121/128), same puffin
                    // envelope offsets. In-flight-guarded inside.
                    if frame.count > 10, frame[8] == 0x24,
                       DeviceConfigReadProbe.isReadOnlyOpcode(frame[10]) {
                        handleDeviceConfigProbeResponse(frame, isWhoop5: true)
                    }
                    // #174: a reply belonging to an R22 DISABLE run — either the SET_FF_VALUE(120) write ack
                    // or the GET_FF_VALUE(128) read-back that verifies it. In-flight-guarded inside, so this
                    // is a byte compare on every other frame. Note 128 is also matched by the read-probe
                    // clause above; both handlers guard on their OWN run being live, so exactly one acts.
                    if frame.count > 10, frame[8] == 0x24,
                       frame[10] == WhoopCommand.setConfig.rawValue
                        || frame[10] == WhoopCommand.getFeatureFlagValue.rawValue {
                        handleR22DisableResponse(frame, isWhoop5: true)
                    }
                    // #695: a 5/MG GET_DATA_RANGE COMMAND_RESPONSE (puffin envelope: type @8, cmd @10). Feeds
                    // the SAME newest/oldest window + backfill gate + diagnostics as the 4.0 path above — this
                    // reply was previously ignored on 5/MG (the 4.0 handler keyed on frame[6]). cmdOff = 10.
                    // MG ECG (Labrador) probe: settle each command's outcome and hunt for the packet type
                    // the ECG records arrive under. `ecgProbeArmed` is false outside a user-initiated
                    // run, so this costs one Bool read on every other frame.
                    if ecgProbeArmed { noteEcgProbeFrame(frame) }
                    if frame.count > 10, frame[8] == 0x24, frame[10] == WhoopCommand.getDataRange.rawValue {
                        // feedsSync: false — #695 diagnostic-only on 5/MG: log the dump/backlog/newest/oldest so
                        // a strap log validates the decode, but DON'T feed strapNewestTs/backfill/state yet.
                        // Flip to true once a real 5.0/MG strap confirms the newest/oldest are correct.
                        handleDataRangeResponse(frame, cmdOff: 10, feedsSync: false)
                    }
                    // NOTE: we deliberately do NOT ingest live 5/MG REALTIME_DATA into the Collector
                    // here. For a 5/MG the standard 0x2A37 Heart-Rate profile is already the RELIABLE,
                    // continuously-persisted live source (see didUpdateValueFor 0x2A37 → ingestStandardHR);
                    // decoding HR a second time off the puffin stream stored a duplicate row per heartbeat
                    // at a slightly different second (strap-unix vs Mac-receive), inflating the sample
                    // store. 0x2A37 stays the single authoritative live HR/RR source for 5/MG.
                    // Capture for protocol mapping (no-op unless the Settings toggle is on). PR #20.
                    puffinRecorder.capture(frame: frame, char: characteristic.uuid)
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if let error = error {
            log("Notify enable failed for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            log("Notify \(characteristic.isNotifying ? "active" : "off") \(characteristic.uuid)")
            // #34: the cmd-notify channel carries GET_ALARM_TIME's (and every other COMMAND_RESPONSE's)
            // reply. Once IT confirms subscribed, check whether the handshake side of connectSettled is
            // also done — this is the "notify confirmed" half arriving AFTER the handshake body, the
            // ordering a v8.6.2 strap log showed actually happens.
            if characteristic === cmdNotifyCharacteristic, characteristic.isNotifying {
                cmdNotifyConfirmedActive = true
                maybeSignalConnectSettled()
            }
        }
    }
}
