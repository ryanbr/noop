# NOOP v5 — Raw-Signal AI Coach (design spec)

Date: 2026-06-19
Status: Draft for review (design only, no code)
Codename: Strand · Pillar of NOOP v5
Author surface: anonymous independent project

---

## Goal & differentiation (why only NOOP)

Today NOOP's Coach is a **summary-fed chatbot**: `AICoachEngine.buildContext()`
flattens the last 14 days of *already-computed* daily scores (charge / effort /
rest / HRV / RHR) into ~1,500 tokens of plain text, prepends it to the first user
turn, and ships it under the user's own key. It is good, private, and honest — but
it can only ever **re-narrate a number it was handed**. Ask it *"why was my recovery
low on Tuesday?"* and it can say *"because your charge was 38"* — which is circular.
It cannot look at the actual Tuesday-night R-R series, the skin-temp deviation
trend, the accelerometer-derived restlessness, or the user's own discovered
correlations (alcohol → −12% recovery), because those never entered the prompt.

**v5 evolves the Coach into a first-principles, raw-signal reasoner** modelled on
the **PHIA pattern** (Personal Health Insights Agent, arXiv:2406.06464): instead of
being handed a pre-baked answer, the model is given a **tool/function layer** and
**generates its own analysis over the user's raw on-device timeseries and stats**.
It plans ("to answer 'why low recovery' I need: that night's HRV samples, skin-temp
deviation, the recovery driver breakdown, and any logged behaviours"), calls the
tools, reads the numbers NOOP already computes, and synthesises a grounded answer.

Why this is structurally **only-NOOP**:

- **WHOOP / Oura / Ultrahuman** assistants run in *their* cloud over *their* derived
  scores. They never expose your raw R-R / red-IR PPG / accelerometer to a model
  *you* control, and you cannot point them at a local model or your own key.
- **Apple / Garmin** have no conversational coach over raw signals at all.
- NOOP already owns the raw streams (`StreamStore`, `MetricSeriesStore`), the
  on-device analytics (`HRVAnalyzer`, `RecoveryScorer` driver breakdown,
  `CorrelationEngine`, `BehaviorInsights`, `WeeklyDigestEngine`), AND the
  privacy posture (BYO-key, on-device-orchestrated, summary-only egress).
  The raw-signal coach is the surface that *fuses all of that* into one answer.

The differentiator in one line: **NOOP is the only health app whose coach reasons
from your raw biosignals and your own discovered correlations, orchestrated entirely
on your device, under a key you control — and can run fully offline against a local
model.**

This pillar keeps every existing guarantee: **opt-in, BYO-key, on-device-orchestrated,
summary-only egress, wellness-not-medical, anonymous.** It does not weaken privacy —
it makes the *same* small text egress *smarter* by letting the model choose *which*
small summaries it needs, rather than always sending one fixed blob.

---

## Data & signals used (already available vs new)

### Already available (reuse — no new capture)

All of these are already computed/stored on-device. The new work is **exposing them
to the coach as callable tools**, not capturing them.

| Signal / stat | Source primitive (existing) | Notes |
|---|---|---|
| Daily charge/effort/rest, HRV, RHR, SpO₂, respiration, skin-temp dev, steps, kcal | `Repository.days` (`DailyMetric`) | Already in today's context |
| Per-key daily series (any metric, by day) | `Repository.series(key:source:)`, `resolvedSeries`, `exploreSeries` | Powers Insights |
| Beat-to-beat R-R → HRV (RMSSD/SDNN/pNN50, clean vs raw) | `HRVAnalyzer.analyze(_:)` over `StreamStore` R-R | Raw, on-device |
| Recovery driver breakdown (which input pushed the score) | `RecoveryScorer.DriverBaseline` / score internals | The "why" of charge |
| Sleep stages & efficiency, sleep debt | `SleepStager`, `SleepStageTotals`, `SleepDebt`, `Repository.sleepSessions` | Raw motion-derived |
| HR buckets / zone minutes (accel + HR derived) | `Repository.hrBuckets`, `workoutZoneMinutes`, `HRZones` | |
| Behaviour effects (does X move outcome Y) | `BehaviorInsights.rank/effect/sentence` | Alcohol, late meal, etc. |
| Pairwise + lagged correlations (e.g. strain→next-day recovery) | `CorrelationEngine.pearson/alignByDay/lagged` | The new "labs" data |
| Weekly digest + balance read | `WeeklyDigestEngine`, `WeeklyDigest` | Trend narrative |
| Daytime stress, sedentary, fitness age, recovery forecast | `DaytimeStress`, `SedentaryDetector`, `FitnessAgeEngine`, `RecoveryForecast` | |
| Workouts | `Repository.workoutRows`, `WorkoutDetector` | Already in context |
| Imported Health Records / Apple Health / nutrition / 3rd-party | `StrandImport` (`AppleHealthAggregator`, `NutritionCsvImport`, etc.) | Opt-in imports |

### New (this pillar)

- **No new sensor capture.** The pillar is an orchestration + tool layer, not a new
  collector. (R-R, PPG, accel, skin-temp already flow through `StreamStore`.)
- **`CoachToolKit`**: a thin, read-only, deterministic façade over the stores/engines
  above, returning *compact JSON-ish text* the model can read (see Architecture).
- **Tool-call loop**: an agentic loop that lets a tool-capable provider call those
  tools, then answer. (Providers that don't support tool-calling fall back to today's
  one-shot context — see Cross-platform plan.)
- **Provenance trail**: each answer records *which tools it called with which args*
  so the UI can show a "based on: HRV samples for 2026-06-17, recovery drivers,
  alcohol correlation" footer — honesty about what was actually read.

---

## On-device algorithm (grounded; cite the approach)

### The PHIA-style agentic loop (the core)

We adopt the **code-and-retrieval agent** shape from PHIA (arXiv:2406.06464), but
*tool-calling* rather than arbitrary code-exec (safer, deterministic, no sandbox):

```
user question
  → COACH (LLM under user's key)
      ↳ plans: which on-device facts does this need?
      ↳ emits tool calls (name + args)        ──►  CoachToolKit (on-device, deterministic)
      ↳ reads tool results (compact text)     ◄──  numbers NOOP already computed
      ↳ (optionally calls more tools)
      ↳ synthesises grounded answer + provenance
```

Loop control (on-device, deterministic — the model never controls these):

- **Max N tool rounds** (default 4) and **max M total tool calls** (default 8) per
  question. Hard cap → forces an answer, bounds token cost and latency.
- **Whitelisted tools only.** The model can only call the registered read-only tools;
  there is no free-form query, no SQL, no code-exec, no write path.
- **Budgeted results.** Each tool truncates to a token budget (e.g. an HRV-samples
  tool returns summary stats + a downsampled sparkline, never thousands of raw R-R
  values). The *raw* never leaves; a *computed summary of the raw* does.
- **Determinism for the math.** All statistics (HRV, correlation, effect size,
  drivers) are computed by the existing pure engines, NOT by the model. The model
  *orchestrates and explains*; it never does the arithmetic. This is the honesty
  guarantee — numbers come from `HRVAnalyzer` / `CorrelationEngine` /
  `BehaviorInsights`, which are unit-tested.

### Worked example — "Why was my recovery low on Tuesday?"

1. `get_recovery_drivers(day:"2026-06-17")` → `{charge:38, dominant:"HRV −1.6σ below baseline", rhr:"+6bpm", skinTemp:"+0.7°C", sleepDebt:"+1h20m"}`
2. `get_hrv_detail(night:"2026-06-17")` → `{rmssd:31ms (baseline 48), nClean:412, trend:"falling 3 nights"}`
3. `list_significant_behaviors(outcome:"recovery")` → `BehaviorInsights.sentence(...)` for the top effects, e.g. *"On days you logged 'Alcohol', recovery was 12% lower (61 vs 69)."*
4. `get_behavior_on_day(day:"2026-06-16")` → `{alcohol:true, lateMeal:true}`
5. Coach answers: *"Your charge was **38**. The biggest driver was **HRV at 31ms — about 1.6σ under your 48ms baseline** — alongside a **+0.7 °C skin-temp rise** and **+6 bpm resting HR**, all of which point to your body still working harder than usual. You logged **alcohol the night before**, and across your history alcohol nights run **~12% lower recovery**. Today, treat it as an active-recovery day…"* — with a provenance footer listing the 4 tools.

Every clause is anchored to a deterministic, on-device number.

### Local-model degradation

A small local model (Gemma-class) often won't reliably emit structured tool calls.
The loop degrades gracefully: if the provider/model isn't tool-capable, NOOP runs a
**single deterministic "evidence pack"** — it pre-runs the most relevant tools for
the question class (recovery/sleep/strain/general, picked by keyword match) and
prepends their results as today's context does. So even a dumb local model gets
*richer-than-today* grounding without a tool loop. (See Phasing.)

---

## Architecture & files (engine package + Kotlin twin + UI)

### Principle

The *math and data access* are pure and shared; the *LLM transport* is per-platform
(it already is). We **do not** move networking into a Swift package — we add a
**deterministic, testable tool layer** that both the Swift engine and the Kotlin twin
call, mirroring the existing `StrandAnalytics` ↔ Kotlin-mirror pattern.

### Swift (macOS + iOS) — reuse + new

```
Packages/StrandAnalytics/Sources/StrandAnalytics/
  CoachTools.swift            (NEW) — pure tool *definitions*: name, args schema,
                                       result-formatting helpers. NO networking,
                                       NO store access. Deterministic string output
                                       from already-fetched values. Unit-tested.
  CoachToolPlanner.swift      (NEW) — keyword→tool-set fallback "evidence pack"
                                       selection (recovery/sleep/strain/general).
                                       Pure. Unit-tested.

Strand/AI/                    (existing folder; app-layer, has store access)
  AICoach.swift               (EXTEND) — AICoachEngine gains a tool loop:
                                       buildContext() stays for fallback; new
                                       runToolLoop() drives rounds, dispatches tool
                                       calls to CoachToolKit, feeds results back.
  CoachToolKit.swift          (NEW) — the READ-ONLY façade that actually binds tool
                                       names → Repository / StrandAnalytics calls
                                       (HRV detail, drivers, correlations, behaviours,
                                       sleep, weekly digest, imports). Returns the
                                       compact text from CoachTools formatters.
  Providers/*.swift           (EXTEND) — add optional tool-calling to OpenAI/Anthropic/
                                       Gemini/Custom clients (function-calling wire
                                       format). A capability flag per provider/model;
                                       no tool support → one-shot path unchanged.
```

`CoachTools` lives in the **shared package** so its formatters and the planner are
unit-tested once and reused. `CoachToolKit` stays in the **app layer** because it
touches `Repository` (which is app-level, `@MainActor`), exactly like today's
`buildContext()` does.

### Kotlin twin (Android)

```
android/app/src/main/java/com/noop/ai/
  CoachTools.kt          (NEW) — value-for-value twin of CoachTools.swift:
                                  same tool names, same arg schema, same compact
                                  output format. Pure. Unit-tested (mirror of the
                                  Swift tests — the existing AiCoachContextTest.kt
                                  pattern).
  CoachToolKit.kt        (NEW) — binds tool names → WhoopRepository / analytics
                                  mirror calls. Returns CoachTools-formatted text.
  CoachToolPlanner.kt    (NEW) — keyword→tool-set fallback, twin of the Swift planner.
  AiCoach.kt             (EXTEND) — chat() gains the tool loop for tool-capable
                                  providers; existing one-shot path is the fallback.
```

### What to REUSE (do not rebuild)

- `AICoachEngine` / `AiCoach` — keep the whole key/Keychain, provider, consent,
  windowing, error mapping, privacy-note machinery. Extend, don't replace.
- `AIProvider` + `Providers/*` — extend with tool-calling; do not fork.
- `buildContext()` / `buildFullContext()` — becomes the **fallback evidence pack**
  and the seed turn; not deleted.
- `HRVAnalyzer`, `RecoveryScorer`, `CorrelationEngine`, `BehaviorInsights`,
  `WeeklyDigestEngine`, `SleepStager`, `FitnessAgeEngine`, `RecoveryForecast` —
  the coach reads *their* output; it never re-implements their math.
- `Repository` read methods (`series`, `resolvedSeries`, `sleepSessions`,
  `workoutRows`, `journalEntries`, `hrBuckets`, `dailyMetrics`) — the tool kit's
  only data source.
- `AIKeyStore` / `AiKeyStore` (Keychain / EncryptedSharedPrefs) — unchanged.
- The consent gate (`dataConsent`) — **the tool loop is gated by the same flag.**
  No consent → no tools run, model answers generally (identical to today).

---

## Cross-platform plan

- **macOS + iOS** share `CoachTools` / `CoachToolPlanner` (Swift package) verbatim;
  `CoachToolKit` is app-layer but identical logic on both (same `Repository`).
- **Android** gets the hand-ported Kotlin twin (`CoachTools.kt` etc.), kept in lockstep
  by a **golden test**: the same fixture day must produce **byte-identical tool output
  strings** in Swift XCTest and Kotlin JVM tests (extends the existing
  `AiCoachContextTest` parity pattern). This is the parity guarantee.
- **Provider tool-calling** is added once per wire format and shared across platforms
  by mirroring the JSON shape (OpenAI/Custom `tools` + `tool_calls`; Anthropic
  `tools` + `tool_use`/`tool_result`; Gemini `functionDeclarations`/`functionCall`).
- **Tool-capability matrix** is data, not code: a per-(provider, model) flag. Unknown
  models default to **no tools → one-shot fallback**, so nothing breaks.
- Parity rule (per workspace memory): a NOOP change must reach all three clients.
  MVP ships the **fallback evidence pack on all three** first (no provider tool-calling
  needed), then layers the tool loop. That keeps Android from lagging behind a
  Swift-only feature.
- Build/verify centrally (don't run gradle per-agent): swift-test the package, JVM
  test the Kotlin twin, then one central 3-platform build.

---

## UX (screens/flows per platform — honest + skimmable)

The Coach screen (`CoachView.swift` / `CoachScreen.kt`) is **kept**; we add depth, not
a new tab.

### Shared flow

1. **Setup unchanged** — pick provider, paste your own key (or point Custom at a local
   server), choose a model. Same privacy footnote.
2. **Consent bar unchanged** — "Let the coach use my data" (off by default). The tool
   loop only runs when this is on.
3. **Ask** — same composer + suggestion chips. New chips lean into the raw-signal
   angle: *"Why was my recovery low?"*, *"What's hurting my sleep?"*,
   *"Is alcohol affecting me?"*, *"Why is my HRV down this week?"*
4. **Thinking, transparently** — while the loop runs, the "Coach is thinking…" pill
   shows the step honestly: *"Reading your HRV detail…"*, *"Checking your alcohol
   correlation…"* (the tool's human label). No fabricated drama; just what it's doing.
5. **Answer + provenance** — the Markdown reply (existing renderer) plus a small,
   collapsible **"Based on"** footer chip-list naming the tools/days it read. Tapping
   a chip can deep-link to the matching screen (HRV snapshot, Insights, Sleep) so the
   user can verify the number themselves. Honesty by construction.
6. **Capability honesty** — if the chosen model can't do tool calls, a one-line note:
   *"This model answers from a prepared summary of your data. For step-by-step
   reasoning over your signals, pick a model that supports tools."* No silent
   downgrade.

### Platform specifics

- **macOS**: provenance footer renders as a wrapped chip row under the bubble;
  hovering a chip shows the exact figures (e.g. the tool's raw result text).
- **iOS**: same, chips are tappable to the relevant detail screen; "Thinking" steps
  appear as a single replacing line (no scrolling spam).
- **Android (Compose)**: mirror — `CoachScreen.kt` gains the step line + the
  provenance `FlowRow` of chips. Markdown via existing `CoachMarkdown`.

### Anti-patterns (explicitly avoided)

- No auto-sending, ever. Tools run only after a key + consent + an asked question.
- No "agent ran 19 steps" spinner-of-doom — capped rounds, honest single status line.
- No invented numbers — if a tool returns "not enough data", the coach must say so
  (system prompt rule + because the deterministic tool literally returns that).

---

## Non-clinical / legal framing (wellness-only, never diagnostic)

This pillar **increases** the surface where a model talks about the body, so the
framing must be tighter, not looser.

- **Wellness, not medical.** The coach gives **training, sleep, and lifestyle
  suggestions** from wellness signals. It is **not** a medical device, does **not**
  diagnose, and does **not** treat. This is already in the system prompt
  ("You are NOT a doctor — never diagnose"); v5 **strengthens** it: an explicit rule
  that even when reasoning over raw R-R / skin-temp / SpO₂, it must frame findings as
  *wellness observations and coaching*, never as a condition, and must route genuine
  health concerns to a professional.
- **"Reasoning over signals" ≠ "interpreting symptoms."** The prompt forbids naming
  diseases, suggesting one might have a condition, or interpreting a metric as a
  clinical sign (e.g. it may say *"your skin temp is up and HRV is down — a good day
  to go easy and prioritise sleep"*; it may **not** say *"this could be an
  infection / illness"*). A short deny-list of clinical-claim patterns is included in
  the prompt.
- **Honest about limits.** PPG-derived HRV/HR, motion-derived sleep staging, and
  skin-temp *deviation* (not absolute core temp) are estimates from a consumer strap;
  the provenance footer and copy say "estimated from your strap", consistent with the
  rest of NOOP (e.g. the SpO₂ walk-back, skin-temp-as-deviation).
- **Privacy copy unchanged and reinforced.** Same `aiCoachPrivacyNote`: nothing leaves
  until a key is set, consent is on, and a question is asked; only a **compact text
  summary** of computed values goes to the provider the user chose — *never raw R-R /
  PPG / accelerometer streams*. v5 must keep this literally true: tools emit summaries,
  never raw sample dumps. This is a **hard invariant** with a test (below).
- **Anonymity (absolute).** The Coach is the **one** allowed AI surface, and only as
  **the user's own choice of provider under their own key**. Shipped copy, system
  prompts, tool names, and provenance labels **never** reference any project-side AI,
  model vendor, or that the app author uses AI. The system prompt names no app, no
  author, no vendor — only "coach". (Matches `feedback_ai_deflection`.)
- **USD, jurisdiction-neutral.** Any cost framing in copy uses **USD**; legal copy
  stays jurisdiction-neutral (consistent with TERMS.md).
- Existing `DISCLAIMER.md` / `TERMS.md` cover this; add one line noting the coach may
  reason over raw-derived signals but remains wellness-only.

---

## Test plan

Pure/deterministic layers get real unit tests; the LLM transport is contract-tested
with stubs (never a live network call in CI).

1. **Tool formatters (`CoachTools` Swift + Kotlin)** — given a fixed fixture day,
   each tool produces the expected compact string. **Golden parity test**: Swift and
   Kotlin outputs are byte-identical for the same fixture (extends
   `AiCoachContextTest`). This is the cross-platform guarantee.
2. **Planner (`CoachToolPlanner`)** — keyword→tool-set mapping is deterministic and
   covered (recovery/sleep/strain/general; unknown → general).
3. **No-raw-egress invariant (security test)** — assert every tool's output for a
   fixture night contains **summary stats / downsampled values only**, and its length
   is under the per-tool token budget; assert no tool returns more than K raw samples.
   This is the privacy guarantee, enforced by test.
4. **Loop control** — with a scripted "model" stub that always asks for one more tool,
   the loop stops at max rounds and still produces an answer; with a stub that calls an
   unknown tool, the kit returns a safe "unknown tool" result, not a crash.
5. **Consent gate** — consent off ⇒ zero tool calls, generic answer (parity with
   today's `noConsentNote` path).
6. **Fallback path** — a non-tool-capable model gets the evidence pack and a richer
   one-shot context; verify the pack is assembled deterministically.
7. **Provider wire format** — encode/decode tool-call request/response for
   OpenAI/Anthropic/Gemini/Custom against captured fixtures (no network), incl. the
   "model returned no tool call, just text" terminal case.
8. **Anonymity scan** — a test/grep asserting no shipped string in the coach surface
   (prompts, tool names, labels) names a model vendor or the app author.
9. **Regression** — existing coach tests (context build, windowing, key ownership)
   still pass unchanged; the one-shot path is untouched.

---

## Phasing

### MVP (v5.0) — richer grounding, no agent loop required

- `CoachTools` + `CoachToolKit` + `CoachToolPlanner` (Swift + Kotlin) with the core
  read tools: `get_recovery_drivers`, `get_hrv_detail`, `get_sleep_detail`,
  `list_significant_behaviors`, `get_correlation`, `get_weekly_digest`,
  `get_day_summary`.
- **Fallback evidence pack** wired on all three platforms: planner picks the relevant
  tools for the question and prepends their deterministic output (replaces/augments
  today's fixed `buildContext()`). **No provider tool-calling needed** → ships
  everywhere at once, works with local models, honours all privacy/consent rules.
- Provenance footer (which tools fed the answer).
- Strengthened non-clinical system prompt + anonymity scan.

This alone makes the coach *materially smarter* (it can cite drivers and your
correlations) while shipping to all clients in lockstep with zero new dependencies.

### Phase 2 — true agentic tool loop

- Add tool-calling to OpenAI/Anthropic/Gemini/Custom clients; capability matrix;
  multi-round loop with caps; honest "thinking" step line. Tool-capable models get
  PHIA-style iterative reasoning; everyone else keeps the MVP evidence pack.

### Phase 3 (STRETCH — explicitly not a v5 dependency) — bundled local model

- An **optional** small on-device model (**Gemma-class via MLX on Apple silicon /
  ExecuTorch on Android**) so the coach can run **fully offline with zero key**.
- **Must be a separate, clearly-marked download**, never bundled into the base app
  (a ~1 GB model would balloon the binary and break the lean, anonymous distribution).
  Presented as: *"Run Coach fully offline — download a local model (~1 GB)."* Opt-in,
  deletable, with honest expectations (a small local model reasons less reliably than
  a frontier cloud model; tool-calling may be limited → it uses the evidence-pack
  path). **v5 ships and is complete without this.** It is a future enhancement, gated
  on real device-perf validation (memory, thermals, latency) before any commitment.

---

## Open questions

1. **Tool-call wire formats** differ across the 4 providers (and Custom/Ollama tool
   support is patchy). Confirm the minimum viable set for Phase 2 — do we require
   OpenAI + Anthropic first and treat Gemini/Custom tool-calling as best-effort?
2. **Token budget per tool** — what's the right cap so a 4-round loop stays cheap on
   cloud and fits a 2,048-token local window? (HRV-detail and correlation tools are
   the fattest.)
3. **Provenance depth** — show just tool names, or tool names + the exact figures
   returned? More transparency vs. more clutter in a chat bubble.
4. **Local-model footprint** (Phase 3) — which Gemma-class size actually runs within
   memory/thermal budget on a mid-range Android and an iPhone, and does it ever
   tool-call reliably, or is it evidence-pack-only forever?
5. **Health Records / imported data** — how deep should tools reach into imported
   Apple Health / nutrition / third-party data, and how do we keep that *summary-only*
   in egress (the same no-raw-dump invariant)?
6. **Suggested-prompt curation** — the new chips imply capabilities ("why is my HRV
   down"); ensure each maps to a tool path that returns *something* even on sparse data
   (don't promise an answer we can't ground).
7. **macOS network entitlement** — the sandboxed macOS build's AI Coach network path
   (per `project_strand_decisions`) — confirm it's enabled for the tool loop, or the
   feature is iOS/Android-first on the cloud path.
