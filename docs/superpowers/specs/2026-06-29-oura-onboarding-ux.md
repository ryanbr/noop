# NOOP Local Oura Support - Factory-Reset-and-Adopt

READ-ONLY design pass. This is the user-facing design for NOOP owning an Oura ring locally over BLE, in NOOP's existing Apple-Fitness x WHOOP language. It supersedes today's "honest dead-end" Oura path (`Strand/BLE/OuraProbeSource.swift`, wizard `.oura` case in `AddDeviceWizard.swift`) with a real, opt-in adoption flow for users who are intentionally leaving Oura.

No em-dashes in any user-facing copy below (verified). All copy reads in NOOP's anonymous, no-AI voice.

---

## 0. Clean-room protocol facts (cited, FACTS ONLY)

NOOP's adoption path stands on documented Oura BLE behaviour. We reimplement; we copy no source. Facts used by this design:

- **Oura advertises as a standard BLE peripheral**; NOOP already recognises it by advertised-name substring `"oura"` (`Strand/BLE/ExperimentalBrand.swift`, `recognise(name:)` returns `.oura`). FACT confirmed in-repo.
- **Gen 3 vs Gen 4/5 use different transports.** Gen 3 exposes a Nordic-UART-style GATT pair for command/response framing; Gen 4 (and the same-family newer ring) moved to a revised characteristic set and a different bond/key requirement (per the open Oura-RE notes, e.g. the `oura-re` / `open_ring` PROTOCOL writeups: "Gen 3 = UART service, Gen 4 = new service UUID + per-ring key"). We DETECT the gen by which GATT services enumerate, never by trusting the name. FACT (protocol layout) per open Oura-RE PROTOCOL docs.
- **The ring is owned by a 16-byte key installed at setup.** The official Oura app provisions this key during onboarding; the ring will only answer authenticated commands from the holder of that key (per open_ring PROTOCOL notes on the setup/auth handshake). FACT (auth model) per open_ring PROTOCOL docs.
- **Factory reset returns the ring to an unprovisioned state** in which a new owner can install their own key (per the same RE setup notes: reset clears the installed key so the next setup claims it). This is the mechanism NOOP uses: the user resets in the Oura app, then NOOP installs ITS key and becomes the sole owner. FACT (reset semantics) per open_ring PROTOCOL docs.
- **One-owner constraint.** The ring answers one key at a time, so once NOOP owns it the official Oura app can no longer drive it. This is the same single-link reality NOOP already warns about for WHOOP (`AddDeviceWizard.swift` `singleConnectionWarning`). FACT (single-owner) per open_ring PROTOCOL docs + mirrors WHOOP A6.
- **Available live/decoded metrics off an owned ring:** live heart rate, raw PPG/IR for HR + a derived HRV (rMSSD) under suitable conditions, motion (steps as a raw motion count), skin-temperature deviation, and battery, with sleep staging derived on-device from the offloaded overnight record. Higher-level "readiness" is Oura's own proprietary derived score and is NOT recovered; NOOP computes its own Charge instead. FACT set per open Oura-RE metric notes; absolute SpO2 % is NOT decoded.
- **Export-file shapes** (the Advanced/import lane and the per-day rollups this screen reuses) are NOOP's own parser, `Packages/StrandImport/Sources/StrandImport/OuraExportParser.swift`: sleep periods (durations not a hypnogram), `daily_readiness` (RHR, `temperature_deviation`, reference score), `daily_sleep` (reference score), `daily_activity` (steps, calories). FACT confirmed in-repo.

Every fact above is read-for-protocol-only; the NOOP driver, key install, decode and UI are original.

---

## 1. Reused components (so this is buildable, not new chrome)

