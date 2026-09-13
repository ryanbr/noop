# Scope & non-goals

NOOP exists to give you **your own strap data, offline and on-device**. That mission sets hard limits
on what belongs in the app. This page names the WHOOP-app features that stay **out of scope** — and the
local equivalents that stay **in scope** — so a parity proposal has a standing answer before a PR is
opened. It does not change the constraints stated in [CLAUDE.md](../CLAUDE.md), the
[Contributing guide](CONTRIBUTING.md), or the [Disclaimer](../DISCLAIMER.md); it maps them onto specific
features so the boundary is discoverable.

## The constraints this follows from

NOOP is **offline-first, on-device, and anonymous**: no NOOP-operated server, no account, no cloud
dependency, no telemetry, and **not a medical device** (see the
[Disclaimer](../DISCLAIMER.md#5-not-a-medical-device)). Those are hard constraints, not preferences.
The one explicit network-export exception is the default-off Experimental self-hosted push described
below. Everything else on this page is a consequence of these constraints, not a separate rule.

## Out of scope

These map to features visible in WHOOP-app reverse-engineering, but they conflict with the constraints
above. They are out of scope **unless the project deliberately changes its scope** in a tracked issue.

| Feature (WHOOP parity) | Why it's out of scope | Ref |
|---|---|---|
| Possible-arrhythmia / diagnostic-style alerts | A medical-device-style claim. NOOP is explicitly **not a medical device** and must not tell a user they may have a health condition. | #752 |
| Community feeds, team chat, social graph, leaderboards, cloud messaging | Require a **server, accounts, and an identity** — the opposite of anonymous and offline. | #755 |
| Cloud- or account-dependent coaching / notification parity | Requires cloud identity and server sync. NOOP's coach is strictly bring-your-own-key and on-device. | — |
| Anything requiring telemetry, an app-dependent/hosted server sync, user identity, or medical claims | Fails a hard constraint directly. The default-off self-hosted export below is the narrow exception: NOOP never depends on its receiver. | — |

## In scope — the local, non-diagnostic equivalents

The point of a boundary is to say what *is* welcome. These stay in scope because they run entirely
on-device from NOOP's own data and make no medical claim.

- **Local rhythm instrumentation.** Surfacing RR/IBI or beat-to-beat variability for the user's own
  curiosity is fine **only** as **default-off instrumentation** with explicit **non-diagnostic** wording
  — never an alert, never a health warning, never "possible arrhythmia" language, and never feeding a
  downstream gate. This mirrors the physiological-signal rule in
  [CLAUDE.md](../CLAUDE.md): an unproven derivation lands as instrumentation, not a shipped feature.
- **Local notifications from NOOP's own metrics** — charge, alarm, sync state — computed on-device.
- **Local export / import / reporting** — your data leaves only when *you* export it, including the
  explicit, default-off standing export described below.
- **Offline insights and explainers** that need no cloud identity.

## Experimental exception — self-hosted one-way push

Issue #1314 deliberately changed the scope for one narrow export path. NOOP may offer a
**default-off Experimental** client that sends incremental data to an HTTP(S) endpoint the user owns
and configures. It remains in scope only while all of these boundaries hold:

- With no endpoint configured, it never runs: no network egress and no change to current battery,
  screens, scores, or local behaviour.
- It runs in an independent background job after a successful strap offload. Receiver latency,
  failure, or misconfiguration must never delay or interfere with the strap sync path.
- It only exports rows. NOOP does not fetch rows, commands, settings, URLs, schemas, or conflict
  decisions from the receiver; the local on-device database remains the sole authority. The receiver
  may advertise only a subset of the client's fixed versioned stream registry so unsupported data is
  not read or sent.
- Identity is local to the installation and device. There is no NOOP account, hosted service,
  third-party destination, or telemetry channel. Endpoint and bearer credential are user supplied.
- This repository ships the client and the versioned [push format](PUSH_PROTOCOL.md), not a server.
  A receiver, dashboard, vault, or agent belongs to the user and lives outside this repository.

This is automated export, not restore or two-way sync. A NOOP-operated receiver, accounts, server
read-back, remote writes, or making app behaviour depend on endpoint availability remain out of
scope. The feature stays Experimental until its Android background behaviour is proven quiet and
reliable in real-world use.

## Proposing a scope change

Scope changes are deliberate, not incidental. If you believe one of the out-of-scope areas should move,
open an issue that names the constraint it touches and how it would be satisfied — don't open the PR
first. A "WHOOP has it" argument, on its own, is not a reason: NOOP is a clean-room, offline, anonymous
tool, not a WHOOP clone.
