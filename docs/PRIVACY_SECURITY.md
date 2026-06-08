# Privacy & Security

This document describes NOOP's privacy posture, security model, and the hardening
applied to the parts of the codebase that touch untrusted input. It is written
against the actual source tree; file paths and identifiers below are real and can
be checked.

> **Not affiliated with WHOOP. Not a medical device.** NOOP is an independent,
> unofficial, local-first companion app. It interoperates with a WHOOP strap that
> **you own**, reading **your own** biometric data from **your own** device. It is
> not affiliated with, endorsed by, or connected to WHOOP, Inc. All computed
> outputs (recovery, strain, HRV, sleep, SpO₂, skin temperature, respiratory rate)
> are approximations and are not clinically validated. See `DISCLAIMER.md` and
> `ATTRIBUTION.md` at the repo root.

---

## 1. Design principle: offline by default

NOOP is **offline by default**. The biometric pipeline — strap → on-device decode →
local SQLite — has no network layer at all: no phone-home, no analytics, no accounts,
no login, no cloud sync, and no telemetry. Everything NOOP computes about you lives in a
single SQLite file on your own device.

There is exactly **one** opt-in exception: the **AI Coach** (§1.1a). It is off until you
turn it on with your own API key; when you ask it a question it sends a short text
summary of your recent metrics to the provider you choose. Nothing else in the app ever
touches the network, and your raw data never does.

Data enters NOOP two ways:

| Path | Transport | Direction |
|------|-----------|-----------|
| Live collection | Bluetooth LE, strap → device | Read-only from the strap |
| File import | User-selected files on disk | Read-only from disk |

The only outbound path is the opt-in AI Coach; the biometric pipeline produces no network
traffic of any kind.

### 1.1 Network code: only the optional AI Coach

The biometric pipeline and all five Swift packages
(`WhoopProtocol`, `WhoopStore`, `StrandAnalytics`, `StrandImport`, `StrandDesign`)
contain **no** use of `URLSession`, `URLRequest`, `NWConnection`, `dataTask`, or any
other networking API. The **only** networking anywhere in the app is the AI Coach
(`Strand/AI/AICoach.swift` on macOS, `com.noop.ai.AiCoach` on Android), described in
§1.1a. The package manifests reference dependency *download* URLs that Swift Package
Manager resolves at build time, never at runtime:

```
Packages/WhoopStore/Package.swift   → https://github.com/groue/GRDB.swift.git
Packages/StrandImport/Package.swift → https://github.com/weichsel/ZIPFoundation.git
```

GRDB.swift is the SQLite layer; ZIPFoundation is the archive reader used by the
importers. Neither opens a socket.

### 1.1a The AI Coach (optional, off by default, bring your own key)

The AI Coach lets you ask questions about your data in plain language. It is the one
feature that uses the network, and only on your terms:

- **Off until you enable it.** You enter your own API key for the provider you choose
  (OpenAI or Anthropic). No key, no network calls, ever.
- **What is sent.** When you ask a question, NOOP builds a compact **text** summary of
  your recent metrics (recovery, strain, sleep, HRV, resting HR over ~14 days, plus
  30-day averages and recent workouts) and sends it, with your question, directly to
  that provider's API (`api.openai.com` / `api.anthropic.com`).
- **What is NOT sent.** No raw biometric streams, no Bluetooth data, no account or
  device identifiers — only the summary text and your question.
- **Your key, your relationship.** The request goes from your device straight to the
  provider you picked, under your own account. NOOP runs no server in between and keeps
  no copy.

If you never enable the AI Coach, NOOP makes zero network connections.

### 1.2 The macOS sandbox (and what it means for the AI Coach)

On macOS the App Sandbox is the backstop. The app ships with a deliberately minimal
entitlement set (`Strand/Resources/Strand.entitlements`):

```xml
<key>com.apple.security.app-sandbox</key>                       <true/>
<key>com.apple.security.device.bluetooth</key>                  <true/>
<key>com.apple.security.files.user-selected.read-write</key>    <true/>
```

That is the entire entitlement file. Three keys:

- **`app-sandbox`** — the process runs inside the macOS App Sandbox container.
- **`device.bluetooth`** — permits BLE access to talk to the strap. The matching
  `NSBluetoothAlwaysUsageDescription` string (declared in `project.yml`) states
  plainly: *"NOOP connects directly to your WHOOP strap over Bluetooth to read heart
  rate, R-R intervals, battery, and sensor data locally on your Mac. Nothing leaves
  your device."*
- **`files.user-selected.read-write`** — lets the app read import files the user
  explicitly picks (and write the database in its own container).