| Need | Existing component | Source |
| --- | --- | --- |
| Screen frame + title/subtitle + pull-to-refresh | `ScreenScaffold` | `Strand/Screens/ScreenScaffold.swift` |
| Wizard step container, header, back/close, frosted rows | `AddDeviceWizard` (`typeRow`, `prepStep`, `pickStep`, `confirmStep`) | `AddDeviceWizard.swift` |
| Device list card | `DeviceCard` + `DeviceCapabilityProfile.make(for:)` | `DevicesView.swift` |
| Status chip (Active/Paired/Beta/Searching) | `StatePill` (tones: positive/accent/warning/neutral) | `StatePill.swift` |
| Live/pulse dot | `ConnectionDot(pulsing:)` | `StatePill.swift` |
| Signal strength | `SignalBars(rssi:)` | `DevicesView.swift` |
| Card surface | `StrandCard` / `.frostedCardSurface(tint:cornerRadius:)` | `StrandCard.swift` |
| Amber heads-up panel | the `experimentalTierNote` / `singleConnectionWarning` pattern (statusWarning at 0.10 fill) | `AddDeviceWizard.swift` |
| Metric tiles + charts on the device's own screen | `StatTile`, `ChartCard`, `TrendChart`, `Hypnogram`, `SegmentedPillControl` | `Components.swift`, `XiaomiBandView.swift` (the template to copy) |
| Per-device page template | `XiaomiBandView` (range control, tile grid, chart cards, hypnogram) | `XiaomiBandView.swift` |
| Empty/pending states | `ComingSoon`, `DataPendingNote`, `SyncingHistoryNote` | `ScreenScaffold.swift` |
| Primary buttons | `NoopButton` / `.buttonStyle(.borderedProminent).tint(StrandPalette.accent)` | `NoopButton.swift` |

