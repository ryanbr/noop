# Sleep Module Overhaul — Diagnosis & Redesign

**Date:** 2026-06-20
**Trigger:** pikapik487 (#525, #547) asked for a full sleep-pipeline hygiene check rather than more targeted patches. Confirmed by a 4-dimension consistency audit (9 findings), a focused root-cause of the two headline symptoms, and domain research on how main-sleep selection should actually work.
**Status:** Diagnosis complete, design proposed, NOT yet built. Holding for approval of the approach.

---

## 1. Root causes (evidence-backed)

### A. THE foundational bug: main-night selection is a hard overnight GATE (confirmed)
`SleepStageTotals.mainNightIndex` / `mainNightIndexByStages` rank blocks **lexicographically**: an overnight-onset block (onset hour in [20:00, 10:00) local) always beats a daytime-onset block, with duration only a tiebreak. So a genuinely long sleep whose detected onset falls in the daytime gap [10:00, 20:00) can **never** beat a short overnight fragment — it gets tagged a nap. Because `analyzeDay` builds `totalSleepMin` / efficiency / stages / Rest / debt / contributors from the chosen block, one mis-pick poisons the whole downstream chain. This is pikapik's "longest session classified as a nap."

- Duplicated in **four** places (iOS analytics + iOS UI + Android analytics + Android UI), all wrong the same way, so they agree with each other but all mis-pick.
- **Window off-by-one:** the detector treats overnight as [20:00, 11:00) (`SleepStager.isOvernightOnset`) while the selector/UI use [20:00, 10:00). A ~10:30 onset is kept as "night" by the detector but demoted to "nap" by the selector. Cleanest trigger.
- **Why this is the anti-pattern:** the domain research is unanimous, no major wearable (Oura, WHOOP, Garmin, Fitbit) or actigraphy algorithm (GGIR/HDCZA, Actiware) uses a fixed clock onset window. It is a documented failure mode for late/irregular/shift/daytime sleepers.

### B. Android sleep edits never re-score (confirmed, medium)
Swift calls `analyzeRecent()` immediately after every sleep edit/delete/nap-add, recomputing recovery + the persisted Rest. Android only persists the row and waits up to 15 min for the background loop. So after editing sleep on Android, Charge and Rest stay stale and Today disagrees with the Sleep tab. (Audit findings #2/#3/#4 — one root cause.)

### C. Edited-day main-night pick uses the DETECTED onset, not the user-corrected one (confirmed, medium)
`IntelligenceEngine.sleepEditedDaily` threads the immutable detected `startTs` into the overnight test instead of the effective (edited) onset, so after a bedtime edit the Sleep tab hero and the daily aggregate can pick different blocks. (Audit #8.)

### D. Cross-platform window/parity mismatches (confirmed, medium/low)
- Debt ledger / Sleep Need / per-tile baselines use **different input windows** across platforms when browsing a past night (#5) — explains "debt vs ledger disagree" and "Need inflated."
- Android substitutes the displayed night's time-in-bed for total-sleep in per-tile series; iOS doesn't (#1/#7) — in-bed vs asleep mismatch.
- `SleepDebt.round1` rounds negative half-ties opposite ways Swift vs Kotlin (#6) — tiny but real.

### E. NOT our bug: "Rest repeats across days" in Intelligence > By Day
Exhaustive both-platform trace (adversarially verified): the By-Day Rest value is derived/persisted/merged/rendered strictly per-day, no shared/cached/reused value. The repeat almost certainly comes from an **imported source file** (the merge winner) or a sparse-strap detection artifact. Needs pikapik's data (a By-Day screenshot + their export + a `daily_metric` dump) to confirm; do **not** blind-fix.
- Real adjacent find: the By-Day card hard-codes a "NOOP-computed" badge even on imported rows, so a user can't tell a strap-scored night from an imported one. Fixable, separate.

### F. Test gap (confirmed)
The #525 reconciliation tests never exercised the divergent cases (daytime-onset longest block; bedtime-edited onset crossing the overnight boundary), which is exactly how A and C slipped through.

### G. Already fixed (in tree, unshipped): #543 (recovery No-Data at midnight → carry last night), #544 (Android HR chart axis timezone). #495 (iPhone 16 Pro layout) needs a screenshot to diagnose — not guessed.

---

## 2. Proposed redesign

### 2.1 Main-night selection (the core fix) — replace the gate with a duration-first score
Build ONE selector (in `SleepStageTotals`, both platforms) that the UI calls into (no re-deriving). The new rule, synthesized from GGIR/HDCZA + Oura/WHOOP/Garmin + All-of-Us:

1. **Bridge short wake gaps** (< 60 min) between adjacent sleep runs so a fragmented/biphasic main sleep is one block (the stager partly does this; verify + align to the research's <60 min).
2. **Score each block** = `asleepMinutes + alignmentBonus`, where `alignmentBonus` is a **fixed credit (~+90 min)** when the block's onset aligns with the user's sleep timing — NOT an infinite gate. Pick the highest score as the main sleep.
   - Alignment v1: onset in a broad overnight band. Alignment v2 (better, deferrable): onset near the user's **habitual midsleep**, a rolling median from history (the All-of-Us "typical sleep period" approach), so a shift/late sleeper's "overnight" is their real bedtime.
3. **Nap threshold:** a block is nap-classified if it isn't the chosen main AND is short; derive "nap" from "not the chosen main block," never an independent onset test (fixes the label contradicting the pick).
4. **Reconcile the windows:** align the selector's overnight band to the detector's, removing the [10:00, 11:00) off-by-one.

Why a score, not pure-longest: it lets a genuine 7h daytime-onset sleep (420) beat a 1.5h overnight fragment (90+90=180), while a normal 4h+ overnight (240+90=330) still beats a 5h... actually a 5h block (300) would beat it — which is correct if that 5h block is real sleep. The habitual-anchor (v2) is what correctly keeps the *usual* night winning on an odd day. v1 (broad band + bonus) already fixes pikapik; v2 makes it robust for shift workers.

**Apply identically in both selector variants** (`mainNightIndex` used by `analyzeDay`, `mainNightIndexByStages` used by the edit seam) and call it from the UI on both platforms, so analytics + Sleep tab always resolve to the SAME block (the whole point of #525).

### 2.2 Edited-onset fix (C)
Thread the **effective** onset (`startTsAdjusted ?? startTs`) into the selector for edited nights, both the seam and the UI.

### 2.3 Android edit → immediate re-score (B)
After `updateSleepSessionTimes` / `deleteSleepSession` / `addManualNap`, call `IntelligenceEngine.analyzeRecent(...)` (same args as the launch loop), so recovery + Rest recompute and Today refreshes, matching Swift.

### 2.4 Cross-platform consistency (D)
- One definition of the debt/need/tile input window, mirrored on both platforms.
- Decide asleep-vs-in-bed for the displayed-night tiles and make both platforms match (recommend asleep, the consistency tile already insists on it; drop the Android in-bed substitution).
- Align `SleepDebt.round1` rounding (Kotlin → half-away-from-zero, matching Swift).

### 2.5 Recompute-not-cache principle (research best practice)
Daily totals are always re-derived per day from the canonical session set when sessions change. Largely already true; B closes the Android gap. Add the observability the audit recommended: a one-line `persisted day=X totalSleepMin=Y matched=N` diagnostic so the next report ships proof of what was computed per day (and to settle E).

### 2.6 Honesty fixes
- Show real source on the By-Day card (computed vs imported), not a hard-coded "NOOP-computed" badge.
- Reply to pikapik on E honestly (not our bug, here's how to confirm), once we have the observability + the rest shipped.

### 2.7 Tests (F)
Add, both platforms: longest block with a daytime-gap onset + shorter overnight block → assert the longer wins; the [10:00,11:00) window-mismatch case; bedtime-edited onset crossing the boundary; nap-only day; biphasic/bridged night; cross-midnight; off-wrist-trimmed start.

---

## 3. Implementation plan (after approval)
1. **Engine core** (Swift + Kotlin `SleepStageTotals`): the new scored selector + gap-bridge + window reconcile, with the full edge-case test suite (TDD).
2. **Wire-through:** `analyzeDay` + `sleepEditedDaily` (effective onset) + the UI selectors call the one source of truth; `isNap` derives from the pick.
3. **Android re-score** on edit; **cross-platform window/rounding** unification.
4. **Honesty:** By-Day source badge + the per-day observability line.
5. **Verify:** full 3-platform gate + the new edge-case tests + an adversarial re-review of the scoring math. Then hold.

## 4. Open questions
- **Main-night rule:** ship v1 (broad overnight band + duration score) now and v2 (habitual-midsleep anchor) as a follow-up, or build the habitual anchor straight away? v1 fixes pikapik; v2 is the fully-robust shift-worker answer.
- **Nap vs sleep cutoff:** the research convergence is ~3h for "real sleep not a nap." NOOP currently scores shorter main sleeps. Keep scoring short main sleeps (no hard 3h floor, just the score), or adopt a soft 3h "this is a nap" lean?
- **Scope:** do all of section 2 in one verified update, or split (core selector first, parity/honesty second)?
