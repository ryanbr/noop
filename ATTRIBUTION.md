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

## Xiaomi Smart Band (Mi Band) import
- **`artyomxx/xiaomi-band-ios-export`** — documented the Mi Fitness iOS app's on-device
  SQLite layout (`DataBase/<user_id>/de/<user_id>.db`, JSON `value` columns, the `*_day`
  rollups and the `sleep` table's `items[]` hypnogram with state codes). NOOP's
  `XiaomiBandImporter` is **re-derived** from those findings and verified against a real
  Mi Band 10 export; **no code is copied** (the reference tool is AGPL, NOOP is not).
- **Gadgetbridge** (`Freeyourgadget/Gadgetbridge`) — referenced only for *protocol facts*
  about the live Mi-protobuf BLE stack in the roadmap's research notes. GPLv3; NOOP copies
  **none** of its code and has not built the live lane.

## Facts learned from a decompiled app

The facts-only doctrine above is usually applied to other open-source RE projects. It applies the same
way when a fact originates in a **decompile of the vendor's own app** — a case that recurs because
several third-party WHOOP projects are decompile-derived.

The line is between the fact and the expression of it:

- **A protocol fact may be re-derived** — a byte offset, field width, enum value, scale factor. It is
  attributed at the point of use, and it ships as an **unvalidated candidate**: decoded and logged,
  never backing a shipped metric, until independent captures from real hardware clear it.
- **The implementation may not be copied** — not verbatim, not transcribed. Nor may string literals,
  assets, or anything else that is authored expression rather than an observation about the wire.

Current command and field meanings are maintained in the
[command reference](docs/PROTOCOL_COMMANDS.md), [sensor layouts](docs/PROTOCOL_SENSORS.md),
and [ECG contract](docs/PROTOCOL_ECG.md). Decoder support and physical validation remain
separate questions.

## Oura ring (gen 3/4/5) protocol
NOOP's Oura code is **original clean-room** work. The local BLE source
(`Strand/BLE/OuraLiveSource.swift` + `android/.../ble/OuraLiveSource.kt`) and the JVM/Swift-pure
`OuraProtocol` package (`Packages/OuraProtocol/`, `android/.../com/noop/oura/`) were written from
**documented protocol facts only**, cited tersely in `docs/OURA_PROTOCOL.md`. The community
reverse-engineering resources below were consulted as **facts-only references** (byte layouts,
service/characteristic UUIDs, framing and auth shapes); **no RE source code is copied** into NOOP.
- **`open_ring`**: consulted for protocol facts only. Licensed **GPL-3.0**; NOOP copies none of
  its code and is not a derivative work of it.
- **`open_oura`**, **`ringverse`**, **`relue`**: consulted for protocol facts only. These carry
  **no license**, so NOOP treats them as reference documentation of observed behaviour only and
  copies no code from them.

NOOP reads only the ring's own decoded raw signals and its own open event tags, computes NOOP's
own Charge/Rest, and **never** reads or displays Oura's encrypted readiness or sleep scores. The
documented Oura file-import lane (`Packages/StrandImport/Sources/StrandImport/OuraExportParser.swift`)
remains available as a fallback.

## Other
- **GRDB.swift** (`groue/GRDB.swift`) — SQLite persistence (via Swift Package Manager).
- **MarkdownUI** (`gonzalezreal/swift-markdown-ui`) — renders the AI Coach's Markdown
  replies (via Swift Package Manager).

NOOP contains no WHOOP proprietary code, binaries, firmware, logos, or assets, and
performs no DRM circumvention. It operates only with the user's own device and data.
NOOP is **not a medical device**; all metrics (HR, HRV, recovery, strain, sleep,
SpO₂, temperature) are approximations and not clinically validated.
