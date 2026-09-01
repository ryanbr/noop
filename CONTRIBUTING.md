# Contributing to NOOP

Thanks for your interest in contributing. NOOP is a standalone, fully **offline**
companion app for WHOOP 4.0 and 5.0 / MG straps — it pairs over Bluetooth, stores
everything on-device in SQLite, and computes recovery / strain / HRV / sleep
locally. No servers, no accounts, no data leaving the device.

This file is a quick orientation. The **full contributing guide** —
repository layout, the design-system rules, the BLE safety contract, how to add a
metric / screen / command / migration, and the commit conventions — lives in
[`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md). Read that before opening a
non-trivial PR.

> NOOP is not affiliated with, endorsed by, or connected to WHOOP, Inc., and is
> not a medical device. See [`DISCLAIMER.md`](DISCLAIMER.md).

---

## Quick start

The codebase is reusable Swift packages (`Packages/`) plus a thin macOS app
(`Strand/`) and a full Android app (`android/`). The fastest feedback loop is the
packages — they build and test on their own, no Xcode project and no strap needed.

### Swift packages

```bash
# Test just the package you touched (substitute the name):
cd Packages/WhoopProtocol && swift build && swift test
```

The five packages are `WhoopProtocol` (BLE framing / decode), `WhoopStore`
(SQLite persistence), `StrandAnalytics` (recovery / strain / HRV / sleep math),
`StrandImport` (WHOOP CSV + Apple Health importers), and `StrandDesign` (the
SwiftUI design system).

### macOS app

The Xcode project is generated from `project.yml` and is **not** committed.

```bash
brew install xcodegen
xcodegen generate         # regenerate after any project.yml or file add/remove
open Strand.xcodeproj     # build and run from Xcode
```

For a runnable, ad-hoc-signed `NOOP.app` without an Apple ID, see
[`docs/BUILD.md`](docs/BUILD.md).

### Android app

```bash
cd android
./gradlew assembleFullDebug      # the real app (full flavour); JDK 17 required
./gradlew assembleDemoDebug      # demo flavour — 120 days of synthetic data, no strap
./gradlew testFullDebugUnitTest  # unit tests
```

---

## What CI checks

Some GitHub Actions workflows run on *every* PR; others are path-filtered and only run when
you touch what they cover. All of them compile and run unit tests only — no code signing, no
secrets, no release. The table is the source of truth, deliberately — the section this
replaced led with a count, and a count in prose is what goes stale while the list below it
looks fine.

The check names GitHub shows you are **job** names, which do not resemble the workflow
names. That column is why this table exists:

| Check you see | Workflow | Runs when |
|---|---|---|
| `check` | **i18n Coverage** (`i18n-coverage.yml`) | every PR |
| `doc-comments` | **Source Hygiene** (`source-hygiene.yml`) | every PR |
| `linux-capture` | **Tools Python CI** (`tools-python.yml`) | every PR |
| `build-and-test` | **Android CI** (`android.yml`) | `android/**`, the protocol/store test resources, `Strand/Resources/Localizable.xcstrings` |
| `test (…)`, `tools (…)` | **Swift Packages CI** (`swift-packages.yml`) | `Packages/**`, the `Tools/SleepBench`, `Tools/SleepPSG` and `Tools/Backfill` packages, `android/app/src/test/resources/**`, `Strand/Liquid/LiquidCore.swift` |

Read that as a worked example: an Android-only PR runs Android CI plus the three that always
run, so a short list of checks does not mean little was checked.

**App build** (`app-build.yml`, app-target compile + the `StrandTests` macOS suite) is
`disabled_manually` and is **not** in that list. App-target code — SwiftUI views,
`BLEManager`, `Repository`, Compose screens — is compiled by **nothing** on a normal PR, so
build it locally before you push, or ask a maintainer to dispatch `app-build.yml`. See
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md#what-ci-gates--and-what-it-deliberately-doesnt)
for why the lean setup is deliberate and what else is gated at release time instead.

If CI fails on your PR, fix the cause rather than working around it. Never commit
generated output (`Strand.xcodeproj/`) or any secrets, keystores, or `local.properties`.

---

## Submitting a PR

1. One concern per PR where practical (keep protocol, schema, UI, and Android
   changes separate).
2. Fill in the [PR template](.github/PULL_REQUEST_TEMPLATE.md).
3. For anything on the BLE path, state what you tested **on real hardware** and on
   which strap. A green build is not proof a command behaves correctly.
4. For analytics changes, add a test and cite the method.
5. For UI changes, use `StrandDesign` tokens only — no hardcoded colors, fonts,
   or spacing.

By opening a pull request you agree your contribution is licensed under the same
terms as the project — see [`LICENSE`](LICENSE).

---

## Reporting issues

- **Bugs and feature requests:** open an issue using the templates in
  [`.github/ISSUE_TEMPLATE`](.github/ISSUE_TEMPLATE). NOOP is on-device, so please
  leave out anything that identifies you.
- **Security issues:** see [`SECURITY.md`](SECURITY.md).

## Code of conduct

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). Be respectful and
keep discussion focused on the technical work.