Notably **absent**:

- `com.apple.security.network.client` — **no outbound network entitlement.** The macOS
  sandbox will refuse any socket the app tries to open, **including the AI Coach's**. So
  on the sandboxed macOS build the AI Coach cannot reach the network as currently
  shipped — the whole macOS app, Coach included, is offline. (Android has no equivalent
  sandbox restriction, so the AI Coach's call works there with your own key.) Turning the
  macOS Coach on would mean adding this entitlement; until that's a deliberate choice, it
  stays out and macOS stays fully offline.
- `com.apple.security.network.server` — no inbound listener.
- No `files.downloads`, `files.documents`, or any broad filesystem entitlement —
  the app cannot wander the disk; it sees only what the user hands it through the
  open panel, plus its own sandbox container.

This is the structural guarantee behind "offline by design" on macOS: the privacy
property is enforced by the OS, not merely by convention.

> **Note on Hardened Runtime.** `project.yml` currently sets
> `ENABLE_HARDENED_RUNTIME: NO` for local development builds. Distributable /
> notarized builds should enable the Hardened Runtime; it composes with, and does
> not weaken, the sandbox entitlements above.

---

## 2. Data at rest

### 2.1 Where the data lives

All durable data is stored in a single GRDB/SQLite database. The macOS reference app
opens it at (`Strand/Collect/StorePaths.swift`):

```
<Application Support>/OpenWhoop/whoop.sqlite
```

Because the app is sandboxed, `<Application Support>` resolves **inside the app's
sandbox container**, not the user's global `~/Library/Application Support`. Other
apps cannot read it through normal filesystem access.

The schema is defined by a versioned `DatabaseMigrator` in
`Packages/WhoopStore/Sources/WhoopStore/Database.swift` (currently schema version 9).
It holds exactly the kinds of data you would expect from the features:

- **Decoded biometric streams** (durable): `hrSample`, `rrInterval`, `spo2Sample`,
  `skinTempSample`, `respSample`, `gravitySample`, `battery`, `event`.
- **Derived/cached metrics**: `sleepSession`, `dailyMetric`, `workout`, `journal`,
  `appleDaily`, and the generic long-format `metricSeries`.
- **A transient raw outbox** (`rawBatch`): compressed raw BLE frames, **prunable**.
- **Device records** (`device`): strap id, MAC, name, first/last-seen timestamps.

The database is opened in WAL journal mode with `synchronous = NORMAL` and a busy
timeout, tuned for bulk import/backfill writes
(`Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift`). WAL means you will also
see `whoop.sqlite-wal` and `whoop.sqlite-shm` sidecar files alongside the main
database — they live in the same container.

### 2.2 Encryption

The SQLite file is **not encrypted at rest by NOOP itself.** Confidentiality of the
data on disk relies on the platform:

- **FileVault** (full-disk encryption, on by default on modern Macs) protects the
  database whenever the disk is at rest / the machine is powered off.
- The **sandbox container** keeps other user-space apps from reading the file
  directly.

What this does **not** protect against: an attacker with your unlocked, logged-in
session, or a backup/Time Machine copy of the container made while FileVault is
unlocked. The data is plaintext SQLite once the volume is mounted.

> **Option: SQLCipher.** GRDB supports SQLCipher (an encrypted SQLite build) as a
> drop-in. Wiring NOOP's `DatabaseQueue` to a SQLCipher build with a
> Keychain-derived key would give at-rest encryption independent of FileVault. This
> is not enabled in the current build, but the persistence layer is small and
> centralized (one `WhoopStore.init(path:)`), so it is a contained change.

### 2.3 Data minimization & pruning

The raw-frame outbox (`rawBatch`) is treated as transient, not as the system of
record — the decoded streams are durable, the raw frames are a compressed,
**prunable** buffer. The prune policy in
`Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift` deletes old batches:

```sql
DELETE FROM rawBatch WHERE syncedAt IS NOT NULL AND syncedAt < ?
```

So raw captures do not accumulate forever. (The `syncedAt`/upload-related columns are
schema scaffolding inherited from the upstream collection library; in NOOP's offline
configuration nothing uploads, and the raw buffer is purely a local replay/recovery
aid.)

### 2.4 Diagnostics: the strap connection log

When a strap won't connect or behaves oddly, the single most useful thing a user can
send is the connection log. NOOP keeps one so it can be shared **without** needing
`adb` or a developer setup (this is what made issues #17/#18 reportable), and the same
log doubles as the primary tool for **debugging and protocol development** (see
`ANDROID.md` → "Debugging the strap connection").

**What it is.** The BLE client (`android/.../ble/WhoopBleClient.kt`,
`Strand/BLE/BLEManager.swift` on macOS) keeps an **in-memory ring buffer** — the last
2000 log lines on Android — of the connection's control flow: scan results (strap
advertised name + RSSI), the bond/handshake state machine, command names with their
outbound payload **hex**, and offload progress (trim cursors, chunk acks). It is held
in RAM only; the "Share strap log" button writes it to a private app-cache file at
share time and hands that file to the OS share sheet. Nothing is uploaded by NOOP.

**What it does *not* contain.** No account credentials (there is no account), no
decoded biometric *values* (heart-rate numbers, R-R intervals, SpO₂, skin-temp are not
written to the log — only control-plane command names and frame-routing), and no
hello-token or serial hex (the handshake lines log *that* a step happened, not its
secret payload). The one mild identifier is the strap's advertised name (e.g.
`WHOOP 5AG…`), which the user chooses to include when they tap Share.

