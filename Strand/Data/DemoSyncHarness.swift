#if DEBUG
import Foundation

// MARK: - DEBUG-only sync-indicator harness
//
// A companion to DemoDayHarness for the Today header's charge→sync control. Neither `--demo-seed` nor
// `--demo-hour` can drive that control: it reads LiveState (strap connection, battery percentage,
// backfill progress), none of which the synthetic dataset supplies. Without a paired strap the control
// therefore renders the offline `bolt.slash` and the charge→sync morph never plays — so the morph, which
// is the whole point of the control, cannot be watched or captured in a simulator.
//
// `--demo-sync` closes that gap on two fronts: it supplies a synthetic battery reading, so the control
// takes the `.charge` path that owns ChargeSyncMorph rather than the plain offline crossfade, and it
// cycles the syncing signal so the capsule expands and collapses on a loop instead of needing a real
// offload to be timed by hand.
//
// Gating: the WHOLE file is `#if DEBUG`, so it is stripped from every Release build. At runtime nothing
// changes unless `--demo-sync` is present: `active` stays false and LiquidBatteryButton reads LiveState
// exactly as before, so the shipped control is untouched. Everything here is SYNTHETIC — this is not a
// real battery reading and no strap is contacted.

enum DemoSyncHarness {

    /// True only when `--demo-sync` was passed (→ otherwise zero behaviour change).
    static private(set) var active = false

    /// The synthetic strap battery the control shows while the harness drives it. Mid-range and not
    /// charging, so the ring draws a partial arc — a full circle or the charging bolt would hide the
    /// arc-to-spinner part of the morph.
    static let batteryPercent: Double = 72
    static let charging = false

    /// Idle stretch between sync bursts. MUST comfortably exceed
    /// `StrandMotion.syncIndicatorSignalDebounceNanoseconds` (3s): LiquidBatteryButton debounces the
    /// falling edge by that much, so a shorter idle cancels the pending collapse and the capsule never
    /// morphs back — it just sits expanded with the spinner looping. 3s of debounce + ~2s visibly
    /// collapsed.
    static let idleSeconds: Double = 5.0

    /// Chunks "pulled" per burst, and the gap between them, so the expanded read-out ticks 1 → 2 → 3
    /// the way a real offload does rather than showing one frozen number.
    static let chunkTicks = 3
    static let chunkIntervalSeconds: Double = 1.2

    /// Scan the launch args for `--demo-sync`. Call ONCE at launch, beside DemoDayHarness. Safe to call
    /// always: with the flag absent `active` stays false and nothing changes. Idempotent.
    static func applyLaunchArgsIfNeeded() {
        active = CommandLine.arguments.contains("--demo-sync")
    }
}
#endif
