# Attribution

NOOP is an independent, unofficial, local-first app for macOS, Android and iOS. It is not affiliated
with, endorsed by, or connected to WHOOP, Inc. "WHOOP" is used nominatively only to
identify the hardware the app interoperates with.

NOOP builds on prior community reverse-engineering and interoperability work:

## WHOOP 4.0 protocol + Swift packages
- **`johnmiddleton12/my-whoop`** — the `WhoopProtocol` and `WhoopStore` Swift packages
  (vendored under `Packages/`), the WHOOP 4.0 BLE framing/command/decode work, and the
  iOS collection logic that NOOP's `WhoopBLE`/`Collect` layers are adapted from.
  See `DISCLAIMER.md` (carried over from that project).

## WHOOP 5.0 / MG protocol
- **`b-nnett/goose`** — the WHOOP 5.0 BLE reverse-engineering (service UUID family
  `fd4b0001-…`, CRC16-Modbus header, CLIENT_HELLO, and the "puffin" packet types)
  that NOOP's `DeviceFamily` Whoop-5 path and `whoop5_protocol.json` are ported from.

## Other
- **GRDB.swift** (`groue/GRDB.swift`) — SQLite persistence (via Swift Package Manager).
- **MarkdownUI** (`gonzalezreal/swift-markdown-ui`) — renders the AI Coach's Markdown
  replies (via Swift Package Manager).

NOOP contains no WHOOP proprietary code, binaries, firmware, logos, or assets, and
performs no DRM circumvention. It operates only with the user's own device and data.
NOOP is **not a medical device**; all metrics (HR, HRV, recovery, strain, sleep,
SpO₂, temperature) are approximations and not clinically validated.
