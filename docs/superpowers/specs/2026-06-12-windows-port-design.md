# NOOP for Windows — Design & Implementation Plan

**Status:** Design (2026-06-12). NOOP for Windows is **not built**. This is the blueprint, grounded in
a 4-track architecture study. It cannot be built or BLE-tested from a macOS machine — see "Build &
test reality."

**Goal:** A Windows desktop NOOP with the same functionality and the same design language as the macOS
app: pair a WHOOP strap over Bluetooth, store everything on-device, compute recovery/strain/HRV/sleep
locally, import WHOOP CSV + Apple Health, the AI Coach — all offline, no account, no cloud.

**Hard constraints:** (1) **Anonymous** — no paid code-signing certificate, no Microsoft Store account
(both attach identity); (2) **maintainable by one Mac-based person**; (3) **BLE to a WHOOP strap is
mandatory** (GATT central: scan, connect, **bond**, subscribe notifications, write commands).

---

## The decision

> **Primary path: Compose Multiplatform Desktop (Kotlin) — gated on a Bluetooth spike.**
> **Fallback if the BLE spike fails: .NET 8 + Avalonia with native WinRT Bluetooth.**

Why, in one paragraph: the **Android app is already a Kotlin/Compose twin** of NOOP — the protocol
decoder (incl. the v25 work), the recovery/strain/HRV/sleep analytics, the data layer, and the *screens
themselves* are Compose. Compose Multiplatform Desktop runs that same Kotlin/Compose code on the JVM on
Windows, and **the entire app — UI, analytics, data — builds and iterates from the Mac** (`./gradlew
run`). No third reimplementation of the reverse-engineered crown jewels, and the design language matches
because it *is* the Android UI (which already mirrors macOS). The only greenfield piece — and the only
real risk — is **Bluetooth**, because the Android BLE layer (`android.bluetooth.*`) does not port to
desktop. So the plan front-loads a hard, time-boxed BLE spike before committing.

### Why not the others

