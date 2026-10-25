# Oura live API import — design

This is a historical design proposal, not current setup instructions. The implementation lives in
[`Strand/Oura/`](../../../Strand/Oura/), with pure parsers in
[`StrandImport`](../../../Packages/StrandImport/Sources/StrandImport/) and storage in
[`OuraRawStore`](../../../Packages/WhoopStore/Sources/WhoopStore/OuraRawStore.swift).
Current build opt-in, credentials and privacy behavior are documented in
[Privacy/security §1.1b](../../PRIVACY_SECURITY.md#11b-the-oura-history-import-compiled-out-by-default-bring-your-own-oauth-app).
The original completed execution recipes remain available at their implementation commit:
[foundation](https://github.com/ryanbr/noop/blob/cb749ae8cc2fedd5cb67ef5c44d82a493f041e0e/docs/superpowers/plans/2026-06-27-oura-live-api-import-1-foundation.md),
[network/auth](https://github.com/ryanbr/noop/blob/cb749ae8cc2fedd5cb67ef5c44d82a493f041e0e/docs/superpowers/plans/2026-06-27-oura-live-api-import-2-network-auth.md),
[orchestration/UI](https://github.com/ryanbr/noop/blob/cb749ae8cc2fedd5cb67ef5c44d82a493f041e0e/docs/superpowers/plans/2026-06-27-oura-live-api-import-3-orchestration-ui.md).

- **Date:** 2026-06-27
- **Status:** Draft for review
- **Scope:** iOS only (the Swift app). macOS, Android explicitly out (see §13).
- **Author:** design session (brainstorming → spec)
- **Supersedes/relates:** the existing offline Oura file-import lane (`WearableExportImporter` / `OuraExportParser`); the roadmap entry [`docs/DEVICE_SUPPORT_ROADMAP.md`](../../DEVICE_SUPPORT_ROADMAP.md) "Oura — Cloud API v2 — off-by-default OAuth import lane only".

---

## 0. v8.5.2 reconciliation (2026-06-30)

This spec was written against v7.2.3; work now targets upstream **v8.5.2** (`ryanbr/noop`, on branch `oura-cloud-import`). Corrections below are verified against current code and **supersede the inline references** further down:

- **Migration number.** The WhoopStore migrator is at **v23** (not v18); the `ouraRaw` table (§4/§8.5/§14) is migration **v24** (not v19 — `v19-step-activity-class`…`v23-daily-spo2-raw` already exist).
- **Provenance (§8.4).** Register the cloud source as `PairedDevice.sourceKind = .cloudImport` — it already exists (`PairedDevice.swift:42`) and is treated as non-day-owning (`IntelligenceEngine.swift:1369`), so **no new SourceKind is needed**. `deviceId = "oura-api"` stands; `DataSourceKind.ouraApi` is now *optional* (add only if a StrandImport-level provenance tag is actually consumed).
- **`motionJSON` (§8.2).** Written via the dedicated `persistSessionMotion(deviceId:sessionStart:motionEpochs:[Double])` (`MetricsCache.swift:234`), **not** through `upsertSleepSessions` (`CachedSleepSession` has no `motionJSON` field). Map `movement30s` `[Int]→[Double]`.
- **New integration points.** Add `"oura-api"` to `Repository.wearableImportSources` (`Repository.swift:452`) if it should join the import-source union; disconnect via the actor `store.deleteAllData(deviceId:)` (`DataSourcesView.swift:598`), not `DeviceRegistryStore` directly (avoids a main-actor stall).
- **UI (§9).** `DataSourcesView` is entirely file-picker cards today; the live "connect/adopt" precedent is `AddDeviceWizard.swift`. Decide explicitly whether cloud Oura is an *import card* (mirrors the export card) or a *connect-device* flow — the OAuth "Connect" button is a new pattern here.
- **Confirmed intact (no change):** the `Wearable*` models + initializers, all five upsert APIs and their row structs, every target table shape, and the network-free-packages invariant. The `#862` export-parser hardening **confirmed** our field mapping (incl. the nested `spo2_percentage.average`). The foundation design holds.

---

## 1. Summary

NOOP already imports a user's own Oura data from the **account export file** (a single JSON), parsed by
[`OuraExportParser`](../../../Packages/StrandImport/Sources/StrandImport/OuraExportParser.swift) into the
normalized `WearableDailyRow` / `WearableSleepSession` models. That lane is lossy by necessity: the file
export carries stage **durations** but no hypnogram, no heart-rate/HRV time series, and only a handful of
daily metrics.

This feature adds a **live Oura API v2 lane** that pulls the user's **full** Oura history once, over the
network, under the user's own OAuth grant — capturing the rich data the file export can't: the
`sleep_phase_5_min` hypnogram, `heart_rate`/`hrv` time series, per-night HR series, SpO2, daytime stress,
resilience, cardiovascular age, VO2 max, workouts, sessions, tags, and ring metadata, across ~18 endpoints.

It is a **one-time, pull-everything** operation (the user's stated use case), behind an off-by-default
opt-in — NOOP's **second** network exception after the AI Coach. Storage is **lossless**: every raw Oura
payload is archived verbatim, and a curated subset is normalized into the existing on-device tables so the
dashboard, Sleep tab, and Metric Explorer light up immediately. A future "Sync again" re-pull is a button,
not new architecture.

---

## 2. Goals / non-goals

### Goals
- **G1 — Maximum fidelity.** Pull as much of the Oura v2 surface as the grant allows; never silently drop a
  field. Raw payloads are retained verbatim so new metrics can be derived later without re-fetching.
- **G2 — One-time backfill.** A single "Connect Oura & Import Everything" action that authenticates, walks
  all of history across all endpoints, stores, and reports an honest summary.
- **G3 — Fit, don't duplicate.** Reuse `OuraExportParser`'s field mapping and the existing `WhoopStore`
  write path (`dailyMetric`, `sleepSession`, `metricSeries`, `hrSample`, `workout`) and the device registry.
- **G4 — Honest data.** Oura's own scores (readiness, sleep, activity, resilience) are stored **reference-only**
  and never become NOOP's Charge/Effort/Rest, exactly as the file lane already does.
- **G5 — Preserve invariants.** Every Swift package stays network-free; `StrandImport` stays offline-pure;
  untrusted JSON is treated as hostile; the WHOOP experience never regresses.
- **G6 — Re-pull seam.** Tokens (incl. refresh) persist so a later re-pull needs no re-auth; auth sits
  behind an `AuthProvider` protocol so OAuth-with-backend can replace BYO-app later without touching fetch/parse.

### Non-goals (this spec)
- **NG1 — No background sync / webhooks.** No `BGTaskScheduler`, no incremental "changed since" diffing, no
  Oura webhook subscriptions (those need a public callback URL / backend).
- **NG2 — No backend.** No server component. The OAuth `client_secret` is the user's own (BYO app).
- **NG3 — No macOS / Android.** iOS Swift app only.
- **NG4 — No new scoring.** NOOP's recovery/strain/sleep math is unchanged; this only feeds it inputs.

---

## 3. Background constraints (verified)

### 3.1 Oura API v2 (verified against the live OpenAPI spec `openapi-1.35.json`, `info.version 2.0`, fetched 2026-06-27)
- **Personal Access Tokens are deprecated (Dec 2025) and can no longer be created.** OAuth2 is the only path.
- **OAuth2 is plain authorization-code, no PKCE.** Authorize `https://cloud.ouraring.com/oauth/authorize`;
  token `https://api.ouraring.com/oauth/token`; bearer header `Authorization: Bearer <token>`. The code→token
  exchange requires `client_id` + `client_secret`. Refresh tokens are issued by the server-side flow.
- **Scopes (8):** `email`, `personal`, `daily`, `heartrate`, `workout`, `tag`, `session`, `spo2Daily`
  (the auth page labels SpO2 as `spo2` — verify against the live consent screen at build time).
- **Pagination:** every list/time-series response carries `next_token` (repeat with `next_token=` until null).
- **Rate limit:** 5000 requests / 5-minute window → HTTP 429 on exceed. A multi-year backfill across ~18
  endpoints fits comfortably with light pacing + backoff.
- **No `changed_since`.** Incremental sync (future) re-pulls a trailing window and upserts by `id`, because
  Oura re-scores prior days. Not needed for the one-time pull.
- **Membership gate:** Gen3 / Ring 4 users without an active Oura Membership get empty/4xx from the API.
  Handle honestly in the UI (see §9).
- **Sandbox:** every collection endpoint has a twin at `/v2/sandbox/usercollection/...` returning static demo
  data with identical schemas — used for development and as a live smoke test without a real account.

### 3.2 NOOP invariants this feature must not break
- **Offline-by-default privacy posture** ([`docs/PRIVACY_SECURITY.md`](../../PRIVACY_SECURITY.md) §1).
  The five Swift packages are network-free; the AI Coach (in the **app target**) is the single opt-in network
  exception. → The Oura networking lives in the **app target**, and is documented as the **second** opt-in
  exception. The data flow is **inbound** (Oura → device, the user's own data, under the user's own grant);
  nothing of the user's existing NOOP data leaves the device except the OAuth handshake with Oura.
- **`StrandImport` is offline-pure** — its banner reads "STAY OFFLINE: nothing here touches the network."
  → Only **pure** (no-network) Oura-API response parsers are added to `StrandImport`; the fetch happens in the
  app target. This mirrors the existing split: `StrandImport` parses, `Strand/Data/WearableImporter.swift` writes.
- **Honest data** — a brand's own scores are reference-only; NOOP recomputes downstream.
- **Untrusted input is hostile** ([`docs/PRIVACY_SECURITY.md`](../../PRIVACY_SECURITY.md) §3) — byte caps,
  finite/range-checked numerics, bounded collection counts (reuse `WearableJSON` coercion helpers).
- **Supply chain** — dependencies are pinned `exact:` and must match across `Packages/*/Package.swift` and
  `project.yml`. This feature adds **no** third-party dependency (uses `URLSession` + `ASWebAuthenticationSession`
  + `Security`, all first-party).
- **WHOOP primacy** — Oura is an additional source; it must not auto-seize day ownership from WHOOP (§8.4).

---

## 4. Architecture overview

```
┌──────────────────────────── app target: Strand/Oura/ (NETWORK lives here, beside Strand/AI/AICoach) ────────────────────────────┐
│                                                                                                                                  │
│  OuraCredentials      OuraAuth (AuthProvider)            OuraAPIClient                 OuraSyncCoordinator        OuraSyncWriter   │
│  client_id/secret  →  ASWebAuthenticationSession      →  URLSession + paging +      →  one-time backfill:      →  WhoopStore      │
│  from xcconfig        code → token exchange              rate-limit/backoff +          fan out across all         upserts +       │
│  (Info.plist)         tokens → Keychain (AIKeyStore)     sandbox/prod base URL         endpoints, page each       registry +      │
│                                                                                        date-windowed, decode       dayOwnership   │
│                                                                                        via pure parsers ↓                         │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┼──────────────────────────┘
                                                                                                        │ Data (raw JSON)
┌──────────────── package: StrandImport (PURE, network-free) ─────────────┐                             ▼
│  OuraApiParser (new)  ── reuses ──▶  OuraExportParser helpers            │     ┌──────────── package: WhoopStore (GRDB/SQLite) ───────────┐
│  + OuraHypnogram decoder (sleep_phase_5_min / 30_sec, movement_30_sec)   │     │  ouraRaw (NEW, v19)  ·  dailyMetric  ·  sleepSession      │
│  + rich API model types (time series, sessions, resilience, …)          │     │  metricSeries  ·  hrSample  ·  workout  ·  pairedDevice   │
│  emits: WearableDailyRow / WearableSleepSession (+ stages) + rich models │     │  dayOwnership                                            │
└─────────────────────────────────────────────────────────────────────────┘     └───────────────────────────────────────────────────────────┘
```

**Components (all new unless noted):**

| Component | Location | Responsibility | Networks? |
|---|---|---|---|
| `OuraCredentials` | `Strand/Oura/` | Read `client_id` / `client_secret` / redirect from an **untracked xcconfig** surfaced via Info.plist. | no |
| `AuthProvider` (protocol) + `OuraOAuthProvider` | `Strand/Oura/` | The auth seam. `OuraOAuthProvider` runs `ASWebAuthenticationSession`, exchanges code→tokens, stores/loads/refreshes via Keychain. | yes |
| `OuraTokenStore` | `Strand/Oura/` | Keychain wrapper for access/refresh tokens + expiry, mirroring `AIKeyStore` (service `com.noop.oura`). | no |
| `OuraAPIClient` | `Strand/Oura/` | Typed `URLSession` client: per-endpoint GET, `next_token` paging, 429/5xx backoff, base-URL switch (prod vs sandbox), bounded byte reads. | yes |
| `OuraSyncCoordinator` | `Strand/Oura/` | One-time backfill orchestration: discover account span, fan out across endpoints, window requests, hand pages to the pure parser, drive progress, persist a "last full sync" marker. | yes (via client) |
| `OuraSyncWriter` | `Strand/Oura/` | Map parsed models → `WhoopStore` upserts; archive raw; register the source; never auto-own days. Mirrors `WearableImporter`. | no |
| `OuraApiParser` + `OuraHypnogram` + rich model types | `Packages/StrandImport/Sources/StrandImport/` | **Pure** decode of Oura API JSON → normalized + rich models; reuses `OuraExportParser` + `WearableJSON`. | no |
| `ouraRaw` table (migration **v19**) | `Packages/WhoopStore/.../Database.swift` | Lossless raw payload archive. | no |
| `DataSourceKind.ouraApi` | `Packages/StrandImport/.../ImportModels.swift` | New provenance case (enum only). | no |
| Oura card + connect/sync UI | `Strand/Screens/DataSourcesView.swift` (+ small new views) | Connect, progress, summary, membership-gate messaging, disconnect. | no |

---

## 5. Auth design (BYO Oura app, authorization-code, one-time)

### 5.1 Flow
1. The user registers a **free OAuth application** on Oura's developer portal once (redirect URI =
   NOOP's custom scheme, e.g. `noop://oura/callback`), then provides its `client_id` + `client_secret`.
   For the personal/one-time case these go into an **untracked xcconfig** (no in-app credential screen to
   build); see §5.3. (A paste-credentials screen is a noted alternative — §12 Q2.)
2. Tapping **Connect** runs `ASWebAuthenticationSession` against
   `https://cloud.ouraring.com/oauth/authorize?response_type=code&client_id=…&redirect_uri=…&scope=<all 8>&state=<nonce>`.
3. On redirect, NOOP validates `state`, extracts `code`, and POSTs to
   `https://api.ouraring.com/oauth/token` with `grant_type=authorization_code`, the code, redirect, and
   `client_id`/`client_secret` → `{access_token, refresh_token, expires_in}`.
4. Tokens + expiry are stored in Keychain (`OuraTokenStore`, `kSecAttrAccessibleAfterFirstUnlock`, mirroring
   [`AIKeyStore`](../../../Strand/AI/AICoach.swift)).
5. The backfill (§7) runs. On 401 mid-sync, the client refreshes via `grant_type=refresh_token` once and retries.

### 5.2 The `AuthProvider` seam
```swift
protocol AuthProvider {                       // Strand/Oura/
    func validAccessToken() async throws -> String   // returns a fresh token, refreshing if needed
    func authorize() async throws                    // interactive: runs ASWebAuthenticationSession + exchange
    func signOut() throws                            // clears Keychain
    var isConnected: Bool { get }
}
```
`OuraAPIClient` depends only on `AuthProvider`. Shipping BYO-app today vs. a backend-mediated flow later is a
provider swap; fetch/parse/store are untouched.

### 5.3 Credentials delivery (default: xcconfig)
- An untracked `Strand/Oura/OuraSecrets.xcconfig` (gitignored) defines `OURA_CLIENT_ID`, `OURA_CLIENT_SECRET`,
  `OURA_REDIRECT_URI`, referenced from `project.yml` (XcodeGen) and surfaced into Info.plist; `OuraCredentials`
  reads them at runtime. A committed `OuraSecrets.example.xcconfig` documents the keys.
- The redirect scheme is registered in `CFBundleURLTypes` (Info.plist via `project.yml`).
- **No secret is committed**; for a single-user build the secret never leaves that user's machine/binary.

---

## 6. The Oura API client

- **Base URL switch:** `https://api.ouraring.com/v2/usercollection/…` (prod) vs `…/v2/sandbox/usercollection/…`
  (dev/tests). A single `OuraEnvironment` enum.
- **Request:** `GET` with `Authorization: Bearer`, `start_date`/`end_date` (or `start_datetime`/`end_datetime`
  for `heartrate`), and `next_token` when paging.
- **Paging:** loop until `next_token == nil`, accumulating `data[]`. A per-endpoint hard page cap (e.g. 10⁴
  pages) is a runaway guard, logged if hit (never silent — §3.2).
- **Rate-limit & resilience:** on `429`, honor backoff and retry; on `5xx`/transport error, bounded
  exponential backoff with jitter; on `401`, refresh-once-then-retry. A small global pacer keeps well under
  5000/5-min.
- **Bounded reads:** cap per-response bytes (reuse the 256 MB ceiling rationale from `WearableExportImporter`)
  and decode with `JSONSerialization` through the existing `WearableJSON` finite/range-checked coercion so a
  hostile/garbled response can't OOM or trap.
- **Decoding:** the client returns raw `Data` per page to the coordinator, which (a) hands it to `OuraSyncWriter`
  for verbatim archival and (b) hands it to the pure `OuraApiParser` for normalization. The client itself does
  not interpret payloads beyond `data`/`next_token` envelope extraction.

---

## 7. Sync orchestration (one-time backfill)

`OuraSyncCoordinator.runFullImport()`:
1. **Span discovery.** `GET personal_info` (also yields PII to optionally store, §12 Q3) and probe the earliest
   available day (e.g. widen `start_date` back in coarse windows until a daily endpoint returns empty). Default
   floor: a fixed early date (e.g. 2013-01-01, before any Oura ring shipped) so we never miss history.
2. **Fan out across endpoints** (§8.1). For each: page through `[span.start … today]` in date-windowed chunks
   (e.g. 90-day windows for summaries; shorter for `heartrate`/`sleep` to bound page size), following `next_token`.
3. **Per page:** archive raw (`ouraRaw` upsert by `(endpoint, documentId)`), then parse + accumulate normalized rows.
4. **Persist** via `OuraSyncWriter` (§8): batched upserts to `dailyMetric` / `sleepSession` / `metricSeries` /
   `hrSample` / `workout`; register the `pairedDevice`; set ring model from `ring_configuration`.
5. **Progress** is reported per endpoint (e.g. "sleep: 1,240 nights", "heartrate: 412k samples") to the UI.
6. **Completion marker:** store `last_full_sync` (epoch) in `cursors` (`oura:lastFullSync`) so a future re-pull
   is informed and the UI can show "Last imported …".

Ordering: fetch `ring_configuration` early (sets the device model), then `sleep` + daily summaries (the
dashboard's core), then `heartrate` (the largest), then the long tail (sessions/tags/rest_mode/etc.). A failure
in one endpoint is logged and skipped without aborting the whole import (honest partial — surfaced in the summary).

**Future re-pull** (out of scope to build, in scope to not preclude): the same `runFullImport` with a trailing
window + refreshed token. Idempotent because every store upsert is keyed by natural key / Oura `id`.

---

## 8. Data model & storage

### 8.1 Endpoint → storage mapping

All endpoints are archived verbatim to `ouraRaw`. The normalized columns below are the curated projection that
drives existing UI. "ref-only" = reference `metricSeries` key, never a NOOP score (G4).

| Oura endpoint | Raw | Normalized target | Notes |
|---|---|---|---|
| `personal_info` | ✓ | (optional) profile PII, local only | §12 Q3 decides storing age/sex/height/weight. |
| `ring_configuration` | ✓ | `pairedDevice.model` (hardware_type → "Oura Ring Gen3/4/…") | Sets the source's display model. |
| `sleep` (detailed) | ✓ | `sleepSession` (+ **hypnogram** → `stagesJSON`, **movement** → `motionJSON`), daily sleep rollup → `dailyMetric` | The richest object. HR series → `hrSample`; HRV series → raw + `avgHrv`. See §8.2. |
| `daily_sleep` | ✓ | `ref_sleep_score` (ref-only) + contributor keys | Score is reference. |
| `daily_readiness` | ✓ | `dailyMetric.restingHr`, `skinTempDevC`; `ref_readiness_score` + contributor keys | Mirrors `OuraExportParser`. |
| `daily_activity` | ✓ | `dailyMetric.steps`; `metricSeries` steps/active_kcal/total_kcal/met-minutes; `ref_activity_score` | `met`/`class_5_min` series → raw. |
| `daily_spo2` | ✓ | `dailyMetric.spo2Pct`; `metricSeries` spo2, bdi | |
| `daily_stress` | ✓ | `metricSeries` stress_high_s, recovery_high_s; day_summary encoded ref | Categorical summary stored ref-only. |
| `daily_resilience` | ✓ | `metricSeries` resilience contributors (0–100); `ref_resilience_level` | Level encoded 1–5 ref-only. |
| `daily_cardiovascular_age` | ✓ | `metricSeries` vascular_age, pulse_wave_velocity | |
| `vO2_max` | ✓ | `metricSeries` vo2max | (no `dailyMetric` column; `appleDaily.vo2max` is Apple-specific). |
| `sleep_time` | ✓ | `metricSeries` optimal bedtime offsets (ref) | Recommendation enum → raw. |
| `workout` | ✓ | `workout` table (sport=activity, source, durationS, energyKcal, distanceM, start/end) | |
| `session` | ✓ | `metricSeries` session counts/day; HR/HRV/motion arrays → raw | Sessions aren't workouts; normalized surface kept minimal v1. |
| `tag` / `enhanced_tag` | ✓ | raw (annotations surfaced later) | `tag` is deprecated; prefer `enhanced_tag`. |
| `rest_mode_period` | ✓ | raw | |
| `ring_battery_level` | ✓ | raw | |
| `heartrate` (time series) | ✓ | `hrSample(deviceId, ts, bpm)` | `source` enum preserved in raw. Largest payload — see §8.3. |

Reused write APIs (all already exist): `upsertDailyMetrics`, `upsertSleepSessions`, `upsertMetricSeries`
([`MetricsCache.swift` / `MetricSeriesStore.swift`]), `upsertWorkouts`
([`JournalWorkoutAppleCache.swift`]), `insert(_ streams:deviceId:)` for `hrSample`
([`StreamStore.swift`]), and `DeviceRegistryStore.add` / `setDayOwner` / `deleteAllData`.

### 8.2 Sleep hypnogram (the headline win)
- `OuraHypnogram.decode(_:)` turns `sleep_phase_5_min` (or the finer `sleep_phase_30_sec` when present) into
  `[{start,end,stage}]` segments, epoch-aligned from `bedtime_start`. Legend (verbatim): `1=deep, 2=light,
  3=REM, 4=awake` → NOOP stage strings `"deep"/"light"/"rem"/"wake"` (matching `WearableSleepStageInterval`).
  This populates `sleepSession.stagesJSON`, which the Oura **file** lane always left empty.
- `movement_30_sec` (legend `1=no motion … 4=active` — a **different** decoder) → `sleepSession.motionJSON`
  (the v18 per-epoch motion column).
- `heart_rate` `PublicSample` (interval+items+timestamp) → `hrSample` rows under `deviceId="oura-api"`.
- `hrv` `PublicSample` → archived raw + per-night `avgHrv` on the session (no good per-sample normalized home;
  `rrInterval` is RR not rMSSD — noted honestly, not faked).
- Scalar mapping (`bedtime_start/end`, `total/deep/light/rem_sleep_duration`, `awake_time`, `efficiency`,
  `average_heart_rate`, `lowest_heart_rate`, `average_hrv`, `average_breath`) reuses `OuraExportParser.sleepSession`
  semantics (durations are seconds → minutes).

### 8.3 Heart-rate volume
5-minute cadence ≈ 288 points/day (denser during workouts/sessions) → low-hundreds-of-thousands of rows over
years; `hrSample` is a compact `(deviceId, ts, bpm)` table and absorbs this fine (tens of MB). Raw `heartrate`
pages are also archived (lossless). Because raw HR roughly doubles HR storage, **raw heartrate archival is a
toggle** (default on for "as much as we can get"; off saves the most space) — §12 Q1.

### 8.4 Provenance, registry, day ownership
- New `DataSourceKind.ouraApi`; partition `deviceId = "oura-api"` (distinct from the file lane's `"oura-import"`,
  so live and file data coexist as separate sources).
- Register a `PairedDevice(id:"oura-api", brand:"Oura", model:<from ring_configuration>, sourceKind:<new
  cloud/api kind>, capabilities:[sleep,hr,hrv,spo2,skinTemp,steps,…], status:.active)` via `DeviceRegistryStore.add`.
- **Do not auto-set `dayOwnership` to `oura-api`** — WHOOP/primary stays the default owner; Oura is an additional
  comparable source the user can select. (Respects WHOOP primacy; never blends scores.)
- **Disconnect** = `DeviceRegistryStore.deleteAllData(deviceId:"oura-api")` + clear Keychain tokens + delete
  `ouraRaw` rows for the source.

### 8.5 `ouraRaw` schema (migration v19)
```
ouraRaw:
  endpoint     TEXT NOT NULL      -- "sleep" | "daily_readiness" | "heartrate" | …
  documentId   TEXT NOT NULL      -- Oura `id`; for heartrate pages, a synthesized window key
  day          TEXT               -- YYYY-MM-DD when the doc is day-keyed (nullable)
  payloadJSON  TEXT NOT NULL      -- the raw object, verbatim (JSONEncoder .sortedKeys for stable bytes)
  fetchedAt    INTEGER NOT NULL   -- unix seconds
  PRIMARY KEY (endpoint, documentId)
  INDEX (endpoint, day)
```
Additive migration only; no existing table touched. (`DATA_MODEL.md` is stale at "v9"; the live migrator is at
v18 — this is **v19**. The doc's schema table will be updated to reflect v10–v19, including `ouraRaw`.)

---

## 9. UI (iOS)

- **Data Sources screen** ([`Strand/Screens/DataSourcesView.swift`]): add an **Oura (live)** card, sibling to
  the existing wearable file-import card. Primary action **"Connect Oura & Import Everything."**
- **Connect:** runs auth (§5) then the backfill (§7) as a foreground operation with **per-endpoint progress**
  and a cancel. (One-time, foreground — no background task.)
- **Summary:** honest completion line — counts per category and date span (mirrors `WearableExportImporter.summaryText`),
  including any endpoints that were skipped/failed (never a silent "complete").
- **Membership gate:** if the API returns empty/4xx for the membership reason, show a clear, non-alarming
  message ("Oura returned no data — an active Oura Membership is required for API access") rather than a generic error.
- **Connected state:** show "Last imported <date>", a **Sync again** button (re-runs §7), and **Disconnect** (§8.4).
- The card is **off/empty until connected**; no network call happens until the user taps Connect (privacy posture).

---

## 10. Security & privacy

- **Second opt-in network lane.** Update [`docs/PRIVACY_SECURITY.md`](../../PRIVACY_SECURITY.md) §1/§4/§5 to
  document the Oura lane honestly: off-by-default, user-initiated, **inbound** (the user's own Oura data → device
  under the user's own OAuth app), tokens in Keychain, no NOOP server, raw data never exfiltrated. §4's "No
  WHOOP account or API credentials" stays true (this is Oura, the user's own grant) but the blanket "offline by
  default / one exception" framing is amended to "two opt-in exceptions: AI Coach and Oura import."
- **Token storage:** Keychain only, `kSecAttrAccessibleAfterFirstUnlock`, service `com.noop.oura`. Never logged
  (the strap-log redaction policy extends: no tokens, no `code`, no `client_secret` in any log).
- **Untrusted responses:** bounded byte reads + `WearableJSON` finite/range-checked coercion + per-collection
  caps (parity with `WearableExportImporter`).
- **iOS entitlements:** the iOS build permits outbound network (no macOS-style sandbox block); the redirect
  scheme is registered in `CFBundleURLTypes`. No new ATS exemption expected (Oura is standard TLS) — verify.
- **macOS note:** the macOS app would need the `com.apple.security.network.client` entitlement to use this lane;
  out of scope here (iOS-only), and the spec deliberately does not add it.

---

## 11. Testing

- **Pure parsers** (`StrandImportTests`, XCTest, inline-JSON fixtures like `WearableExportImporterTests`):
  `OuraApiParser` per endpoint; `OuraHypnogram.decode` round-trips (`sleep_phase_5_min`/`30_sec` legends,
  epoch alignment, the distinct `movement_30_sec` legend); honest-data assertions (Oura scores land only on
  `ref_*` keys, never `recovery`/`strain`).
- **Client** (app-target tests): a `URLProtocol` stub feeds canned responses — paging via `next_token`, 429
  backoff, 401-refresh-once, bounded-bytes, prod/sandbox base URL.
- **Writer/integration:** in-memory `WhoopStore.inMemory()` → assert `dailyMetric`/`sleepSession`(+stages)/
  `hrSample`/`metricSeries`/`workout` rows and `pairedDevice` registration; assert day-ownership is **not**
  seized from WHOOP.
- **Live smoke (manual/dev):** point the client at the `/v2/sandbox/...` tree (no account) to exercise the real
  envelope/paging end-to-end.

---

## 12. Open questions for your review

- **Q1 — Raw heart-rate archival.** Default **on** (true lossless) but it roughly doubles HR storage. OK to
  default on with a toggle, or default off (still keep normalized `hrSample`)?
- **Q2 — Credentials UX.** Default is an untracked **xcconfig** (no UI to build, best for one-time/personal). Want
  a small **paste-credentials screen** instead so any user can connect without rebuilding? (Larger scope.)
- **Q3 — `personal_info` PII.** Store age/sex/height/weight locally (useful for some scores), or archive raw only?
- **Q4 — Module placement.** Pure parsers in **`StrandImport`** (max reuse, recommended) vs. a new pure package
  **`StrandOura`** (cleaner home, more scaffolding). This refines the earlier "new networked module" framing:
  networking is in the app target regardless; only the parser home is in question.

---

## 13. Out of scope

Background sync, webhooks, incremental "changed-since" diffing, a backend/token-proxy, OAuth-for-all-users
(BYO-app only for now), macOS, Android, and any change to NOOP's scoring math. All are reachable later behind
the `AuthProvider` seam and the idempotent store upserts without reworking this lane.

---

## 14. Touched files (high level — detailed steps come in the implementation plan)

**New (app target `Strand/Oura/`):** `OuraCredentials.swift`, `OuraAuth.swift` (`AuthProvider` + `OuraOAuthProvider`),
`OuraTokenStore.swift`, `OuraAPIClient.swift`, `OuraEnvironment.swift`, `OuraSyncCoordinator.swift`, `OuraSyncWriter.swift`,
+ small SwiftUI views for the card/progress/summary.
**New (package `StrandImport`):** `OuraApiParser.swift`, `OuraHypnogram.swift`, rich API model types (+ tests).
**Edited:** `Packages/WhoopStore/.../Database.swift` (migration **v19** `ouraRaw`) + a small `OuraRawStore.swift`;
`Packages/StrandImport/.../ImportModels.swift` (`DataSourceKind.ouraApi`); `Strand/Screens/DataSourcesView.swift`
(Oura card + flow); `project.yml` (xcconfig ref + `CFBundleURLTypes`); `.gitignore` (`OuraSecrets.xcconfig`);
docs: `PRIVACY_SECURITY.md`, `DEVICE_SUPPORT_ROADMAP.md` (Oura row → "in progress"), `DATA_MODEL.md` (v10–v19 incl. `ouraRaw`).