**logcat is opt-in (debug mode), off by default.** By default the log is mirrored
**only** to the in-app buffer — it is *not* written to Android's system log
(`Log.d`/logcat). A user has no reason to emit the connection log to the device-wide
log, so they don't. Developers who want to watch a session live over
`adb logcat -s WhoopBleClient` turn on **Settings → Strap → "Debug logging"**
(persisted as `NoopPrefs.KEY_DEBUG_LOGGING`, default `false`); the flag drives
`WhoopBleClient.debugLogcat`, which gates the single `Log.d` call. The in-app buffer
and the "Share strap log" export work the same whether or not debug logging is on, so
the diagnostic path is always available without ever defaulting users into logcat.

### 2.5 Wrist alerts: the Android notification listener

Android wrist alerts (buzz the strap when chosen apps notify you) need a
`NotificationListenerService` — that's the only way to register in the OS's
**Notification Access** list and be told a notification was posted. Notification
access is a powerful permission, so for a privacy-first app it's worth being precise
about what NOOP does and does not do with it:

- **Off by default, double opt-in.** The service does nothing until you both grant
  Notification Access in system settings *and* turn on **Wrist alerts** in NOOP, then
  enable specific apps (each app is off by default).
- **It reads only the posting package name — never content.** On a posted
  notification NOOP looks at *which app* posted (and skips ongoing / foreground-service /
  group-summary noise), checks your settings (master toggle, that app's opt-in, quiet
  hours, only-when-worn), and if all pass, sends a haptic-pattern command to the strap.
  The notification's title, text, sender, and extras are never read, stored, logged, or
  transmitted.
- **Nothing leaves the device.** There is no server; the only output is a Bluetooth
  buzz to your own strap. (`android/.../notif/NoopNotificationListener.kt`.)

---

## 3. Threat model

NOOP parses two classes of **untrusted input**: bytes arriving over Bluetooth, and
files chosen for import. Both are treated as hostile and validated before anything
reaches the database. Apple Health and WHOOP files in particular can be very large
(multi-hundred-MB to multi-GB), so resource exhaustion is part of the model.

What is explicitly **out of scope**: NOOP cannot defend the data against an attacker
who already controls your unlocked user session (see §2.2), and it makes no claim of
cryptographic authentication of the strap — BLE pairing/bonding security is provided
by the OS Bluetooth stack and the device, not by NOOP.

### 3.1 Threat A: a malicious or malfunctioning BLE peer

A device advertising as a strap (or a glitching real strap) could send malformed,
truncated, oversized, or adversarial frames. The protocol core
(`Packages/WhoopProtocol/`) is the reverse-engineering layer and is the first line of
defense.

**CRC-gated parsing.** Every frame is checked against its checksums before it is
allowed to drive any application state. `Framing.swift` implements three checksums
verbatim from the wire formats:

- `crc8` (poly 0x07) over the length header,
- `crc32` (zlib/reflected) over the inner payload,
- `crc16Modbus` for the WHOOP 5.0 header (ported from the `goose` work).

`verifyFrame(_:)` (and the family-aware `verifyFrame(_:family:)`) only return
`ok == true` when the header CRC **and** the payload CRC32 both validate:

```swift
let ok = crc8OK && (crc32OK ?? false)
```

The live BLE path then refuses anything that fails. In
`Strand/BLE/FrameRouter.swift`:

```swift
let parsed = parseFrame(frame)
guard parsed.ok else { return }
// Reject frames that failed their checksum — never let bad bytes drive state.
if parsed.crcOK == false { return }
```

The same gate guards clock correlation (`Strand/Collect/ClockCorrelation.swift`
requires `parsed.ok, parsed.crcOK != false`), so a corrupt frame can neither update
the displayed metrics nor poison the device-clock model.

