# NOOP documentation

Choose a current guide below. For downloads and a product overview, start with the [project README](../README.md).

## Install and use

| Need | Guide |
|---|---|
| Install or build on iPhone; AltStore/SideStore troubleshooting | [iOS](IOS.md) |
| Install, build or test Android | [Android](ANDROID.md) |
| Features and common questions | [Features](FEATURES.md), [FAQ](FAQ.md) |
| Import a Lift Log program | [Program import](LIFT_LOG_PROGRAM_IMPORT.md) |
| Homebrew packaging status | [Homebrew](HOMEBREW.md) |
| Help or report a problem | [Support](../SUPPORT.md), [security reports](../SECURITY.md) |

## Contribute and build

| Need | Guide |
|---|---|
| Contributor entry and PR checklist | [Contributing](../CONTRIBUTING.md) |
| Engineering rules, BLE safety and change recipes | [Full contributing guide](CONTRIBUTING.md), [agent entry](../AGENTS.md) |
| Toolchain, repository layout and platform build commands | [Build](BUILD.md), [XcodeGen source](../project.yml) |
| App layering and shared-code boundaries | [Architecture](ARCHITECTURE.md), [cross-platform discipline](CROSS_PLATFORM.md) |
| Storage and device drivers | [Data model](DATA_MODEL.md), [driver architecture](DEVICE_DRIVER_ARCHITECTURE.md) |
| Project scope, privacy and safety boundaries | [Scope](SCOPE.md), [privacy/security](PRIVACY_SECURITY.md), [safeguards](SAFEGUARDS.md) |

## Analytics and protocol research

| Need | Guide |
|---|---|
| Metric definitions and validation before changing scores | [Analytics](ANALYTICS.md), [validation protocol](VALIDATION_PROTOCOL.md), [fitness age](FITNESS_AGE.md) |
| Sleep heart-rate research and references | [Sleep contrast](sleep-heart-rate-contrast.md), [research library](LIBRARY.md) |
| Protocol entry and detailed topic map | [Protocol](PROTOCOL.md) |
| Capture data or investigate a new command | [Raw capture](RAW_DATA_CAPTURE.md), [BLE reverse engineering](BLE_REVERSE_ENGINEERING.md) |
| WHOOP 5/MG deep data and optical investigation | [Deep data](WHOOP5_DEEP_DATA.md), [optical experiment](WHOOP5_OPTICAL_EXPERIMENT.md) |
| Experimental Oura observations | [Oura protocol](OURA_PROTOCOL.md) |
| User-owned one-way export format | [Push protocol](PUSH_PROTOCOL.md) |

The [protocol index](PROTOCOL.md) links the individual transport, sensor, configuration, alarm,
command and device-family references. Protocol observations are not proof that a derived metric is validated.

## Design records and history

These explain past work or proposed directions; they are not installation instructions or evidence that a feature ships.

- [Design specifications](superpowers/specs/) and the [Oura BLE architecture record](superpowers/plans/2026-06-29-oura-local-ble-architecture.md).
- [Device-support roadmap](DEVICE_SUPPORT_ROADMAP.md) and [R-R optimisation plan](RR-OPTIMIZATION.md).
- [Original iOS porting notes](IOS.md#historical-porting-notes).
- [Release notes](releases/) and [changelog](../CHANGELOG.md), also shown in the app under **What's new**.

Completed execution recipes for [Oura API import](superpowers/specs/2026-06-27-oura-live-api-import-design.md)
and [Android sleep timeline rows](superpowers/specs/2026-07-10-android-sleep-stage-timeline-design.md) are retained
in Git history, linked from those design records. Their implementations and tests are maintained in the source tree.

## Project notices

[Disclaimer](../DISCLAIMER.md) · [terms](../TERMS.md) · [attribution](../ATTRIBUTION.md) ·
[license](../LICENSE) · [code of conduct](../CODE_OF_CONDUCT.md).

Keep current instructions in their named guide and link to them from here. Preserve existing document paths and
anchors when reorganising: they are referenced by issues, PRs and external readers.