| Option | Verdict |
|---|---|
| **Compose MP Desktop (Kotlin)** ✅ | Best reuse by far (the Kotlin twin already exists), builds + iterates from the Mac, UI matches. **Risk: desktop BLE (btleplug/JVM) is the one unproven piece.** |
| **Swift-on-Windows** ❌ | Reuses the pure-Foundation Swift packages (`WhoopProtocol`, `StrandAnalytics`) — but **SwiftUI doesn't exist on Windows** (0% UI reuse), and worst of all **Swift-on-Windows cannot be built from a Mac** (needs the MSVC toolchain), with **no prior art for GATT-central over swift-winrt**. Highest risk, can't dev from Mac. |
| **.NET 8 + Avalonia (C#)** 🟡 (fallback) | **Cleanest BLE** — native WinRT `Windows.Devices.Bluetooth` is the mature first-party path. Builds from Mac. **But it's a third codebase**: a full C# re-port of the protocol + analytics + a full Avalonia rebuild of all ~25 screens. Most work, no reuse. |

The spike must validate the Windows BLE connection and security workflow on the target strap.

---

## Architecture (primary path: Compose MP Desktop)

```
windows/  (new Gradle module, or a desktopMain source set in a Kotlin Multiplatform restructure)
├── shared Kotlin (REUSED from android/app, moved to a commonMain/jvmMain shared module):
│   ├── com.noop.protocol   ── BLE framing/CRC/decode incl. v25  ── reuses ~100%, pure Kotlin
│   ├── com.noop.analytics  ── recovery/strain/HRV/sleep math     ── reuses ~100%, pure Kotlin
│   ├── com.noop.ingest     ── WHOOP CSV + Apple Health importers ── reuses (drop Health Connect, Android-only)
│   └── com.noop.ui (Compose) ── the screens                       ── reuses with adaptation (window vs phone, no Android nav)
├── data:  Room → SQLDelight (JVM)   ── Room is Android-only; SQLDelight gives the same schema on JVM/Windows
├── ble:   NEW — WindowsBleClient    ── the from-scratch piece (see below)
└── app:   Compose Desktop window + tray, wires it together
```

- **Protocol + analytics + importers:** lift `com.noop.protocol`, `com.noop.analytics`, the pure parts
  of `com.noop.ingest` into a shared module. They're plain Kotlin/Foundation-free — they compile on the
  JVM unchanged. This is the whole reason to choose this path.
- **Data:** the Android app uses **Room** (Android-only). Swap to **SQLDelight** for the JVM target — same
  SQL schema, generates typed Kotlin. (Or bundle the SQLite JDBC driver.) One-time port of the DAO layer.
- **UI:** the Compose screens reuse, adapted for a **resizable desktop window** instead of a phone (the
  Android bottom-nav becomes a sidebar like macOS; remove Android-specific widgets/Glance/foreground-service
  UI). This is moderate adaptation, not a rebuild — and it lands the macOS design language via the Android port.
- **BLE — `WindowsBleClient` (the new + risky part):** mirror the `WhoopBleClient` *interface* (connect /
  bond / subscribe char-05 / write commands / the realtime + historical-offload state machines — all of
  which are platform-agnostic and live above the transport) but implement the transport against **btleplug
  via JNI**, or a thin native WinRT bridge. Everything *above* the raw GATT transport (the handshake, the
  v25 decode, the Backfiller, the retro-decode) is already written and reuses.

### AI Coach
Reuses directly — `com.noop.ai.AiCoach` is plain Kotlin + OkHttp (BYOK to Anthropic/OpenAI/local LLM).
No change.

---

## The Bluetooth spike (do this FIRST — it's the go/no-go)

Before any UI or porting work, prove the transport on real hardware:

1. A throwaway Kotlin/JVM console app on **Windows** that uses **btleplug-jni** (or a minimal WinRT bridge)
   to: scan → find a WHOOP strap by service UUID → connect → **bond/encrypt** → subscribe the notify
   characteristic → write `GET_BATTERY_LEVEL` → confirm a notification comes back.
2. **Success criteria:** a real WHOOP 4.0 answers over an encrypted link from a Windows JVM process.
3. **If it passes:** proceed with Compose MP Desktop — the rest is reuse + adaptation.
4. **If it fails** (bonding/encryption won't establish from JVM): switch to **.NET 8 + Avalonia**, where
   native WinRT GATT is proven, and accept the full C# re-port + Avalonia UI rebuild.

Bonding is the specific thing to prove — WHOOP's proprietary service requires an encrypted link, and that's
where JVM-level BLE libraries are weakest.

---

## Build & test reality (state this plainly)

- **Dev + build + UI + analytics:** fully doable **on the Mac** — Compose Desktop is JVM/Gradle; `./gradlew
  run` launches the desktop app on macOS, and every screen + all the analytics/decoder logic iterate and
  unit-test there. This is the decisive advantage over Swift-on-Windows (which can't build from a Mac at all).
- **BLE:** **requires a real Windows machine (or a Windows VM with a USB-passthrough Bluetooth radio) next
  to a WHOOP strap.** BLE cannot be meaningfully tested in CI or in a UI-only run. There is no way around a
  Windows box for the one part that talks to hardware.
- **Packaging the `.exe`/installer:** Compose Desktop's `packageReleaseDistributionForCurrentOS` /
  jpackage targets must run on Windows to produce the Windows artifact. So: a Windows machine or a cloud
  Windows CI runner is needed to cut the actual Windows release (the Mac produces nothing Windows-runnable).

**Bottom line for a one-person Mac maintainer:** you can write ~90% of this on the Mac, but you need a
Windows box (physical, VM, or CI runner) for BLE testing and for cutting the release. That's the real
ongoing cost, and it's unavoidable for *any* Windows port that does Bluetooth.

---

## Anonymity & distribution (clears cleanly — same model as macOS/Android)

- Ship an **unsigned, portable** Windows artifact (a `.zip` of a self-contained build, or an unsigned
  installer) from **GitHub Releases** — exactly the no-store, no-cert, no-identity model NOOP already uses.
  **No Microsoft Store account, no paid Authenticode cert** — both would attach a real identity.
- **Anonymize the binary** with a Windows twin of `anonymize-macos-app.sh` / `anonymize-ios-app.sh`: scrub
  the builder's home path out of every binary in the bundle before zipping (JVM apps embed fewer such
  paths than native, but verify → 0). Same discipline.
- **SmartScreen reality (document it like the Gatekeeper/Play-Protect notes):** an unsigned exe from an
  "unknown publisher" triggers a SmartScreen warning → **More info → Run anyway**. Honest, one-time, the
  Windows equivalent of macOS right-click-Open.

---

## Phased implementation plan

1. **BLE spike (go/no-go)** — btleplug-via-JNI scan→connect→bond→subscribe→write to a real strap on Windows.
   *Gate the whole project on this.*
2. **Shared-module extraction** — move `com.noop.protocol` / `analytics` / pure `ingest` into a Kotlin
   shared module that builds for both Android and JVM. Unit tests (already exist) run on the Mac. No behaviour change to Android.
3. **Data port** — Room DAOs → SQLDelight (JVM). Verify schema parity against the Android DB.
4. **`WindowsBleClient`** — implement the transport from the spike; reuse the platform-agnostic handshake /
   Backfiller / decode / retro-decode above it.
5. **Compose Desktop shell + UI adaptation** — desktop window, sidebar nav, reuse the screens; iterate on the Mac.
6. **Importers + AI Coach** — wire CSV/Apple-Health import + the Coach (both reuse).
7. **Package + anonymize + SmartScreen docs** — `anonymize-windows-app` + unsigned zip; needs a Windows box.
8. **Hardware validation on Windows** — the real test; recruit a Windows + 4.0 tester (we already have
   community volunteers asking for more platforms).
9. **Docs/wiki** — flip Windows from "in design" to "available" only after step 8 passes.

---

## What this is honest about

- It is a **plan, not a build.** I cannot compile or BLE-test Windows from this Mac.
- **BLE is the single point of failure** and is unproven for the preferred (reuse-maximising) path — hence
  the spike-first gate and the named fallback.
- A **Windows machine is unavoidable** for testing + releasing, even though ~90% of the work happens on the Mac.
- Everything else — code reuse, anonymous distribution, the UI matching macOS — clears cleanly.