**Bounds-checked decoding.** Field reads never index past the end of the buffer. The
low-level readers in `Interpreter.swift` return `nil` instead of trapping when a read
would run off the end of the frame:

```swift
@inline(__always) private func readU16(_ f: [UInt8], _ off: Int) -> Int? {
    off + 2 <= f.count ? Int(f[off]) | (Int(f[off + 1]) << 8) : nil
}
```

Schema-driven field extraction skips any field whose offset is out of range
(`guard let val = readDType(frame, fld.off, dtype) else { continue }`), and the
`FieldBuilder` clamps every slice to the real buffer length
(`let end = min(off + length, frame.count)`). The WHOOP 5.0 path adds explicit
minimum-length and `payloadEnd <= frame.count` guards before slicing the payload or
trailer. A short or lying length field therefore yields a partial parse, never an
out-of-bounds read.

**Sane-value gating at the application edge.** Even a CRC-valid frame is range-checked
before it updates the UI/state. The realtime handler discards implausible heart rates
(`hr >= 30, hr <= 220`) and only overwrites R-R intervals when the frame actually
carries them — so a single bad-but-valid packet can't wipe good state.

**Reassembly is bounded by the declared length.** The `Reassembler` resynchronizes on
the `0xAA` start-of-frame byte, discards leading garbage, and only emits a frame once
`length + 4` bytes are present — it does not unboundedly buffer arbitrary data.

### 3.2 Threat B: a malicious import file (zip bombs, XML bombs, huge exports)

Both importers live in `Packages/StrandImport/` and assume the file is hostile.

**Apple Health (`AppleHealthImporter.swift`).** Apple Health exports routinely exceed
1 GB, and a malicious one could be far worse.

- **Streaming SAX parse, never DOM.** The importer parses with `XMLParser` /
  `XMLParserDelegate` over an `InputStream` opened directly on the file. It explicitly
  does **not** use `XMLParser(contentsOf:)`, which would load the whole multi-hundred-
  MB document into memory first. Element handling runs inside a per-element
  `autoreleasepool` so temporaries from tens of millions of elements drain instead of
  accumulating — peak memory stays bounded regardless of file size.
- **Zip-bomb cap on decompression.** When the input is a `.zip`, `export.xml` is
  extracted to a temp file in fixed-size chunks with a running budget; the moment the
  decompressed total crosses the ceiling, extraction aborts:

  ```swift
  var written = 0
  let cap = 8 << 30   // 8 GB decompressed ceiling — zip-bomb guard
  _ = try archive.extract(entry, bufferSize: 1 << 20) { chunk in
      written += chunk.count
      if written > cap { throw ImportError.xmlParseFailed("export.xml too large") }
      try handle.write(contentsOf: chunk)
  }
  ```

  Chunks go straight to disk, so a bomb cannot inflate RAM. This deliberately replaced
  an earlier pipe-fed parser that could deadlock or crash on a malformed export.
- **Robust error handling.** Parse failures are surfaced as typed `ImportError`s; the
  delegate distinguishes a genuinely malformed document from a benign empty/EOF
  condition rather than crashing.
- **Temp files are cleaned up** via `defer { try? FileManager.default.removeItem(at: tmp) }`.

**WHOOP CSV export (`WhoopExportImporter.swift`).** The WHOOP data export is a small
bundle of CSV files, but the same defensive posture applies.

- **Per-entry size ceiling.** Each CSV is capped at 256 MB
  (`maxEntryBytes = 256 << 20`). Folder imports skip any file larger than the cap;
  zip imports reject entries whose *declared* uncompressed size exceeds it **and**
  enforce a running byte budget during extraction, so a ZIP64 header that lies about
  its size is still stopped mid-stream:

  ```swift
  let declared = Int(exactly: entry.uncompressedSize) ?? Int.max
  if declared > Self.maxEntryBytes { continue }
  ...
  if written > Self.maxEntryBytes { throw CancellationError() }
  ```