Design tokens used (no hardcoded values): `StrandPalette.accent` (#60A0E0 dark / #234F9E light), `.statusWarning` (amber heads-up), `.statusCritical` (the irreversible warning), `.statusPositive` (Active/Live), `.metricRose/.metricPurple/.metricCyan/.metricAmber` (chart worlds), `NoopMetrics.gap/sectionSpacing/cardRadius/tileHeight/chartHeight`.

A new **`oura` family** is added to the registry alongside `.huami/.ftms/.liveBLE`: `sourceKind == .ouraOwned`. The card icon is `circle.circle` (already the wizard's Oura glyph), tinted accent when active.

---

## 2. SCREEN-BY-SCREEN: "Add your Oura ring" (Factory-Reset-and-Adopt)

Entry: **Devices → Add a device → Experimental → Oura ring**. The type row copy changes from today's dead-end wording to:

> **Oura ring**
> Take over your ring locally. Beta. This replaces the Oura app.

The wizard keeps its existing 4-step skeleton (`type → prep → pick → confirm`) plus two Oura-only inserts: a **What you get / what you lose** gate before scan, and an **Adopt** step that installs NOOP's key. Header uses the existing `header` (chevron back, title, xmark close).

### Step A - Type picked → the honest gate ("This replaces Oura")

Header: `Oura ring` · subtitle `Take it over locally. Beta.`

Top: a **Beta** banner using the amber `experimentalTierNote` pattern.

> **Beta. Read this first.**
> Local Oura support is new and we cannot test every ring here. It may not connect on your ring, and it can change between updates. NOOP never makes up a number. If something does not work, it will tell you plainly.

Below it, a single `StrandCard` split into two columns titled with `.strandOverline()`:

**WHAT YOU GET**
- Your ring talks to NOOP only, fully offline, no Oura account.
- Live heart rate, and HRV when the ring can measure it.
- Overnight sleep staging, resting heart rate, skin-temperature trend, motion and battery, read straight off the ring.
- NOOP's own Charge, Effort and Rest, computed on your device from published methods.

**WHAT YOU LOSE**
- The Oura app and your Oura account stop working with this ring. This is the point. You are replacing Oura.
- Oura's own Readiness and Sleep scores. NOOP does not copy them. It computes its own.
- Anything that needs Oura's cloud (web dashboard, Oura's coaching, shared circles).
- Likely your Oura warranty and support, because the ring is no longer paired to Oura. Treat this as permanent.

Then the **irreversible** line, styled `statusCritical` (red), with a checkbox the user must tick to continue:

> [ ] I understand this disconnects the ring from Oura and that NOOP cannot undo it for me. To go back to Oura I would factory-reset the ring again and set it up in the Oura app.

Two buttons:
- Primary (disabled until the box is ticked): **Continue** → Step B.
- Secondary, plain accent text: **Keep the Oura app instead (import a file)** → routes to the existing file-import lane (the honest, non-destructive path stays one tap away).
- Tertiary, plain accent text, small: **Advanced: I already have my ring's key** → Step B-Alt (power-user import-key path, section 2.1).

### Step B - Prep: factory-reset in the Oura app

Header: `Get your ring ready` · subtitle `Reset it in the Oura app first.`

Reuse the `prepStep` checklist style (accent `checkmark.circle.fill` rows) inside a frosted card:

1. Open the official Oura app and remove this ring (Oura calls it "factory reset" or "unpair and reset"). This wipes the ring's owner so NOOP can take it over.
2. Keep the ring on the charger or on your finger so it stays awake.
3. Make sure the Oura app is fully closed. A ring answers one owner at a time.
4. When the ring is reset and waking, tap Scan below.

Amber `singleConnectionWarning`-style card:

> **A ring talks to one owner at a time.**
> If the Oura app is still running it will hold the ring and adoption will fail. Force-quit Oura, then scan.

Button: **Scan for your ring** (`.borderedProminent`, accent, icon `dot.radiowaves.left.and.right`). → Step C.

### Step C - Pick the ring (live scan)

Reuses the `OuraPickList` shape but now selecting a ring proceeds to adopt rather than dead-ending. Top: `ScanStatusBar` ("Searching..." accent pulse + Rescan). While empty: `SearchingCard` with Oura-specific hint:

> Not showing up? Make sure you reset the ring in the Oura app and force-quit it, then tap Rescan. A ring still owned by Oura will not list here.

Each found ring is a `DiscoveredRow`: `SignalBars(rssi:)`, name (advertised, e.g. "Oura"), subtitle = the **detected generation** (see section 3), chevron. Tapping → Step D.

If a ring is detected but is **still owned by Oura** (enumerates but rejects the unprovisioned check), its row shows a neutral `StatePill("Still paired to Oura", tone: .warning)` and tapping opens an inline note: "This ring is still set up with Oura. Reset it in the Oura app first, then Rescan."

### Step D - Detect generation + confirm

Header: `Your ring` · no subtitle.

A frosted card identifies the ring (section 3): the correct **ring image/glyph**, the **gen name** ("Oura Ring Gen 3" / "Oura Ring 4" / "Oura Ring (newer)"), and the **per-gen capability list** rendered as a compact, honest checklist (✓ supported, dash for not-available, with a one-line caveat). A `StatePill("Beta", tone: .warning, showsDot: false)` sits top-right.

If the detected gen is **not supported yet** (section 4), this becomes the not-supported state instead of an adopt button.

Below: a name field (the existing `confirmStep` text field, prefilled "Oura ring"), then the **Adopt** action:

Button (red-tinted to signal weight, using `.statusCritical` border on a prominent accent fill, or accent with a critical underline): **Take over this ring**. Tapping shows a final system `.alert` (matching the destructive-confirm pattern in `DevicesView`):

> **Take over this ring?**
> NOOP will install its own key on the ring and become its owner. The Oura app will no longer control this ring. This is intended and it cannot be undone from NOOP.
> [Cancel] [Take over]

### Step E - Adopting (key install) progress

Full-card progress state (reuse `DataPendingNote` + a pulsing `ConnectionDot`):

> **Taking over your ring...**
> Installing NOOP's key and confirming the ring answers only to NOOP. Keep the ring close and do not open the Oura app.

Honest sub-states (each a single line that replaces the last, no fake percent, mirroring `SyncingHistoryNote`'s "live signal not a percent" rule):
- "Confirming the ring is reset and ready..."
- "Installing NOOP's key..."
- "Checking the ring now answers only NOOP..."
- "Reading first heartbeat..." → success.

**Success** → register a `PairedDevice(sourceKind: .ouraOwned, capabilities: per-gen)`, then the existing `askMakeActive` alert: "Make Oura ring your active device now? It will provide your live data." → close to the Devices list, new card present.

**Failure** (any sub-state) → honest dead-end card, never a fabricated success:
> **We could not take over this ring.**
> The most common cause is the ring was not fully reset in the Oura app, or the Oura app is still running. Reset the ring again, force-quit Oura, then try once more. If it keeps failing, your ring may be a generation NOOP cannot adopt yet. You can still use file import.
> [Try again] [Use file import]

### 2.1 ADVANCED path (B-Alt): import a 16-byte key (keep the Oura app)

Reached only via the small "Advanced: I already have my ring's key" link on the gate. Clearly fenced as power-user.

Header: `Advanced: use your own key` · subtitle `Power users only.`

Amber heads-up:
> **For power users.**
> If you extracted your ring's 16-byte key from a previous Oura setup, NOOP can talk to the ring with that key WITHOUT resetting it, so the Oura app keeps working too. NOOP does not extract keys for you and cannot help you find one. If you do not know what this means, go back and use the standard setup or file import.

A monospace key field with paste support:
- Label `.strandOverline()`: **RING KEY (32 hex characters)**
- `TextField` styled like `confirmStep`'s, validates 16 bytes / 32 hex chars; inline red helper on bad input: "That is not a 32-character hex key."
- Helper line: "NOOP stores this key only on this device, in the same place it stores your paired bands."

Then Scan (Step C) → on pick, NOOP authenticates with the supplied key (no key install, no reset). Confirm step omits the "this replaces Oura" destructive copy and instead notes: "Both NOOP and the Oura app can use a ring you own by key, but only one can hold the Bluetooth link at a time."

Capability and screen treatment from here on are identical to the adopted ring.

---

## 3. RING-TYPE DIFFERENTIATION (Gen 3 / 4 / newer)

**Detection (never trust the name):** on connect during Step C/D, NOOP enumerates GATT services and classifies by which service set is present (per the open Oura-RE PROTOCOL layout: Gen 3 = UART-style command/response services; Gen 4 family = the revised service UUID + per-ring key requirement). The advertised name `"oura"` only gates that it is an Oura ring (`ExperimentalBrand.recognise`); the **generation** comes from the service fingerprint. Result is one of: `gen3`, `gen4`, `newer` (Gen 4 service family but an unrecognised firmware/variant), or `unknown` (Oura name, no recognised service set → treat as not-supported, section 4).

Each gen maps to its own **name + image + capability list**:

- **Oura Ring Gen 3** - glyph `circle.circle`, image asset `oura-gen3`. Subtitle in pick row: "Gen 3".
- **Oura Ring 4** - image asset `oura-gen4`. Subtitle: "Ring 4".
- **Oura Ring (newer)** - image asset `oura-gen-generic`. Subtitle: "Newer ring". Carries an extra caveat line that decoding is least proven here.

### Capability matrix per generation

Verdicts are honest and source-gated: ✓ = decoded and used; ~ = best-effort / estimate (carries a `*`, same convention as `DeviceCapabilityProfile`); dash = not available off the ring (use file import if you need it); a `*` footnote explains each estimate. This is exactly the `DeviceCapabilityProfile.captures/powers/footnote` model, extended for Oura.

| Capability | Gen 3 | Ring 4 | Newer (Gen 4 family, unverified) | Notes |
| --- | --- | --- | --- | --- |
| Live heart rate | ✓ | ✓ | ~ | Standard live HR off the owned ring. |
| HRV (rMSSD) | ~ | ~ | ~ | Derived from beat-to-beat under still conditions, labelled `*`. |
| Resting heart rate | ✓ | ✓ | ~ | From the overnight record. |
| Sleep staging (hypnogram) | ✓ | ✓ | ~ | Staged on-device from the offloaded night, drawn with the shared `Hypnogram`. |
| Skin-temperature trend | ~ | ~ | ~ | Deviation from your baseline (`+0.3 C vs normal`), `REL.`/`*`, never a clinical absolute. |
| Steps / motion | ~ | ~ | ~ | Raw motion count, `*`, same honesty as WHOOP 5 steps. |
| Battery | ✓ | ✓ | ~ | Surfaced on the card like any active device. |
| Blood oxygen (SpO2 %) | dash | dash | dash | No absolute % is decoded off the ring. File import only. |
| Oura Readiness / Sleep score | dash | dash | dash | Oura-proprietary. NOOP computes its own Charge instead. |
| Powers NOOP scores | Charge, Effort, Rest, Sleep | Charge, Effort, Rest, Sleep | Effort live now; Charge/Rest once enough nights and decode is confirmed | Charge needs the overnight record + a baseline (the existing calibrating-countdown applies). |

Card footnote copy (per gen, via `DeviceCapabilityProfile.make`): `"Beta. * is an on-device estimate. Skin temp is a trend versus your own baseline, steps are a raw motion count, and HRV needs you to be still. No Oura Readiness or SpO2 percentage comes off the ring (import an Oura file for those)."`

---

## 4. STATES: empty / needs-pairing / not-supported / Beta disclosure

### Devices-list card (the row in `DevicesView`)

A new `DeviceCapabilityProfile` branch for `sourceKind == .ouraOwned` so the card renders honestly per gen. The card carries, in the existing `DeviceCard` layout:

- Icon `circle.circle`, tinted accent when active.
- Title = nickname or "Oura ring"; subtitle = gen name ("Oura Ring Gen 3").
- A **Beta** chip beside the state pill: `StatePill("Beta", tone: .warning, showsDot: false)`.
- State pill: `Active · Live` (positive, pulsing) when active+connected, `Active`, `Paired`, or `Removed` exactly as other devices.
- `capabilityRow(waveform.path.ecg, captures)` and `capabilityRow(bolt.fill, powers)` per the matrix.
- Last-seen line + live battery (`liveBatteryPct`) reusing the existing battery glyph buckets.
- Footnote = the per-gen beta caveat above.

So one paired ring reads, e.g.:
> ⌾ Oura ring - Oura Ring Gen 3   [Beta] [Active · Live]
> ◷ Heart rate · HRV* · Sleep · Resting HR · Skin temp* · Steps* · Battery
> ⚡ Powers Charge, Effort, Rest and Sleep
> Beta. * is an on-device estimate. No Oura Readiness or SpO2 % off the ring (import a file for those).
> Connected now · 71%      ⋯

### Empty state (no Oura ring paired, Oura screen reached directly)

Reuse `ComingSoon`:
> **Coming together**
> No Oura ring yet. Add one in Devices to take it over locally, or bring your Oura history in from a file in Data Sources. Live takeover is in beta.

### Needs-pairing / lost-link state

When an adopted ring is paired but not currently connected, the card's last-seen line reads `Last seen 3 h ago`, pill `Paired`. If NOOP holds the key but the ring will not answer (e.g. it was reset again, or re-claimed):
> `StatePill("Not answering", tone: .warning)` + inline: "This ring is not responding to NOOP's key. If you reset it or set it up in the Oura app again, NOOP no longer owns it. Re-add it to take it over."

### Not-supported-gen state (Step D variant)

When detection returns `unknown` (Oura name, no recognised service set) or a Gen 4 firmware NOOP has not validated:
> **We can see your ring, but we cannot take it over yet.**
> This looks like an Oura ring NOOP does not support for live takeover yet (we keep adding rings as we verify them in beta). Your data is not stuck: use Oura's Account → Export Data and bring it into NOOP with file import, fully offline.
> [Use file import] [Tell us your ring model]  (the second opens the Issues link, matching the experimental-tier "help us test" voice)

### Beta disclosure copy (canonical, reused verbatim across wizard gate, card footnote, wiki)

> Local Oura support is beta. NOOP installs its own key on a factory-reset ring and becomes its owner, which is why the Oura app stops working with it. That is intended: you are replacing Oura. NOOP reads heart rate, HRV when it can, sleep, resting heart rate, a skin-temperature trend, motion and battery straight off the ring, fully offline, and computes its own Charge, Effort and Rest. It does not recover Oura's Readiness score or an SpO2 percentage. It never shows a number it did not measure. Taking over a ring cannot be undone from NOOP, and it likely ends your Oura warranty, so do it only if you mean to leave Oura.

---

## 5. The adopted ring's own screen (per-source page)

Built by copying `XiaomiBandView` (the established per-source template): `ScreenScaffold(title: "Oura ring", subtitle: span)`, a `SegmentedPillControl` range control (W/M/3M/6M/1Y/ALL), a `LazyVGrid` of `StatTile`s, then `ChartCard` sections, plus the `Hypnogram` "Last sleep" section. Source partition key `"oura-owned"`.

- Tiles: Resting HR (rose), HRV* (accent), Sleep avg (purple), Skin temp trend* (amber, shown as `+0.3 C`), Steps* (cyan), Battery.
- Chart sections: **Heart & Vitals** (resting HR, HRV*), **Sleep** (time asleep, deep, REM, + the live-staged hypnogram), **Activity** (steps*), **Body** (skin-temp deviation*).
- A persistent **Beta** chip in the header (`StatePill("Beta", tone: .warning, showsDot: false)`), and the canonical beta line as the screen's footer note.
- Same sparse-data widening behaviour as `XiaomiBandView` (a new ring with one night auto-widens its range rather than showing empties).

---

## 6. Anonymity / voice / safety checks

- No em-dashes in any user-facing string above (uses commas, periods, parentheses).
- Voice matches the existing honest, US-neutral wizard copy ("It will tell you plainly", "It never shows a number it did not measure"), no AI mention anywhere.
- Mirrors NOOP's established honesty rules: estimates carry `*`, calibrating uses the countdown pattern (A4), skin temp is `REL.` (A5), the single-owner warning reuses the WHOOP A6 pattern. The destructive "this replaces Oura" gate is the new, Oura-specific honesty surface.
- The non-destructive file-import lane and the Advanced keep-your-key lane are both always one tap away, so the destructive takeover is never the only door.
