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

This is long-standing practice, not a one-off. Worked examples already in the tree:

- **`spo2_candidate_82`** (`Interpreter.swift`) — WHOOP 5 v18 byte `@82` read as a strap-computed SpO₂
  percentage, attributed as *"a decompile-sourced decode (gen5.rs `spo2_pct`), reimplemented here as a
  protocol fact with attribution"*. A guard test stops it ever writing `spo2Pct`, and it is still a
  candidate because the cross-device evidence is split.
- **The R22 config opcodes** (`Whoop5Config.swift` / `.kt`) — `SET_FF_VALUE (0x78)` and the flag key
  names, corroborated against *Asherlc/dofek docs/whoop-ble-protocol.md (Android APK decompilation)*
  and validated byte-for-byte against a decrypted HCI capture.
- **The disputed battery opcode** (`Commands.swift`, `Enums.kt`) — a decompile reads
  `GET_EXTENDED_BATTERY_INFO` as 87 where our table says 98. Both readings are recorded and the
  question is settled by probing real firmware, not by picking a source.
- **The MG ECG ("Labrador") packet layouts** (`Whoop5Ecg.swift` / `.kt`, `docs/PROTOCOL.md` §9.1) —
  field order, widths and enum values for `FilteredLabradorPacket` / `RawLabradorPacket`, plus the
  `{revision, arg, padding}` command payload shape, re-derived from static analysis of the vendor's iOS
  client. The four command NUMBERS were already in our own `CommandNumber` table from the whoomp/goose
  work above. Most of it still ships as an **unvalidated candidate**: the decode backs no metric, and the
  fields nobody can attest (the wrist enum's raw values, the progress "timed out" sentinel, the ECG
  sample unit, the packet type byte) are carried raw rather than named. **One exception is now attested
  rather than inferred:** `ControlSignal`'s raw values were also read off the client's enum order, and a
  WHOOP MG (`WS50_r00`, fw `50.39.1.0`) contradicts that reading — `1` stops generation, `2` starts it,
  `0` is refused. The enum now carries the hardware values with the device and firmware named. A
  hardware-observed value is strictly stronger than the inference it replaces, but it is one device.
  The on-strap rhythm classifier's verdict is decoded as a byte and is never presented as a finding —
  NOOP is not a medical device.

And the line held from the other side:

- **`StrainTargetNotifier`** (both platforms) — *"CLEAN-ROOM: this reimplements the BEHAVIOUR only. The
  copy is NOOP's own — NOT WHOOP's decompiled strings."* Behaviour re-derived; the user-facing text
  written fresh.
- **The `LINK_VALID` handshake**, rejected in
  [`docs/BLE_REVERSE_ENGINEERING.md`](docs/BLE_REVERSE_ENGINEERING.md) — its reply payload is a
  literal string lifted from the app. Expression, not a fact about the wire, so it stays out
  regardless of whether the handshake turns out to be real.

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