- **CRC32 verification on extraction.** `archive.extract()` verifies each entry's
  CRC32 (ZIPFoundation's `skipCRC32` defaults to `false`) and throws on a mismatch or
  truncation. A corrupt/truncated/oversized entry is skipped entirely rather than
  partially imported — no half-rows reach the database.
- **Filename allow-list.** Only four known CSV names
  (`physiological_cycles.csv`, `sleeps.csv`, `workouts.csv`, `journal_entries.csv`)
  are ever read; everything else in the archive is ignored. Matching is by filename,
  case-insensitively, so the parser never executes or interprets arbitrary archive
  members.
- **Tolerant, header-name-driven parsing.** Columns are matched by normalized header
  name (not position), every column is optional, BOMs are stripped, and rows with no
  usable timestamp are dropped. Malformed input degrades to fewer rows, not a crash.

---

## 4. What NOOP does *not* collect or transmit

- **No accounts, no login.** Nothing to sign into; no credentials
  stored.
- **No telemetry / analytics / crash reporting.** No third-party SDKs of that kind.
- **No cloud, no sync, no remote backup.** Your data never leaves the machine via
  NOOP.
- **No advertising identifiers, no tracking.**
- **No WHOOP account or API credentials.** NOOP talks only to the strap over local
  BLE; it does not authenticate against, or pull from, any WHOOP server.

---

## 5. Hardening summary

| Surface | Risk | Mitigation | Where |
|---------|------|------------|-------|
| Process | Data exfiltration / network egress | Only the opt-in AI Coach networks (your key, to your chosen provider, a text summary — §1.1a); on macOS even that is blocked by the sandbox (**no network entitlement**) | `Strand/AI/AICoach.swift`, `Strand/Resources/Strand.entitlements`, `project.yml` |
| Filesystem | Broad disk access | Only `files.user-selected.read-write`; data stays in the sandbox container | `Strand.entitlements`, `Strand/Collect/StorePaths.swift` |
| BLE frames | Malformed / adversarial packets | CRC8 + CRC32 (+ CRC16 for v5) gating; reject on failure | `WhoopProtocol/Framing.swift`, `Strand/BLE/FrameRouter.swift` |
| BLE frames | Out-of-bounds reads from short/lying length | `nil`-returning bounds-checked readers; slice clamping; min-length guards | `WhoopProtocol/Interpreter.swift` |
| BLE frames | Garbage / partial fragments | SOF-resync reassembler bounded by declared length | `WhoopProtocol/Framing.swift` (`Reassembler`) |
| App state | Implausible-but-valid values | Range gates (e.g. HR 30–220) at the state edge | `Strand/BLE/FrameRouter.swift` |
| Health import | XML bomb / multi-GB DOM blowup | Streaming SAX over `InputStream`; per-element autorelease pool | `StrandImport/AppleHealthImporter.swift` |
| Health import | Zip bomb | 8 GB decompressed ceiling, chunked to disk, hard abort | `StrandImport/AppleHealthImporter.swift` |
| CSV import | Zip bomb / oversized entries | 256 MB per-entry cap (declared + running budget); CRC32 verify | `StrandImport/WhoopExportImporter.swift` |
| CSV import | Arbitrary archive members | Filename allow-list; tolerant optional-column parsing | `StrandImport/WhoopExportImporter.swift` |
| Data at rest | Disk theft / offline access | Relies on FileVault + sandbox container; SQLCipher available as an option | `WhoopStore/WhoopStore.swift` |
| Diagnostics log | Leaking the strap log to the device-wide system log | In-app ring buffer only; logcat mirroring is **opt-in** (Settings → Strap → "Debug logging", default off); no biometric values / tokens logged (§2.4) | `android/.../ble/WhoopBleClient.kt` (`debugLogcat`), `android/.../ui/MainActivity.kt` (`NoopPrefs`) |

---

## 6. Reporting a security issue

NOOP is a hobbyist, non-commercial interoperability and research project provided
**as-is, with no warranty**, for personal and educational use only (see
`DISCLAIMER.md`). If you find a security or privacy issue, please open a GitHub issue
describing the problem and a reproduction; sensitive reports can be coordinated
privately via the contact on the project's GitHub profile. Issues will be reviewed in
good faith.

---

## 7. Credits

The protocol and persistence work NOOP builds on is community reverse-engineering of
hardware the user owns, used for interoperability:

- **`johnmiddleton12/my-whoop`** — the WHOOP 4.0 BLE framing/command/decode work and
  the collection logic the `WhoopProtocol` / `WhoopStore` packages and the app's
  collection layer are adapted from.
- **`b-nnett/goose`** — the WHOOP 5.0 protocol (the `fd4b0001-…` service family, the
  CRC16-Modbus header, and the "puffin" packet types) the v5 decode path is ported
  from.
- **`groue/GRDB.swift`** — the SQLite persistence layer.
- **`weichsel/ZIPFoundation`** — the archive reader used by the importers.

See `ATTRIBUTION.md` and `DISCLAIMER.md` for the full attribution and good-faith
notice. NOOP contains no WHOOP proprietary code, firmware, binaries, logos, or
assets, and performs no DRM circumvention.
