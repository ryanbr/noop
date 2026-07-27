# NOOP - Oura Ring BLE Protocol Specification (Clean-Room)

**Status:** Internal decoder foundation, v0.1 (2026-06-29)
**Scope:** Oura Ring Gen 3 (Horizon), Gen 4, Gen 5. Foundation for NOOP's own Swift (`StrandiOSShared` / `Strand`) and Kotlin decoders.
**Authorship:** This is NOOP's own original specification. Every protocol *fact* (UUID, opcode, byte layout, tag value) is cited to a reverse-engineering reference read for facts only. No source code was copied from any RE repo. NOOP decodes raw signals plus the ring's own HRV/sleep tags and runs NOOP's own scoring; NOOP never touches Oura's encrypted PyTorch scores.

**Citation keys used below:**
- **[open_ring]** - LogosIsLife/open_ring `PROTOCOL.md` (GPL-3.0; byte-for-byte verified vs ~953k records, Ring 4). Treat as the authoritative framing/layout source where repos conflict.
- **[ringverse]** - ringverse/protocol `oura/BLE.md`, `oura/events/EVENTS.md` (no-license; Ring 4 event-tag dictionary + layouts), and `oura/storage.md` (the official iOS app's local SQLite schema, cited only for §3.7's key-extraction recipe).
- **[open_oura-r3]** - Th0rgal/open_oura `docs/horizon-ring3-protocol-cheatsheet.md` (no-license; Ring 3).
- **[open_oura-r5]** - Th0rgal/open_oura `docs/ring-5-observations.md` (Ring 5).
- **[open_oura-feat]** - Th0rgal/open_oura `docs/ring-features.md` (feature gating).
- **[open_oura-spo2]** - Th0rgal/open_oura `docs/spo2-calibration.md` (branch `swim-sessions-and-rdata-spike`; no-license, facts cited only, no code copied). Classes `0x6F`/`0x70` as firmware-computed percentages and documents the `0x8b` ratio-of-ratios path with the app's quadratic coefficients. The coefficients are attributed there to the decompiled Oura app (`com/ouraring/oura/workitem/data/items/d.java`); they are recorded here as CITED FACTS for interoperability, not reproduced implementation - NOOP does not receive `0x8b` and implements none of it.
- **[relue]** - relue/oura_ring_reverse `docs/.../heartbeat_replication_guide.md` and `heartbeat_complete_flow.md` (no-license; Ring 3 live-HR).
- **[oura-rs]** - Th0rgal/open_oura `crates/oura-protocol/src/events.rs` (no-license Rust clean-room decoder; facts cited only, no code copied). Its event tags marked `"_status": "unvalidated"` are treated the same as our Tier B - plausible, not ground-truth-confirmed.
- **[open_oura-act]** - Th0rgal/open_oura `crates/oura-cli/src/activity_model.rs` (no-license; facts cited only). The activity classifier's input assembly reads four SEPARATE event tags — `met`←`0x50`, motion←`0x47`, temp←`0x46`, `hr_bpm`←`0x80` — establishing which tag each signal comes from (notably HR from the `0x80` IBI record, not `0x50`).
- **[open_oura-viz]** - Th0rgal/open_oura `crates/oura-cli/src/viz.rs` + `motion_server.rs` + `crates/oura-link/src/client.rs` (no-license; facts cited only, no code copied). A live 3-D motion visualiser fed by the ring's real-time accelerometer stream. Cited for the live-ACM request/response shape, an accelerometer counts-per-g figure, and its own statement that the **gyroscope is not on the live BLE channel** (RData-only), so yaw is unobservable.
- **[open_oura-ctl]** - phoenixdo-eth/open_oura `crates/oura-cli/src/control.rs`, commit `b45b534a` 2026-07-16 (no-license; facts cited only, no code copied). **A FORK, not upstream:** the file has never landed in Th0rgal/open_oura, the commit is AI-co-authored, and its unit tests feed synthetic samples rather than captures — weight its claims below upstream ones. Cited for a second, independently-derived accelerometer counts-per-g figure and for a tilt-angle convention that conflicts with [open_oura-viz].
- **[ring4-ble]** - Defying/oura-ring4-ble `docs/apk-findings.md` + `docs/protocol-notes.md` (no-license; APK static-analysis + Ring-4 BLE captures, facts cited only). Confirms the framing/auth/tag set is generation-invariant (Ring 4 == Ring 3) and pins the full feature-ID table + the feature mode / subscription enums; also confirms the app derives BPM as `round(60000 / ibi_ms)`.
- **[TechInsights]** / **[System Plus]** - public Gen 3 teardowns identifying the IMU as a **Bosch Sensortec BMI160** (`techinsights.com/ebook/oura-ring-gen-3-smart-ring`, `reverse-costing.com/teardowns/oura-ring-gen3`). Hardware identification only.
- **[BMI160 datasheet]** - Bosch Sensortec BMI160 datasheet (BST-BMI160-DS000), public vendor documentation. Cited for the part's own `STEP_CNT` register (§2.11.36) — a capability the ring HAS and does NOT expose, not an Oura protocol fact.
- **[Oura blog]** - Oura's public product blog (`ouraring.com/blog/activity-improvements/`), cited for Oura's own statement that "Real Steps" (March 2025) is a machine-learning model. A vendor statement about behaviour, not a layout source.

> **CONFLICT NOTE (resolution rule):** The relue archive file `event_data_definition.md` describes events as **protobuf varint** records (e.g. `0x55` SLEEP_HR with field tags). This contradicts the **byte-for-byte verified TLV framing** in [open_ring] and [ringverse]. The TLV/bit-packed model from [open_ring]/[ringverse] is authoritative for our decoders; the protobuf description is treated as unverified/likely AI-fabricated and is NOT used. Where a layout is only attested by a single no-license, AI-generated doc, it is marked **(UNVERIFIED)** and our decoder must gate it behind a fixture test before trusting it.

---

## 1. GATT Layout

### 1.1 Base service (all generations)
- **Service UUID:** `98ED0001-A541-11E4-B6A0-0002A5D5C51B` [open_ring][ringverse][open_oura-r3]
- **Write characteristic (phone → ring):** `98ED0002-A541-11E4-B6A0-0002A5D5C51B`
  - ATT handle observed `0x0015`, **Write Without Response** (ATT op `0x12`) [open_ring][ringverse]
- **Notify characteristic (ring → phone):** `98ED0003-A541-11E4-B6A0-0002A5D5C51B`
  - ATT handle observed `0x0012`, notifications via Handle-Value-Notification (ATT op `0x1B`) [open_ring][ringverse]
- **GATT channel id:** `0x0004` [ringverse]

> Implementation note for NOOP: subscribe to `...0003` notifications, then write commands to `...0002` with `.withoutResponse`. Do **not** assume write-with-response.

### 1.2 Per-generation GATT differences

| Aspect | Gen 3 (Horizon) | Gen 4 | Gen 5 |
|---|---|---|---|
| Service `…0001` | yes | yes | yes (same layout) [open_oura-r5] |
| Write `…0002` | yes | yes | yes |
| Notify `…0003` | yes | yes | yes |
| Extra char `…0004` | - | - | **present**: read,write,notify,indicate [open_oura-r5] |
| Extra char `…0005` | - | - | **present**: write,notify [open_oura-r5] |
| Extra char `…0006` | - | - | **present**: write,notify [open_oura-r5] |
| MTU | 203 [open_oura-r3] | 247 [open_ring] | 247 [open_oura-r5] |

- Ring 5 keeps "the **same** GATT layout, framing, and app-auth flow as the Ring 3/4 … no new opcodes, event tags, or fundamental framing changes." [open_oura-r5]
- The functional roles of Ring-5 chars `…0004/0005/0006` are **unconfirmed** in the RE corpus - leave them unused in v1; do not write to them.

### 1.3 MTU negotiation
- Notifications stream up to the negotiated MTU (max payload = MTU − 3 ATT bytes). Default BlueZ MTU is 23 unless negotiated. [open_ring]
- **NOOP rule:** immediately after subscribing to `…0003`, request ATT MTU = **247** (Gen 4/5) or **203** (Gen 3). On iOS/CoreBluetooth the MTU is auto-negotiated; read `maximumWriteValueLength` and `CBPeripheral.maximumWriteValueLength(for: .withoutResponse)` and clamp writes. On Android, call `requestMtu(247)` before the first command.

---

## 2. Framing / Chunking

Two distinct layers ride on the same characteristics. The first byte disambiguates: a value present in the **opcode table (§4)** → outer command/response frame; otherwise → an inner event-record stream. [open_ring]

### 2.1 Outer frame (command + command-response)
All multi-byte integers are **little-endian**. [open_ring][ringverse]

```
+--------+--------+------------------------+
| op : 1 | len : 1| body : <len> bytes     |
+--------+--------+------------------------+
```
- `op` - opcode (§4)
- `len` - number of body bytes following
- Multiple outer frames may be packed into a single ATT notification value. **Consumer rule:** loop `consume(2 + len)` until the buffer is exhausted. [open_ring]

### 2.2 Extended / secure-session frame (opcode `0x2F`)
Opcode `0x2F` carries a sub-operation as the **first body byte**:
```
2F <len> <subop> <subop-body…>
```
Sub-op table in §4.2. [open_ring][open_oura-r3]

### 2.3 Inner event record (TLV) - the event stream
Returned during history fetch (`0x10`/`0x11`) and live streaming. Each record: [open_ring]
```
+--------+--------+--------+--------+--------+--------+------------------+
| type:1 | len:1  | ctr_lo | ctr_hi | ses_lo | ses_hi | payload: len-4   |
+--------+--------+--------+--------+--------+--------+------------------+
```
- `type` - event tag (≥ `0x41`, §6) [ringverse]
- `len` - body length, **`len ≥ 4`** (covers the 4 timestamp bytes + payload) [open_ring]
- `ctr` (u16 LE) + `ses` (u16 LE) → **`ringTimestamp = (session << 16) | counter`** [open_ring]
- payload length = `len − 4`

> [ringverse]'s EVENTS.md states the header as `type:1, len:1, ringTimestamp:u32 LE` (i.e. it treats the 4 counter/session bytes as one u32). These are two equivalent views of the same 4 bytes; NOOP stores `ringTimestamp` as a single u32 LE and derives counter/session only if a generation needs the split. [open_ring][ringverse]

- **Total record length = `len + 2`.** [ringverse]
- Several records may pack into one notification; consume `2 + len` per record and loop. [open_ring]

### 2.4 Multi-packet payloads
There is no application-level fragmentation header beyond the TLV `len`. A record never spans two notifications in the verified corpus; each notification contains whole frames/records. NOOP's parser must still be defensive: buffer partial trailing bytes across notifications and only emit complete `2+len` records.

---

## 3. Authentication Handshake

### 3.1 Key materials (three independent layers) [open_ring]

| Layer | Size | Purpose |
|---|---|---|
| Link-layer LTK | 16 B | BLE bond / link encryption (managed by OS pairing) |
| LE Privacy IRK | 16 B | resolves the ring's rotating private address |
| Application `auth_key` | 16 B (AES-128) | the app-level challenge key (§3.2–3.4) |

- On a **factory-reset** ring, BLE link encryption (OS-level pairing/bond) is **mandatory** before any protocol command can be written. [open_oura-r3]
- The application auth handshake is **session-scoped**: it must be re-run on every new BLE connection. [open_ring][open_oura-r3]

### 3.2 Install our own key (opcode `0x24`) - post-factory-reset only
Used once after a factory reset to provision NOOP's own 16-byte AES key into the ring: [ringverse][open_oura-r3]
```
phone → ring:  24 10 <16-byte key>          (SetAuthKey; 0x10 = 16-byte len)
ring  → phone: 25 01 00                       (status 0x00 = OK)
```
NOOP stores its 16-byte key locally (Keychain on iOS, EncryptedSharedPreferences/Keystore on Android). This key is required for every subsequent session's challenge.

### 3.3 Get auth nonce (sub-op `0x01` → response `0x2C`)
```
phone → ring:  2f 01 2b                        (GetAuthNonce)
ring  → phone: 2f 10 2c <nonce: 15 bytes>      (18 B total)
```
[open_ring][ringverse][open_oura-r3]

### 3.4 Compute proof (AES-128-ECB challenge)
[open_ring][ringverse]
- Plaintext = `nonce (15 B) ‖ 0x01 (1 B)` = 16 B, then **PKCS#5/PKCS#7 full-block padding** appends `0x10 × 16` → 32 B total.
- Cipher = **AES-128/ECB/PKCS5Padding** with our 16-byte `auth_key`.
- **proof = first 16 bytes of the ciphertext.**

> Padding detail per [open_ring]: `AES_128_ECB(auth_key, nonce ‖ 0x01 ‖ pad)[:16]`. The trailing `0x01` byte and full-block `0x10` padding are load-bearing - the ring computes the same and compares the first block. Implement this exactly; do not strip padding before encrypt.

### 3.5 Submit proof (sub-op `0x11` → response `0x2E`)
```
phone → ring:  2f 11 2d <proof: 16 bytes>      (19 B total)
ring  → phone: 2f 02 2e <status>
```
[open_ring][ringverse][open_oura-r3]

**Status byte (`0x2E`):** [ringverse]
| Value | Meaning |
|---|---|
| `0x00` | Success |
| `0x01` | Authentication error (wrong key) |
| `0x02` | In factory reset (need `0x24` key install first) |
| `0x03` | Not the original onboarded device |

### 3.6 Pre-auth readable / gated commands
Before app-auth, the ring answers a small set unauthenticated: firmware (`0x08`), product serial/hardware (`0x18`). Auth-required commands return `2f 02 2f 01` until authenticated: battery (`0x0c`), history events (`0x10`), feature status (`0x2f…0x20`), realtime/feature-latest. [open_oura-r3][open_oura-r5]

### 3.7 Advanced pairing: using the ring's genuine app-issued `auth_key` (optional, user-recipe)
§3.2 provisions **NOOP's own** key, which only works post-factory-reset and does not carry any of the account's server-side feature entitlements (§7.1). An alternative — entirely optional, and only usable with **your own** ring/account/iPhone — is to pair NOOP with the **same** `auth_key` the real Oura app already uses. Because that key is tied to the account, the ring keeps whatever cloud `ClientConfiguration` (SpO2, Exercise HR, real-steps, …) the real app has already unlocked for it (§7.1 documents the 2026-07-30 observation this produced).

> **IMPORTANT: this requires an active Oura membership at the time you enable the feature.** SpO2 / Exercise HR / real-steps are gated behind the paid Oura subscription, not just the free app — the `ClientConfiguration` the ring inherits only unlocks them while a membership is active on the account. A 1-month membership is enough: subscribe, enable the feature(s) in the app (step 1 below), then the ring keeps that entitlement for NOOP to inherit via the Advanced-key pairing. **Untested: what happens after the membership lapses.** We don't yet know whether the ring's unlocked state persists past expiry, needs a periodic server re-check, or reverts — treat the unlock as good for the duration you tested it (one billing month), not confirmed indefinite.

1. Pair the ring with the genuine Oura app first, **with an active paid membership on the account**, and enable the features you want (e.g. SpO2 — [Oura support: Blood Oxygen Sensing](https://support.ouraring.com/hc/en-us/articles/7328398760851-Blood-Oxygen-Sensing-SpO2), steps/activity — [Oura support: How Oura Measures Steps](https://support.ouraring.com/hc/en-us/articles/360025576833-How-Oura-Measures-Steps-Activity)). These toggles are account-side settings, not something NOOP can set.
2. On the same Mac, start a **local, unencrypted** iPhone backup (Finder → device → Back Up Now). No jailbreak, no decryption bypass — this is Apple's own standard backup mechanism over your own data.
3. Browse the backup with a third-party backup explorer (e.g. "iBackup Viewer") and locate the Oura app's container: search for `AppDomain-com.ouraring.oura`, then under it `<UUID>/assa.sqlite` (UUID is uppercase). [ringverse: `oura/storage.md`]
4. Extract `assa.sqlite` and open it with any SQLite browser. Per [ringverse]'s `oura/storage.md`, the ring's id and key live in table `ringconfiguration`:
   ```sql
   SELECT id, auth_key FROM ringconfiguration;
   ```
5. `auth_key` comes back **Base64-encoded**; decode it to get the raw 16-byte AES key.
6. In NOOP's Oura pairing wizard, choose **"Advanced: I already have my ring's key"** (`AddDeviceWizard.swift`) instead of the normal factory-reset flow, and paste in the decoded key.

Treat this key like a password: it authenticates as the real Oura app against your account's ring. NOOP stores it locally the same way it stores its own provisioned key (Keychain on iOS / EncryptedSharedPreferences-Keystore on Android, §3.2) — nothing is transmitted anywhere. This recipe extracts a fact from **your own** device backup and a public schema doc; it does not touch, decompile, or redistribute any Oura app code.

### 3.8 macOS pairing limitation (observed, 2026-07-29)

Pairing an Oura ring that has never been Bluetooth-bonded to the Mac (i.e. any ring whose only prior
bond is with the official Oura app on a phone) reproducibly fails on macOS. `CBCentralManager.connect()`
is issued cleanly (scanning stopped first, `central.state == .poweredOn`, a valid, in-range peripheral -
observed RSSI as good as -55), but **no CoreBluetooth delegate callback ever arrives** - not
`didConnect`, not `didFailToConnect`. The ring never appears in System Settings ▸ Bluetooth either
(no partial bond record is created). Ruled out: a second central holding the ring - the same failure
reproduces with the paired phone's Bluetooth fully off. This matches CoreBluetooth's documented
behavior that `connect()` has no built-in timeout (an unanswered connect just stays pending forever),
so the practical symptom is a silent, permanent hang rather than an error.

This is a different (and apparently more total) failure surface than the already-known WHOOP 5.0/MG
macOS limitation (see `docs/WHOOP5_DEEP_DATA.md`, "iOS / Android only on real hardware") - WHOOP 5/MG
at least connects and discovers services, failing only at an authenticated characteristic write
(`CBATTError` "Encryption is insufficient"). Oura's connect doesn't get that far at all. The exact
CoreBluetooth/bluetoothd mechanism isn't diagnosed further than this (would need a low-level HCI/SMP
trace), but the practical conclusion is the same as WHOOP 5/MG's: **treat Oura ring pairing as
iOS/Android-only** until proven otherwise on macOS. This applies to the §3.7 Advanced-key flow as
much as to the §3.2 factory-reset one - the limitation is at connect time, before any key is used.
Not yet tested: whether a genuinely never-bonded-anywhere (factory-reset) ring behaves differently
from the already-Oura-app-owned case tested here.

---

## 4. Opcode Table

### 4.1 Top-level opcodes
Compiled from [ringverse] (BLE.md) and [open_ring] (PROTOCOL.md); examples are exact bytes from the sources.

| Op | Name | Dir | Example / form | Notes |
|---:|---|---|---|---|
| `0x06` | RealtimeMeas / identity_req | →ring | `06 04 <mode> <flags> 00 00` | realtime enable control; rare in pairing [open_ring][open_oura-r3] |
| `0x07` | identity_resp | ←ring | | [open_ring] |
| `0x08` | GetFirmwareVersion | →ring | `08 03 00 00 00` | pre-auth OK [ringverse][open_oura-r3] |
| `0x09` | FirmwareVersion resp | ←ring | `09 12 …` | API/FW/BL/BT/MAC (§4.3) [ringverse] |
| `0x0A` | RunSelfTest | →ring | `0a 04 ff ff ff ff` | [ringverse][open_oura-r3] |
| `0x0B` | SelfTest resp | ←ring | `0b 04 ff ff ff ff` | [ringverse] |
| `0x0C` | GetBattery | →ring | `0c 00` | auth-gated after key set [ringverse][open_oura-r3] |
| `0x0D` | Battery resp | ←ring | `0d 06 …` | §6.10 [ringverse][open_ring] |
| `0x0E` | StartFirmwareUpdate / soft_reset | →ring | `0e 01 ff` | reboot 22–35 s; DANGEROUS [open_ring] |
| `0x0F` | resp to `0x0E` | ←ring | status `0x00`=accept | [open_ring] |
| `0x10` | GetEvents (history fetch) | →ring | `10 09 <rt:4 LE> <max:1> <flags:4 LE>` | auth-gated; §5 [ringverse][open_ring] |
| `0x11` | GetEvents resp / summary | ←ring | `11 08 …` | §5.2 [ringverse][open_ring] |
| `0x12` | SyncTime | →ring | `12 09 <…> ` | §5.4 [ringverse][open_ring] |
| `0x13` | SyncTime resp | ←ring | `13 05 …` | [ringverse][open_ring] |
| `0x16` | SetBleMode | →ring | `16 01 <mode>` | `00`=normal, `01`/`02`=fast-HR [ringverse][open_ring] |
| `0x17` | SetBleMode resp | ←ring | `17 01 <mode>` | [ringverse] |
| `0x18` | GetProductInfo | →ring | `18 03 <offset> 00 10` | serial `08 00 10`; hw `18 00 10` [ringverse][open_oura-r3] |
| `0x19` | ProductInfo resp | ←ring | | [ringverse] |
| `0x1A` | FactoryReset | →ring | | DANGEROUS [ringverse] |
| `0x1B` | FactoryReset resp | ←ring | | [ringverse] |
| `0x1C` | SetNotification / state_cmd | →ring | `1c 01 <flags>` | `00`=none, `3f`/`bf`=all [ringverse][open_ring][open_oura-r3] |
| `0x1D` | SetNotification resp | ←ring | `1d 01 00` | [ringverse] |
| `0x1E` | state_query | →ring | | [open_ring] |
| `0x1F` | state_query resp | ←ring | | [open_ring] |
| `0x20` | SetUserInfo | →ring | `20 03 <type> …` | [ringverse][open_oura-r3] |
| `0x21` | SetUserInfo resp | ←ring | | [ringverse] |
| `0x24` | SetAuthKey | →ring | `24 10 <16-byte key>` | §3.2 [ringverse] |
| `0x25` | SetAuthKey resp | ←ring | `25 01 00` | [ringverse] |
| `0x26` | EnableFlightMode | →ring | `26 02 <…>` | [ringverse] |
| `0x28` | CheckSleepAnalysis / data_flush | →ring | `28 01 <force>` | `28 01 00` flush flash buffer [ringverse][open_ring][open_oura-r3] |
| `0x29` | resp to `0x28` | ←ring | `29 01 00` | [ringverse][open_ring] |
| `0x2B` | DFU / fw_progress | both | | OTA [ringverse][open_ring] |
| `0x2C` | fw_bulk | both | | OTA payload [open_ring] |
| `0x2F` | Extended / SecureSession | both | `2f <len> <subop> …` | §4.2 [ringverse][open_ring] |
| `0x31` | SetRingMode | →ring | `31 04 <4-byte mode> 00 00` | `00000000`=normal, `01000000`=fast-HR [open_oura-r3] |
| `0x32` | SetRingMode resp | ←ring | | [ringverse][open_oura-r3] |
| `0x37` | SetManufacturingInfo | →ring | | [ringverse] |
| `0x38` | resp to `0x37` | ←ring | | [ringverse] |
| `0x39` | SyncManufacturingInfo | →ring | `39 00` | [ringverse][open_oura-r3] |
| `0x3A` | resp to `0x39` | ←ring | | [ringverse] |

### 4.2 `0x2F` secure-session sub-ops

| Sub | Form | Meaning | Cite |
|---:|---|---|---|
| `0x01` | `2f 01 2b` | request nonce | [open_ring][open_oura-r3] |
| `0x02` | `2f 02 …` | sec_cfg / status / capability page (`2f 02 01 <page>`) | [open_ring][open_oura-r3] |
| `0x10` | `2f 10 2c <nonce:15>` | nonce response | [open_ring] |
| `0x11` | `2f 11 2d <proof:16>` | proof submission | [open_ring] |
| `0x20` | `2f 02 20 <feature>` | feature/param **read** | [open_ring][relue] |
| `0x21` | `2f 06 21 <feature> <mode> <status> <state> <sub>` | feature read **response** | [open_ring][open_oura-r3] |
| `0x22` | `2f 03 22 <feature> <value>` | param **write byte 0** (enable) | [open_ring][relue] |
| `0x23` | `2f 03 23 <feature> <status>` | ack to `0x22` | [relue] |
| `0x26` | `2f 03 26 <feature> <value>` | param **write byte 2** (subscribe) | [open_ring][relue] |
| `0x27` | `2f 03 27 <feature> <status>` | ack to `0x26` | [relue] |
| `0x28` | `2f 0f 28 …` | param **push notification** (carries live-HR samples) | [open_ring][relue] |
| `0x2C` | `2f 10 2c <nonce>` | nonce response (alias view) | [open_ring] |
| `0x2D` | `2f 11 2d <proof>` | proof submission (alias view) | [open_ring] |
| `0x2E` | `2f 02 2e <status>` | handshake completion | [open_ring][ringverse] |

### 4.3 Firmware response (`0x09`) decode
`09 12 <API:3> <FW:3> <BL:3> <BT:3> <MAC:6>` - e.g. API `2.0.0`, FW `3.4.3`, BL `1.0.1`, BT `5.0.12`, MAC little-endian last-6. [open_oura-r3][open_oura-r5]
Gen 5 example `0912 020100 020103 010001 090329 665544332211`. [open_oura-r5]
**NOOP uses byte[2] of the API triplet (generation marker via product info) to branch decoder behaviour - see §7.**

---

## 5. Event Fetch (Cursor) Protocol + Live HR

### 5.1 GetEvents request (`0x10`)
```
10 09 <ringTimestamp:4 LE> <max_events:1> <flags:4 LE>
```
[open_ring][ringverse]
- `ringTimestamp` - cursor; ring streams records with `rt > cursor`. `0x00000000` = full dump. [open_ring]
- `max_events` - up to 255 records to fetch; `0x00` = ack-only (advance cursor without data). [open_ring]
- `flags` - phone sends `0xFFFFFFFF`. [open_ring][open_oura-r3]
- Canonical example: `10 09 00 00 00 00 08 ff ff ff ff` (cursor 0, max 8). [open_oura-r3]

### 5.2 GetEvents response / summary (`0x11`)
```
11 08 <events_received:1> <progress:1> <bytes_left:4 LE> <pad:2>
```
[open_oura `EventBatchSummary`]
- `events_received` - COUNT of events in the batch (`0xFF` = 255, the legacy max). NOT a status byte.
- `progress` - `sleepAnalysisProgress`, informational only (never a block).
- `bytes_left` - the ring's remaining buffered bytes; the drain is done at `bytes_left == 0`.
- The summary carries **no cursor**. An earlier revision read bytes 2–5 as `last_ring_timestamp` — that
  value is `bytes_left`, and persisting it as a cursor caused the #91 full re-dump loop.
- Observed on-device (2026-07-12): the `0x11` can arrive BEFORE its batch finishes streaming.

### 5.3 Canonical fetch loop (NOOP, aligned with open_oura `drain_events`)
1. SyncTime (§5.4). 2. Optionally `28 01 00` to flush flash-buffered events first. [open_ring]
   - **⚠️ ONE CLIENT GETS THE HISTORY, AND ONLY ONE (observed, NOOP 2026-08-02).** The ring bonds to a
     single client at a time, and in practice **whichever client drains a period's history consumes it —
     the other gets nothing for those days**. Confirmed by a user who alternated NOOP and the official
     Oura app: after either had synced, the other found nothing left for that window. This is a hard,
     user-visible consequence of using NOOP with a ring whose Oura Cloud history also matters, and it
     blocks any same-night NOOP-vs-Cloud comparison (see §6.5).
   - **CAUSE UNVERIFIED, and NOOP may be responsible.** NOOP sends `28 01 00` at the START of every
     history fetch (`OuraDriver`, `.startHistoryFetch`), unconditionally, even though [open_ring]
     documents it as OPTIONAL. Two readings of "flush" are equally plausible and have OPPOSITE
     implications:
     - **(A) it CLEARS the flash buffer** — then NOOP is destroying data the Oura app would otherwise
       upload, and simply not sending it would let both clients read the same history.
     - **(B) it flushes RAM→flash** (the usual embedded meaning; the tag is also named
       `CheckSleepAnalysis`, suggesting it finalises pending analysis) — then it is REQUIRED, and dropping
       it would lose the most recent records instead.
     NOOP's own captures cannot distinguish these: our drain resumes from a client-side cursor, so
     not re-receiving old records is equally explained by "we never asked". **Do not change this on
     theory** — it is on the connect/offload path (see the BLE safety contract) and the failure mode of
     guessing wrong is silent data loss.
   - **How to test it:** one session with `28 01 00` suppressed. If NOOP still receives the full backlog,
     reading (A) is supported and the command can be dropped — which would also un-block the §6.5
     same-night comparison. If recent records go missing, reading (B) is right and it must stay.
3. Send `0x10` with the stored cursor, `max=255`, flags `FF FF FF FF` (open_oura's `flags=-1`).
4. Collect the batch until the stream goes QUIET (~1.5 s of no records — open_oura's `transact()`
   window). The `0x11` summary is NOT an end-of-batch marker (§5.2); never re-request mid-stream.
5. Next cursor = max envelope ring-time seen across ALL batch records + 1. If the batch had no records,
   or the cursor did not advance past the previous request's, STOP (open_oura `!progressed`).
6. Repeat from step 3 while the summary reports `bytes_left > 0`; done at `bytes_left == 0`.

**SUPERSEDED (open_ring):** an earlier revision taught an ack-fetch (`max=0`, cursor =
`last_ring_timestamp`) ~100 ms after the records. Re-sending `0x10` at a non-advancing cursor — and
especially mid-stream — makes the ring RESTART serving from that cursor: observed on-device 2026-07-12
as five identical ~955 KB re-serves of one window while the tail (`bytes_left` 409 KB) was never
reached. open_oura has no ack-fetch; every request is the same `(cursor, max=255, flags=-1)` shape
with the cursor advanced per batch.

### 5.4 SyncTime (`0x12`) and its response (`0x13`)
```
12 09 <unix_seconds:8 LE> <tz:1>
```
`unix_seconds` = host UTC as uint64 seconds; `tz` = signed offset in HALF-HOURS from UTC.
[ringverse BLE.md][open_oura `req_sync_time`] — validated on-device 2026-07-12 (this layout made the
ring emit its first 0x42 and anchored history).

Response:
```
13 05 <current_device_timestamp:4 LE> <status:1>
```
`current_device_timestamp` is the ring's OWN clock counter when it processed the SyncTime. [ringverse]
**NOOP anchor use (2026-07-13):** paired with the host wall-clock at receipt this is a DETERMINISTIC
ring-time→UTC anchor available at every connect. Needed because the `0x42` time_sync_ind record is
only logged when the ring actually ADJUSTS its clock — an already-synced ring can serve an entire
drain with no 0x42 (observed: a whole night parked unanchored). ringverse labels the field "seconds"
while the record clock runs in 100 ms ticks; NOOP disambiguates raw-ticks vs seconds×10 against the
persisted resume cursor (exactly one reading must land within cursor…cursor+7 days) and adopts
nothing when ambiguous.

**SUPERSEDED (open_ring):** `12 09 <token:1> <counter:3 LE> 00 00 00 00 f6` with
`counter = floor(unix_seconds/256)` and response `13 05 <ack> <counter_echo:3 LE> 00` — that request
layout never anchored on real hardware.

### 5.5 Ring-time → UTC anchoring
- The ring clock is in **ticks**: default **100 ms/tick** (10 Hz); burst mode **1 ms/tick** (`factor_flag=1`). [open_ring]
- Anchor from event `0x42` (time-sync ind, §6.11): set `anchor.utc_ms` from the event's epoch and `anchor.ring_time` from current `ringTimestamp`.
- Conversion: `utc_ms = anchor.utc_ms + factor × (target_rt − anchor.ring_time)`, `factor ∈ {100,1}`. [open_ring]
- On `0x41` (ring start) with `rt` regression → invalidate anchor (zero it). [open_ring]
- `0x85` RTC beacon gives 1-second-granularity `unix_s` as a secondary source. [open_ring]

### 5.6 Live-HR realtime enable (Gen 3 verified; same path Gen 4/5)
Three writes to `…0002`, each gated on its ACK; daytime-HR feature id = `0x02`: [relue][open_oura-r3]
```
1) 2f 02 20 02      → ACK 2f 06 21 02 01 11 02 00     (read DHR feature status)
2) 2f 03 22 02 03   → ACK 2f 03 23 02 00              (enable: byte0 = 3)
3) 2f 03 26 02 02   → ACK 2f 03 27 02 00              (subscribe: byte2 = 2)
```
**HR/IBI then streams ~1 Hz** as `0x2F` sub-op `0x28` push notifications: [relue][open_ring]
```
2f 0f 28 02 XX 02 00 00 <IBI_L> <IBI_H> 00 00 00 00 YY ZZ 7f
```
- IBI at body bytes 8–9: **`ibi_ms = ((byte9 & 0x0F) << 8) | byte8`** (12-bit, LE-ish nibble) [relue]
- **`bpm = round(60000 / ibi_ms)`** [relue]
- Example `[08,09] = 01 04` → `ibi = 1025 ms` → ≈ 59 BPM. [relue]

**Disable:** `2f 03 22 02 01` → ACK `2f 03 23 02 00`. Stream stops on ACK. [relue][open_oura-r3]

> Behaviour caveat: [open_oura-r3] reports that on its Ring-3 unit, realtime `0x06`-based enabling ACK'd but emitted no stream within 60–90 s, whereas the `0x2F`/feature-`0x02` path above produced ~1 Hz IBI. **NOOP must use the feature-`0x02` (`0x2F`) path, not `0x06`,** and treat absence of `0x28` pushes within ~10 s as "not streaming → retry/reseat."

### 5.7 DHR auto-revert
Daytime-HR auto-reverts after ~20 s; NOOP re-engages every ~15 s while a live session is open. [open_ring]

---

## 6. Event / Record Byte Layouts

All records share the §2.3 TLV header (`type`, `len`, 4-byte `ringTimestamp`). Body offsets below are **relative to the start of the record** (offset 6 = first body byte). All multi-byte values **little-endian** unless stated. [ringverse]

### 6.1 IBI + amplitude - `0x60` `ibi_and_amplitude_event` (18 B)
- Fixed 14-byte body (bytes 6–19) holding 6 IBIs + amplitudes, **byte-scatter packed** — each IBI is
  gathered from SCATTERED bytes, NOT a linear bitstream. [oura-rs][ringverse]
- **Shift exponent** = low nibble `[3:0]` of the last body byte (`b[13]`); if `n=7` then `shift=0`, else `shift=n+1`. [oura-rs]
- Each **IBI** (ms), for `k` in 0…5: `(b[6+k] & 1) | (b[k] << 3) | <2 high bits from the b[12]/b[13] nibbles>`
  — i.e. 1 LSB from an amplitude byte, 8 mid bits from `b[k]`, 2 high bits from the pack bytes. [oura-rs]
- Each **amplitude** = `(b[6+k] >> 1) << shift` (7-bit mantissa `[7:1]` shifted by the exponent). [oura-rs]
- Per-sample timestamp: walk backward from event UTC by each IBI duration. [ringverse]
- **WARNING (2026-07-12, ringverse ingest):** ringverse's `p_ibi_and_amplitude` shows the byte order
  is **SCRAMBLED** (each 11-bit IBI rebuilt from three non-adjacent pieces, exact indices in
  parse.js), while NOOP's `decodeIBIAmplitude` reads the fields with a naive SEQUENTIAL BitReader —
  the two do not agree, so our 0x60 IBI values are SUSPECT until cross-checked against concurrent
  live-HR R-R (same method as the 0x71 fixture plan). Part of the parked history-IBI work.

### 6.2 Green-LED IBI+amp - `0x71` `green_ibi_and_amp_event` (18 B)
Full layout per ringverse `p_green_ibi_and_amp` (parse.js, firmware `@0x503960`); payload = 14 body
bytes (indices below are payload offsets = spec offsets − 6). Strict length gate: wire len == 18.
- `p13` (spec byte 19): bit `[3]` RESERVED — set means a firmware-layout mismatch, do not decode;
  `s = p13 & 7`, `shift = (s == 7) ? 0 : s + 1`.
- 5 IBIs, each an **11-bit** value from three scrambled pieces (bit 0 | bits 2:1 | bits 10:3):
```
ibi0 = (p10 & 1) | (p4 << 3) | ((p13 >> 5) & 6)
ibi1 = (p9  & 1) | (p3 << 3) | ((p12 & 3) << 1)
ibi2 = (p8  & 1) | (p2 << 3) | ((p12 >> 1) & 6)
ibi3 = (p7  & 1) | (p1 << 3) | ((p12 >> 3) & 6)
ibi4 = (p6  & 1) | (p0 << 3) | ((p12 >> 5) & 6)
```
- 5 amplitudes: `amp[i] = (p[6+i] >> 1) << shift` (7-bit mantissa in bits `[7:1]` of `p6..p10`).
- Emission order: first entry is **amplitude-only** (`ibi = 0`, `amp[0]`), then 5 entries
  `{ibi[i], amp[i]}`; per-sample timestamps walk BACKWARD from the event UTC by each IBI (same
  model as 0x60). `p5`/`p11` unused. [ringverse]
- NOOP: `OuraDecoders.decodeGreenIBIAmpCandidate` implements this verbatim as a **Tier-B CANDIDATE**
  (#287) — used only in the 0x71 fixture-capture log, side by side with the raw bytes, until a real
  capture cross-checked against concurrent live-HR R-R validates it.
- CORRECTION: an earlier revision summarized this as "5 IBI deltas + 6 amplitudes" — the five values
  are full 11-bit IBIs (0–2047 ms) used as backward TIME deltas, and only 5 amplitude bytes exist
  (the first emitted entry reuses `amp[0]`).

### 6.3 SpO2 IBI+amp - `0x6E` `spo2_ibi_and_amplitude_event` (17 B)
- Byte 6: bits `[7:6]` = flag(1)+shift(3); bits `[3:0]` = mode(4). [ringverse]
- 5 IBIs as 8-bit counts ×8, read bytes 11→7 (reverse). [ringverse]
- 7 amplitudes: first `byte<<3`, rest `byte<<shift`. [ringverse]

### 6.4 Green IBI quality - `0x80` `green_ibi_quality_event` (4–18 B, 2 B/sample)
Per 2-byte sample, **high byte first** (NOT a little-endian u16): [oura-rs][ringverse]
```
ibi_ms  = (b1 & 0x07) | (b0 << 3)   ; 11-bit, b0 = high 8 bits, b1[2:0] = low 3 bits
quality = (b1 >> 3) & 0x03
flag    =  b1 >> 5
```
**NOOP filter:** accept sample only if `quality == 1` (the ring's "good beat" flag) and the IBI is
physiological (300–2000 ms). (Up to 7 samples per 14-byte record.) [oura-rs]
**Validated (decode fix):** the earlier reading treated the pair as a little-endian u16 masked to bits 0–10,
placing the high byte in the LOW bits — a bit-order error (real-capture within-record jitter 583 ms). The
high-byte-first layout with the `quality == 1` gate yields a clean beat train (45 ms jitter) and keeps more
good beats. Matches `open_oura`'s `parse_api_green_ibi_quality_event`. (Same class of fix as `0x60`, §6.1.)

**IBI → HR (NOOP research, Tier-B):** each accepted sample is a per-beat interval, so an instantaneous HR
follows as `60000 / IBI_ms`. open_oura feeds this record's per-minute HR (`hr_bpm`) into its activity
classifier (`oura-cli/src/activity_model.rs`, alongside `met`←`0x50`, motion←`0x47`, temp←`0x46`) — i.e. HR
comes from THIS record, not from the `0x50` MET record. NOOP already decodes these IBIs for HRV; a diagnostic
sidecar (`oura-ibihr-<id>.jsonl`, records tagged by source event `0x80`/`0x60`/`0x6E`/`0x44`) also
reconstructs an HR history from the banked stream for offline study — NEVER scored. **Result (2026-07-16,
first full overnight):** the earlier "sparse + ~15 % impossible-HR" daytime reading was largely the DECODE
BUG above (wrong bit layout), not a ring limitation. With the corrected layout, one full night decoded to
**94 % minute coverage, ~10 % beat-to-beat artifact, a clean ~56 bpm resting level with a real nocturnal dip
that tracks the reconstructed hypnogram** — i.e. usable as an overnight HR/HRV source. Daytime/activity is
sparser (~43 % coverage — wrist motion thins the banked beats) but the surviving beats are clean and HR
tracks effort (rest ≈ 59 → moderate ≈ 100 bpm). Still Tier-B, never scored; promotion to
`restingHr`/`avgHrv` is gated on multi-night validation against a reference. [open_oura-act]

**Caveats (2026-07-20):** two things bound "usable overnight HR". (a) It is CONDITIONAL on the ring being
worn — a night on the charger still banks a hypnogram + skin-temp but essentially no IBIs (the whole
banked window sits inside a `"chg. detected"`→`"chg. stopped"` interval, §6.15), so overnight HR exists
only on worn nights. (b) A banked IBI must be persisted at its OWN anchored ring-time
(`unixSeconds(forRingTimestamp:)`), never the drain-arrival wall-clock: because a night is drained the next
day, stamping the beat at arrival misfiles every overnight beat to the daytime sync moment — the deep-night
hours (00–06 local) come out empty while the sync hour piles up an implausible density. So the `oura-ibihr`
sidecar (anchored correctly) is right, but the datastore's `rrInterval` is not, until `.ibi` is anchored
like its sibling banked streams (`.hrv`/`.temp`/`.spo2`/`.sleepPhase`) — the fix in PR #677 (pending merge).

### 6.5 SpO2 per-sample - `0x6F` `spo2_event` (5–18 B, 1 s spacing)
- Byte 6: bits `[7:4]` = SpO2 base (<<7); bits `[3:0]` = status flag. [ringverse]
- One `uint8` SpO2 value per second from byte 7 onward; optional `0xFF` terminator. [ringverse]
- **Each sample is stored at its OWN second (#1070).** The record carries ONE `ringTimestamp` for all of
  its samples, but `spo2Sample` is keyed `(deviceId, ts)` — writing them all at the record time collided
  12 of every 13 away on insert, and the loss is permanent because the ring trims its banked history once
  the offload is acked. `OuraSpO2` therefore carries `index`/`count` (the sample's position in its
  record), and `OuraStreamMapping` lays the samples **backward** at 1 s from the record time, so the
  **last** sample keeps the record's own `ts` and the record's anchor semantics are unchanged. The record
  envelope marks the WRITE moment, exactly as for the hypnogram burst (§6.12). Cadence is derived, not
  assumed: a real Gen 3 overnight gives 13 values per packet at a 13 s median packet interval (p10 12,
  p90 14), so the samples tile the interval at exactly 1 Hz. This is collision-**rare**, not
  collision-proof — the cadence has a tight tail, and a 12 s gap between two 13-sample records makes the
  newer record's first second equal the older record's last, costing one sample at that boundary. On the
  same overnight 204 of 1,877 adjacent pairs overlap, by exactly 1 s each: **204 of 24,405 samples
  (0.84 %) lost, against 92.3 % before**. Both platforms insert ignoring the conflict (`DO NOTHING` /
  `OnConflictStrategy.IGNORE`), so the survivor is the older record's *last* sample — the anchor-exact
  one — and what is dropped is the newer record's most back-extrapolated sample. Keeping both would
  require sub-second timestamps; the row key is seconds.
- **`0x6F` is a FIRMWARE-COMPUTED PERCENTAGE, not a raw ADC** — independently documented by open_oura
  (`docs/spo2-calibration.md`, branch `swim-sessions-and-rdata-spike`), which classes `0x6F`
  (`API_SPO2_EVENT`) and `0x70` (`API_SPO2_SMOOTHED_EVENT`) as firmware-computed percentages, distinct
  from the raw ratio path in §6.5.1 below. This corroborates NOOP's own read (the decoder's `#968` note:
  samples are DIRECT percentages, ~95–96, and adding the scaled base produced impossible ~223 % values).
- **⚠️ OPEN: ~51 % of decoded `0x6F` samples exceed 100 %, and this is NOT a decode bug.** Measured over
  **9,076 records / 117,816 samples** from three real Gen 3 captures (2026-07-30 → 08-02), against **922
  nights** of the same wearer's Oura Cloud export (`dailyspo2.csv`) as ground truth:

  | | Oura Cloud (truth) | decoded `0x6F` |
  |---|---|---|
  | mean | 97.59 | **99.98** |
  | median | 97.68 | **101** |
  | max | 99.4 | **107** |
  | samples > 100 | **0** | **51 %** |

  - **Two independent decoders agree byte-for-byte.** NOOP (break at the first `0xFF`) and open_oura's
    `decode_spo2` (strip only a TRAILING `0xFF` sentinel, keep the rest) produce **identical** output on
    this corpus — same count, mean, median and max — because there is **not one mid-payload `0xFF` in
    9,076 records** (27 bodies end in the sentinel). So the header-byte-then-percentages reading is
    agreed, and the >100 values come from the ring, not from either implementation.
  - **The decode's SHAPE is right; only its LEVEL is wrong.** The series is smooth and physiological:
    within-record range median **1**, consecutive |Δ| median **0** / p95 **1** — a real slow-moving SpO2
    trace, not noise or a mis-framed field.
  - **The `[7:4]` "SpO2 base" nibble does NOT explain it.** [ringverse] describes byte 6's high nibble as
    a base; empirically it does not correlate with the record's own level (**r = +0.10**; low nibble
    +0.02). Skipping byte 0 is correct — an earlier attempt to ADD `base << 7` produced impossible ~223 %
    readings.
  - **No simple correction reconciles it.** An additive −2.39 or multiplicative ×0.976 (either would
    centre the mean) still leaves values above the physical ceiling.
  - **A clamp is part of the answer but not all of it.** Applying the **[85, 100]** clamp open_oura
    documents for the `0x8b` path brings the mean to 98.44 — within **0.85** of truth — which is why the
    Cloud never shows >100. But it pins **58 %** of samples at exactly 100, which no real night does, and
    no offset+clamp pair reproduces both statistics (−2 matches the mean but not the median; −4 the median
    but not the mean).
  - **Conclusion: the wire→percentage transform is UNKNOWN.** A clamp is clearly applied downstream; some
    additional level shift also appears to be. NOT corrected here — no same-night ground truth pins it,
    and choosing an offset would fabricate a calibration. **`0x6F` data appears unexplored:**
    [open_oura-spo2] states plainly that they *"don't capture those, and that R→% math lives in
    firmware"*, so this corpus may be the first look at the tag's real distribution.
  - **⚠️ WHY THIS MAY STAY OPEN — the obvious test is structurally blocked.** Separating offset from clamp
    needs a same-night comparison, i.e. an Oura Cloud export overlapping a BLE capture. **That cannot be
    produced concurrently:** the ring bonds to ONE client at a time, so while NOOP is paired the Oura app
    is not syncing, and the Cloud has no data for exactly the nights NOOP captured. Confirmed on this
    setup — the store's `spo2Sample` rows span 2026-07-28 → 08-02 while the Cloud export ends 2026-07-07:
    **zero overlapping days**. The comparison above is therefore distribution-level across
    *non-overlapping* periods (per-sample values vs nightly averages, different nights), which is why it
    can bound the discrepancy but not decompose it.
  - **Re-pairing to the Oura app afterwards does NOT work — already refuted in practice.** Whichever
    client drains a window CONSUMES it, so the app finds nothing left for the nights NOOP captured (and
    vice versa). See the warning in §5.3, which records that observation and flags NOOP's unconditional
    `28 01 00` flush as a candidate cause.
  - **Paths that could still settle it**, in increasing cost: (a) **resolve the §5.3 flush question** — if
    suppressing `28 01 00` leaves the history readable by BOTH clients, this comparison becomes possible
    for free. (b) A **reference pulse oximeter worn during sleep** alongside the ring — definitive, but
    `0x6F` only flows at rest so a daytime spot-check produces nothing comparable. (c) A **second ring**,
    one bonded to each client. Until one of these happens the transform stays UNKNOWN and is documented,
    not guessed.

### 6.5.1 SpO2 ratio-of-ratios - `0x8b` `spo2_r_pi_event` — **NOT OBSERVED in NOOP captures**
- Carries the raw **ratio-of-ratios `r`** plus a **perfusion index `pi`** (quality parameter). This is the
  input the official app converts to a percentage, NOT a percentage itself. [open_oura-spo2]
- **Conversion (app-side, `libecore` `EcoreWrapper.nativeCalculateSpO2Simple`):**
  `SpO2(%) = a·r² + b·r + c`, clamped to **[85, 100]**, with hardware-specific coefficients:

  | Hardware | a | b | c |
  |---|---|---|---|
  | Gen4 / "Oreo" | −13.4 | −5.1 | 105.2 |
  | "Cooper" | −12.1 | −6.9 | 106.3 |

  The two sets differ by <1 % on test data, so the mapping is robust to picking the wrong one; the Ring 5
  mapping is unconfirmed in app 7.18. A naive generic `110 − 25·r` reads ~91 % against a calibrated ~93.4 %
  — i.e. materially worse. [open_oura-spo2]
- **NOOP has NEVER received `0x8b`**: 0 occurrences across every capture checked (vs 5,585 × `0x6F` and
  21,706 × `0x77` in the same files), and it is absent from `OuraEventTag`. Whether that is
  generation-specific (the published coefficients name Gen4/Oreo and Cooper), server-flag gated like SpO2
  itself (§7.1), or simply not emitted on this Gen 3 is **unknown**. Worth a targeted check if a properly
  calibrated SpO2 is ever wanted — this is the only documented path to one, since `0x6F`'s own scale is
  still open (above).

### 6.6 SpO2 smoothed/stable - `0x70` `spo2_smoothed`/`spo2_stable` ; `0x7B` `spo2_stable_event` (6 B)
- `0x7B`: single **uint16 big-endian** at bytes 6–7. **(big-endian - exception to LE rule)** [ringverse]
- `0x70` present in tag dictionary as smoothed SpO2; layout **(UNVERIFIED)** - gate on fixtures. [ringverse]

### 6.7 SpO2 DC - `0x77` `spo2_dc_event` (variable)
- Byte 6: bit`[7]`=HDR low bit; bit`[6]`=`hasBase`; bits`[5:4]`=scale shift. [ringverse]
- If `hasBase`: bytes 7–9 = 24-bit LE base. [ringverse]
- Remaining: sign-magnitude int8 deltas; `v=(int8)raw; mag=|v|<<scale; out = v<0 ? -mag : mag`, accumulated. [ringverse]

### 6.8 Skin temperature
- **`0x46` `temp_event`** (10–18 B, even len): up to 7 samples, each **int16 LE ÷ 100 = °C**. [ringverse]
- **`0x69` `temp_period`** (6 B): single **int16 LE ÷ 100 = °C**. [ringverse]
- **`0x75` `sleep_temp_event`** (6–18 B, 30 s spacing): values **uint16 LE ÷ 100 = °C**, timestamps walk backward from event UTC. [ringverse]

### 6.9 HRV / RMSSD - `0x5D` `hrv_event` (even-length body, 5-min buckets)
- Body is a run of **`(u8 avg HR bpm, u8 avg RMSSD ms)` PAIRS**, one per 5-min bucket — HR at even byte offsets, RMSSD at odd; both **UNSIGNED, no scaling**. Decodes to nil on an empty or odd-length body. [oura-rs]
- **DECODE CORRECTION:** earlier drafts read a 4-byte `time_ms(2 LE) + int8 + int8` stride [ringverse]; that mis-framed the first byte-pair into a bogus `time_ms`, sign-flipped the RMSSD byte, and only its `b1` accidentally landed on a real HR byte. Corrected to the pair layout above and validated against a real overnight capture: the HR byte tracks sleeping HR (~52 bpm), matching the #511 IBI-derived median.
- **TAIL PADDING — a `00 00` pair is FILL, not a bucket.** A record that closes early (the last one before a disconnect, or at the end of a wear period) pads its tail with a `00 00` pair. Observed on a real Gen 3 overnight (2026-08-07, 22 records): 2 were partial and both padded — `48/128 47/137 46/171 47/159 48/176 0/0` and `54/75 54/61 55/45 0/0`. **NOOP rule:** skip a pair whose bytes are BOTH zero, at decode, so an absent bucket stays absent rather than becoming a fabricated `hr_bpm: 0` reading in the same series as real ones (#1128). The test is both bytes, not the HR byte alone: a lone zero beside a non-zero RMSSD has never been observed, and would be a different fault worth leaving visible. A skipped pair still CONSUMES its bucket index, because the consumer derives the bucket's wall-clock from that index and the record's pair COUNT (`bucketTs = ts - (count - index) * 300`, s6.9.1) — renumbering the survivors, or leaving the pad out of `count`, would slide every bucket in that record. Inferred from two partial records, not firmware-documented; a stricter rule would key off the record's declared length if that length is ever shown trustworthy.
#### 6.9.1 Bucket ORDER — the first pair is the OLDEST, and `ts` ends the span
- The record's **FIRST** byte-pair is its **OLDEST** 5-min bucket, and the record's own timestamp marks the **END** of the span it covers. So a bucket is placed at `bucketTs = ts - (count - index) * 300`, where `count` is the record's total pair count **including any `00 00` pad dropped at decode** — the LAST pair's five minutes end exactly at `ts`.
- This matches the two sibling per-record series rather than contradicting them: `0x6F` SpO2 lays its samples back from the record time (s6.5) and the sleep-phase burst lays its codes backward from its anchored end (s6.11). A bucket is an **INTERVAL** stamped at its start, not an instant, which is the one-cadence difference from SpO2's `count - 1 - index`.
- **DECODE CORRECTION (#1167):** NOOP previously used `bucketTs = ts - index * 300`, i.e. index 0 at the record time walking backward — which mirrors every bucket within its own record (up to +30 / −20 min out on a 6-pair record). Measured against an independent reconstruction (median HR of the `0x60` beats in each 5-min window — a different tag and a different decoder) over three consecutive Gen 3 overnights (2026-08-06/07/08): **r = +0.970 / +0.959 / +0.894** with the ordering documented here, against **−0.079 / +0.629 / +0.111** with the old one. Reversing within the same span (zero shift) collapses the best night to **+0.060**, and a ±900 s shift scan finds a single sharp optimum on this ordering and none on the old one — so it is the ORDER being measured, not a clock offset. Inferred from three captures on one ring; not firmware-documented.

- **NOOP note:** `0x5D` is the ring's own summary HR+RMSSD tag; NOOP also reconstructs RMSSD/SDNN itself from the IBI streams (`0x60`/`0x80`) for its own scoring (we do not consume Oura's encrypted scores). [open_ring][oura-rs]

### 6.10 Battery - `0x0D` response (8 B body)
- Layout: `percent, charging_progress, recommended_flag, 3 unknown bytes`. [open_oura-r3]
- Voltage as **uint16 LE at body offset [4..6]** per [open_ring]. **CONFLICT:** [open_oura-r3] reads percent at body[0]; [open_ring] reads voltage at [4]. **NOOP rule:** read percent at body[0]; derive a voltage-based estimate from [4..6] only as a fallback, fixture-validated per generation.

### 6.11 Time-sync ind - `0x42` (15 B)
- Bytes 6–13: an int64 LE epoch value; byte 14: int8 timezone offset in 30-min units (×1800 = seconds). [ringverse]
- **UNIT = unix SECONDS, not milliseconds.** [ringverse] documents this field as epoch milliseconds, but that citation is unverified and wrong: on real Gen 3 hardware the wire value is unix seconds. Treating it as milliseconds anchors every history-fetched sample to roughly Jan 1970 (about 1000x too early). **NOOP rule:** the decoder (`OuraDecoders.decodeTimeSync`) stays a faithful byte-level parse of the documented layout - `OuraTimeSync.epochMs` still names what the doc claims - but the driver multiplies the decoded value by 1000 before using it as the ms-scale UTC anchor (`OuraDriver`, the `.timeSync` ingest case). Treat this as a single-generation data point until a second ring/generation confirms it.
- **CRASH-SAFETY RULE: bounds-check any multi-byte wire arithmetic before use.** A full cursor-0 history dump (a ring never synced before) can surface a `0x42` record deep in the backlog whose raw epoch value is wildly implausible (near `Int64.max`) - a misaligned/corrupt record rather than a real time-sync (§2.4: "each notification contains whole frames/records" is the verified-corpus norm, not a guarantee). A naive seconds→ms `× 1000` on such a value overflows `Int64` and traps. **Any arithmetic on a raw multi-byte wire field must be plausibility-checked before use, never trusted as automatically well-formed.** NOOP's driver gates the time-sync / RTC-beacon anchor to a 2020–2035 unix-seconds window before converting (`OuraDriver.plausibleAnchorMs`), rejecting anything outside it as an undecodable record rather than crashing or anchoring to garbage.
- This is the primary UTC anchor (§5.5). [open_ring][ringverse]

### 6.12 Sleep architecture
- **`0x4B` / `0x4E` / `0x5A` `sleep_phase_details`** (≥19 B): byte6 = header; phase codes are **2-bit**, 4 per byte (bits `[7:6][5:4][3:2][1:0]`); codes **0=deep, 1=light, 2=rem, 3=awake** per open_oura's VALIDATED `decode_sleep_phases` (events.rs `PHASE = ["deep","light","rem","awake"]`). **CORRECTION:** an earlier revision of this line taught `0=awake, 1=light, 2=deep, 3=REM` from [ringverse] (unverified); live captures contradicted it (records decoded at wake carry code 3 = awake under open_oura's mapping), and both platform decoders inherited the bug from this exact text. [open_oura]
- **`0x6A` `sleep_period_info`** (14 B): bytes6–9 four int8 metrics; bytes10–11 `uint8/8.0`; byte12 motion-seconds uint8; byte13 sleep-state int8; bytes14–15 `uint16 LE / 65536`. [ringverse]
- **`0x72` `sleep_acm_period`** (16 B): values0–2 = `whole(8)+frac(8)/255`; values3–5 = `whole(4)+frac(12)/4095`. [ringverse]
- **`0x49` `sleep_summary_1`**: `start_offset_min` / `end_offset_min`, both uint16 LE **minutes
  before the event time** — the ring's tracked sleep window is
  `[event_utc − start_offset·60 s, event_utc − end_offset·60 s]`. [ringverse]
  **VALIDATED against NOOP captures 2026-07-12**: the `600/10` sample on the 7/11→12 night decodes
  to 23:30→09:20, matching the reconstructed 1196-code hypnogram (23:32→09:30 write-anchored) and
  the reported sleep (23:35–09:00). Earlier samples fit the same shape (688/101, 584/108, 716/164).
  Note the window END trails the SleepNet WRITE by `end_offset` minutes (10–43 min observed).
  **NOOP anchors the hypnogram burst end at `event − end_offset`** when a same-finalization 0x49
  (envelope ring-time within 10 min of the burst's) is present — the write-moment envelope shifted a
  whole reconstructed night +43 min on 2026-07-13 before this refinement; the 0x49 window matched the
  wearer's report within minutes (23:32→08:08 vs 23:34→08:03).
  **NOOP also clamps the burst START at `event − start_offset`** (2026-07-23): the SleepNet burst can
  write a few epochs BEFORE the 0x49 onset (7 min / 14 codes observed — reconstruct `22:48:58` vs the
  0x49 onset `22:55:58`), so the pre-window codes are clipped, symmetric with the end anchor. A clamp
  that would drop EVERY code (a mis-paired 0x49) is ignored, so it can never empty the night.
- **`0x76` `bedtime_period`**: start/end as uint32 LE ringTimestamps → map to UTC (§5.5). [ringverse]
- Tags `0x48,0x4A–0x4D,0x4F,0x57,0x58` are additional sleep summary/feature variants in the dictionary; layouts **(UNVERIFIED)** - decode only after fixtures. [ringverse]

**NOOP hypnogram reconstruction & persist (implementation).** The whole-night SleepNet phase codes
arrive as a BURST of `0x4E`/`0x5A` (and `0x4B`) records finalized after wake — all with near-identical
envelope ring-times (the WRITE moment, seconds apart), so arrival order is the code sequence, not a
sortable time. NOOP:
1. **Groups** consecutive phase records into one burst (envelope-gap grouping).
2. **Reconstructs the time axis** by laying the codes BACKWARD from the burst end at the 30 s SleepNet
   epoch: code *j* of *N* gets `ts = end − (N − j)·30 s` (each ts marks the start of its 30 s interval,
   the last interval ending exactly at the burst end).
3. **Refines BOTH ends with the paired `0x49` window** (closest envelope ring-time within 10 min): the
   END anchors to `event − end_offset·60 s` (the true sleep-end, ahead of the write moment) and the
   START clamps to `event − start_offset·60 s` (the onset), clipping the few pre-window codes. Both use
   only RING signals (the `0x49` window + the SleepNet codes); a clamp that would empty the night is
   ignored. The clip lives in the pure `OuraHypnogramBurst.codesWithTimes(…, sleepStartUnixSeconds:)`
   (unit-tested, both platforms).
4. **Anchors to UTC** via the session's `0x42`/`0x13` time-sync (§5.5); an unanchored burst is HELD
   until the anchor lands, never wall-clocked (the resume cursor only advances on an anchored persist).
5. **Persists** the anchored codes as a `CachedSleepSession` (`[{start,end,stage}]` breakdown) under the
   ring's OWN deviceId, so the imported-over-computed merge surfaces the ring's SleepNet staging as the
   night; the UI labels it **"Oura" / "raw on-device stages"**.

**FINDING — raw window vs the app's adjusted period.** The `0x49` window (hence NOOP's persisted window)
is the ring's RAW sleep window: it includes the edge AWAKE epochs (settling-in before sleep, lying awake
before rising). The Oura app / WHOOP display an ADJUSTED *sleep period* (first-asleep → last-asleep),
which is narrower — e.g. 2026-07-23: NOOP raw `22:56 → 08:21` (post start-clamp) vs a perceived/app
`~23:30 → 08:14`; the ~34 min onset gap is edge-awake the ring counts. This is the same raw-vs-adjusted
difference the "raw on-device stages" UI caveat surfaces.

**DESIGN DECISION — surface raw, do NOT NOOP-adjust.** NOOP persists the ring's window VERBATIM (only
reconciling the ring's own `0x49` window with its own SleepNet codes, above). It deliberately does NOT
trim the edge-awake to synthesize a "sleep period" — that would be NOOP post-processing the ring's
hypnogram, contradicting the ring-PROVIDED provenance and the "raw" label. If an adjusted/cleaned sleep
period is ever wanted, the consistent path is NOOP's OWN sleep staging from the raw signals (dense IBI
`0x60`/`0x80` + skin temp + motion), surfaced separately as an "On-device" computed night — never an
edit of the ring's tag.

### 6.13 Motion / activity

> **⚑ RECORDING IS MOTION-GATED — the ABSENCE of a record is itself the signal (NOOP, 2026-08-02,
> ground-truth validated).** The ring does not log on a fixed wall-clock cadence. When the wearer stops
> moving it stops emitting, and resumes the moment movement resumes. On a measured 86-min walk containing
> a deliberate ~3-min standing stop (17:49:16–17:52:17 UTC, per-second cadence from a Suunto `.fit`), all
> three streams went silent together across the stop, then returned to their normal 30 s cadence:
>
> | stream | normal cadence | gap across the stop |
> |---|---|---|
> | `0x7E`/`0x7F` real_steps | 30 s | **174 s** |
> | `0x47` motion | 30 s | **150 s** |
> | `0x50` activity/MET | 60 s | **240 s** |
>
> Three independent streams agreeing rules out a decode drop or a drain artifact. **Consequences for
> anyone consuming these streams:** (a) a gap must be read as "no motion", NOT as missing data to be
> interpolated over — interpolating manufactures activity that did not happen; (b) any "samples × cadence"
> total silently undercounts elapsed time and must not be used as a wall-clock duration; (c) it partly
> re-explains the "~6–19 min holes … ring's own logging cadence" noted for `0x50` below — quiet periods,
> not dropped records. It also means a stationary period yields NO rows to correlate, which is what
> defeats the step-decoder test in the ⛔ entry further down.

- **`0x47` `motion_events`** (variable): byte6 bits`[7:5]`=field_a, `[4:0]`=field_b; bytes7–9 = three **int8 × 8** axis magnitudes; optional bytes10–11. [ringverse]
  - **Persisted as an `OURA_MOTION` event (#834), instrumentation only** (never scored / staged): stored in the `event` table `(deviceId, ts, kind='OURA_MOTION', payloadJSON)`, each window anchored to its OWN ring-time. Payload keys are `orientation`, `motion_seconds`, `x`, `y`, `z`, and — **only when the record carried them** — `low_intensity`, `high_intensity`. The key set is therefore **NOT fixed**: a short (4-byte) record omits the two intensity keys rather than faking a `0`, so any reader must treat `low_intensity` / `high_intensity` as **optional**. Collision note: the event PK is `(deviceId, ts, kind)` and the insert is `ON CONFLICT DO NOTHING`, so two windows anchoring to the same UTC second would drop the later one. That spacing is **observed, not protocol-guaranteed** — the ring emits a motion window on a ~30 s base cadence (stretching longer when still, movement-gated). Evidence (one ring, on-device sidecar): across **2917 windows spanning ~49 h over 3 calendar days**, every window anchored to a **distinct** UTC second — **0** same-second pairs, **0** rows dropped; gap min **26 s** / median **30 s** (2296/2871 gaps exactly 30 s), tightest gap ~26× the 1 s a collision would need. Acceptable for instrumentation; if a future cadence spike ever collided, the loss is one diagnostic window.
  - **⛔ `low_intensity` / `motion_seconds` SATURATE — they are occupancy, not cadence (NOOP, 2026-08-02).**
    Both fields cap at **29** within a 30 s record. Across 168 records of continuous 4.6 km·h⁻¹ walking,
    65 % of `low_intensity` and 82 % of `motion_seconds` samples are pinned at ≥ 27, mean 26.4 / 27.0,
    max 29 / 29. They count **seconds containing motion**, not an amount or a rate of motion. `high_intensity`
    is near-dead for walking (mean 0.4, zero in 77 % of records) — it is a vigorous-movement flag.
    **Structural consequence: a step count or a cadence cannot be recovered from `0x47`, at any scale
    factor.** A signal that is pinned at its ceiling throughout the entire dynamic range of interest carries
    no information about how fast the wearer is moving — only that they are. This is an independent second
    reason (beside the ⛔ ground-truth test below) why steps are unreachable over BLE, and it applies to the
    Tier-A stream NOOP already trusts, so it will not be fixed by a better decode.
  - **⚠️ SCALE HYPOTHESIS: the `int8 × 8` axes are plausibly a ±1 g full-scale gravity vector — and the
    axis ORDER/POLARITY is unknown (NOOP, 2026-08-07).** Two independent consumers of the ring's
    **live accelerometer stream** — a path NOOP does **not** implement (`0x06` set-realtime with type
    bit `0x20`, responses under tag `0x33` carrying two samples of i16-LE x/y/z per notification, plus a
    sample-rate byte) — hardcode an accelerometer scale of **1024** counts/g [open_oura-viz] and **1000**
    counts/g, the latter annotated *"empirical: ~1000 at rest"* [open_oura-ctl]. Both agree within 2.4 %,
    and both are consistent with a **±2 g 12-bit range = 1024 counts/g**, which is also the `Acm2g50Hz`
    entry in that repo's RData data-type enum; both files independently assume **50 Hz**. If 1024 is
    right, `0x47`'s `int8 × 8` axes span −1024…+1016 counts = **exactly ±1 g at 8-count (≈ 0.0078 g)
    resolution**, i.e. the averaged vector is already gravity-scaled — which is precisely the calibration
    `OuraMotionDumpLine` records as missing before the vector can become a durable `gravitySample`.
    **Neither figure is a calibration:** one is a UI slider's default value, the other a single eyeballed
    at-rest reading in an unmerged fork. This stays a **CANDIDATE scale**, Tier B, and nothing may be
    scored on it.
  - **⛔ The three `0x47` axes stay DELIBERATELY UNNAMED — do not map them to X/Y/Z from any RE repo.**
    Axis identity is unresolved *upstream*, not just here: the two files above disagree on which axis is
    up. The visualiser takes gravity along **Y** (`pitch = atan2(up.z, up.y)`, and it carries an
    "invert vertical" toggle precisely because the polarity is unknown) [open_oura-viz]; the fork takes
    it along **Z** with the textbook tilt form (`pitch = atan2(−x, √(y²+z²))`, `roll = atan2(y, z)`)
    [open_oura-ctl]. That repo's own `0x47` decoder further states its axis order is *inferred from
    struct layout*. Of the two, the fork's formulation is the correct tilt maths (pitch taken against the
    magnitude of the other two axes) and is the one to re-derive from should NOOP ever need orientation —
    but the axis→field mapping itself remains unattested, so this spec names only "three `int8 × 8` axis
    magnitudes".
  - **Validation route that settles both, and needs no model.** Capture the live-ACM stream over (a) a
    still ring and (b) a moving one. At rest `|a|` **is** the counts-per-g, settling the scale and hence
    the ±1 g reading of `0x47`. Then compare a per-window deviation magnitude
    `|raw − lowpass(raw)| / counts_per_g` against the ring's **own** six MAD statistics in `0x72`
    `sleep_acm_period` (§6.12) for the same window — which cross-checks that decode at the same time
    (`0x72` is abundant: 5,723 records in the §10 corpus). Blocked on NOOP implementing the `0x06`
    realtime write: a **new outbound command to hardware**, so the BLE safety contract applies, and
    [open_oura-viz] notes real-time measurements *do not self-stop reliably* — a mandatory teardown write
    (`06 04 00000000`) and a time-boxed duration are part of the shape. Note also that `0x47` is
    movement-gated (no still sample ever arrives), so the lowpass/zero-velocity approach those files use
    on the live stream **cannot** be transplanted onto `0x47` records.
- **`0x6B` `motion_period`** (variable): byte6 = header — bits`[7:6]`=period_type, bits`[5:4]`=`count` of valid codes in the **FINAL** byte, bits`[3:0]`=a rolling mod-16 sequence counter (record ordering / dedup, not a state); byte7… = 2-bit MOTION_STATE codes, 4 per byte (MSB-first), the last byte carrying `count` codes where **`count == 0` means 4** (a full final byte — the 2-bit field can't hold 4, so 4 wraps to 0; all 81 `count == 0` records in a real capture have a non-zero final byte, never 0x00, confirming 0 ⇒ 4). MOTION_STATE enum: `0 NO_MOTION, 1 RESTLESS, 2 TOSSING, 3 ACTIVE`. Same shape as the `0x4E` sleep-phase layout (header byte, codes from byte7). The header's low-nibble sequence counter increments and wraps mod-16 across consecutive records in a real capture — pinning byte6 as a header and codes at byte7, correcting an earlier reading (byte6/7 a 12-bit period, codes from byte8) that dropped the first code byte and read phantom codes from the final byte's padding. Layout cross-checked against the native `parse_api_motion_period` (attribution, not a port — re-derived from the capture). [ringverse][open_ring]
- **`0x50` activity_info / `0x51`,`0x52` activity_summary**: activity category + intensity (MET-class). Layout **(UNVERIFIED - partial)**; [ringverse] notes real_steps/activity_info have unresolved constants. Gate on fixtures. [ringverse]
  - **`0x50` decode formula (PR #960 investigation, live Gen 3, 2026-07-02) [oura-rs]:** byte0 = a `state` code (activity-category, meaning unconfirmed); every following byte = one MET sample, `met = byte × 0.1` for `byte < 0x80`, else `met = 12.8 + (byte − 128) × 0.2` (two-slope: 0.1-MET resolution to 12.7, 0.2 steps above). **Plausible against six real Gen 3 captures** across two sessions - a full day from steady resting (0.9–1.1 MET) through a vigorous-activity burst (7.4 MET), everything physiologically sane, nothing negative or absurd - but **NOT ground-truth-validated** against the Oura app's own MET/step numbers. Stays Tier B: NOOP decodes it (`OuraDecoders.decodeActivityInfo` → `OuraEvent.activityInfo`, both platforms) but gates it behind `allowTierB`, logs it for investigation only, and never folds it into `OuraStreamMapping`/scoring - and NEVER derives a step count from it. `0x51`/`0x52` activity_summary stay fully undecoded (raw Tier-B bytes only).
  - **`0x50` MET cross-device validation (NOOP, 2026-07-15, live Gen 3):** the MET series TRACKS real activity
    intensity - three separate walks read mean ≈ 3.4–4.1 MET (p50 ≈ 4.4) against a sleep floor of ≈ 0.9 MET,
    and per-minute MET vs a Suunto `.fit` speed profile correlates **r = 0.89** (one walk, 13 min); the walk's
    Suunto Energy 196 kJ ≈ 47 kcal matched the recorded workout. It UNDERREADS water (swims read near-rest -
    optical/motion degraded). The stream is SPARSE with RING-SIDE cadence gaps (~86 % minute coverage on a
    choppy day; ~6–19 min holes that recur DURING an unbroken drain, so they are the ring's own logging
    cadence, not a decode drop) - so any daily active-minute total derived from it UNDERCOUNTS. This
    corroborates the "plausible, tracks activity" read while keeping it Tier B: still not a step count, still
    not ground-truth-validated against Oura's own numbers, still never scored. NOOP has no MET field in its
    HR/strain data model, so `0x50` remains a diagnostic JSONL corpus (`oura-activity-<id>.jsonl`); the ring's
    path into NOOP activity is HR (live push + banked IBI, §6.4), never MET. open_oura consumes this same
    `0x50` `met` as one input to its activity classifier (`activity_model.rs`). [open_oura-act]
  - **✅ `0x50` MET TRACKS A VARYING INPUT — the strongest validation to date (NOOP, 2026-08-02, live Gen 3).**
    The 2026-07-15 entry above showed MET correlating with speed over one 13-min walk; that is a *level*
    match and could not exclude a coincidental fit (§194). This test uses a **transition** the wearer
    deliberately created: an 86-min flat 6.5 km walk at 4.6 km·h⁻¹ containing a ~3-min standing stop,
    against per-second cadence from a Suunto `.fit`. MET falls to a resting floor exactly when the feet stop
    and recovers when they restart:

    | minute (UTC) | MET | true steps·min⁻¹ |
    |---|---|---|
    | 17:49 | 5.0 | 106 |
    | 17:50 | 2.8 | 24 |
    | 17:51 | **1.3** | **1.7** |
    | 17:52 | **1.2** | **0.0** |
    | 17:53 | 1.7 | 74 ← MET lags ~1 min on recovery |
    | 17:54 | 4.8 | 113 |

    Over the whole walk **r = 0.860** (n = 88 minutes) against true step rate, and — the part that matters —
    it is **robust**: dropping the 3 lowest-activity samples leaves r = 0.777 (contrast the `0x7E` field
    below, which collapses 0.912 → 0.256 under the same test). Mean 4.75 MET is physiologically correct for
    4.6 km·h⁻¹. The record count **independently re-confirms the 60 s cadence**: 86 MET samples for an
    86-minute walk, exactly 1·min⁻¹. Two caveats kept explicit: MET has a **~1 min recovery lag**, so it
    smears activity boundaries; and this validates that MET *tracks intensity*, NOT that the absolute MET
    scale is calibrated against Oura's own numbers — it stays Tier B and unscored.
  - **Walking-equivalent step estimate, scored against two reference devices (NOOP, 2026-08-02).** For the
    same walk, `activeMinutes × 100` (MET ≥ 3.0 → 82 active min) gives **8,200** against a measured
    **8,834** (Suunto `.fit` `total_cycles × 2`) and **7,868** (WHOOP, same walk): −7 % and +4 %. The
    estimate lands **between two commercial devices that disagree with each other by 11 %**, which is the
    realistic accuracy bar for any step figure. This does NOT promote the estimate: a walking-dominated
    window is the single regime a walking-equivalent model should do best in, and it does not overturn the
    857-day picture (median ≈ 0, p90 +186 %) that gates it. It is recorded because it bounds the error on
    the one regime where the estimate is meant to apply.
  - **Real Steps (feature `0x0B`) server gating [open_oura-feat]:** real_steps is behind the server flag `activity/real_steps` (default **false**; `FeatureDefinitions.ActivityRealSteps`, Gen 3+), the same server-flag-off pattern as SpO2 (§7.1). This explains `0x7E`/`0x7F` never once appearing across the PR #960 live sessions - the ring isn't sending them, it is not a NOOP decode gap. `0x50` itself is an always-on base stream (not feature-gated), matching it appearing in every session.
- **`0x7E`/`0x7F` real_steps_features 1/2** (18 B each): bit-packed step features merged across the paired events. **(UNVERIFIED - partial)** [ringverse]
  - **Unpack formula ([oura-rs] - Th0rgal/open_oura `crates/oura-protocol/src/events.rs#L566`, clean-room
    fact citation): 14 fields from the 14-byte body.** Fields 0 and 8 are genuine 9-bit values built as
    `byte*2 + carry_bit`, where the carry bit is stolen from the MSB of a neighboring byte (byte 3's MSB
    for field 0, byte 11's MSB for field 8) - the same byte then supplies field 3 / field 11 from its own
    low 7 bits. Fields 1, 2, 9, 10 are a bare `byte<<1` (no carry completion). Fields 4-7 and 12-13 are
    plain bytes. The source itself marks this decode `"_status": "unvalidated"`.
  - **Wired into a decoder (both platforms, Tier B) and cross-correlated against a real capture**
    (2026-07-30, 2661 real_steps pairs anchored against the already-anchored 0x50 MET corpus from the
    SAME session): `fields[0]` and `fields[8]` - the two carry-completed 9-bit values - are the ONLY
    fields with a consistent movement correlation (r≈+0.3 vs mean MET; effect size +1.5/+1.25
    resting-vs-moving on the same capture). This is a real convergence between the bit-layout hint (these
    two fields are structurally distinct from the other 12) and the empirical signal. Cadence is fixed:
    300 ring-ticks (30 s) between consecutive pairs. **Superseded in part by the ground-truth test below**
    - the movement correlation is real, but the "leading candidate for the step field" reading is WRONG.
  - **⛔ GROUND-TRUTH TEST — NO FIELD IS A STEP COUNT (NOOP, 2026-08-01, first real ground truth).**
    A measured **13,349 steps** (independent device, worn on the SAME wrist, 08:00–15:58 local / 06:00–13:58
    UTC, a golf round) tested against 805 paired records in that window, with 8.5 h of that night's sleep
    (true steps ≈ 0) as the control:
    - **Every one of the 14 fields is large and non-zero during sleep.** `fields[0]` alone sums to 111,736
      across the night; the smallest, `fields[3]`, sums to 38,845 asleep vs 15,095 golfing - i.e. HIGHER
      asleep. No scaling, offset or unit conversion reconciles any field with 13,349.
    - **No cumulative counter exists on the wire.** Every byte offset read as u8 / u16LE / u16BE / u24LE /
      u32LE, both tags, 5,122 records: **zero** monotonic (non-decreasing) sequences. Confirms and
      strengthens the earlier "no running total" note.
    - **A count-of-active-windows × cadence reconstruction also fails:** thresholding `fields[0]` at
      200/250/300/350/400 needs 39/44/48/67/212 steps·min⁻¹ sustained to reach 13,349 - every one
      physiologically wrong for walking (real cadence ≈ 100–120), i.e. the threshold is dominated by
      non-walking windows. Fitting a threshold AND a cadence to a single ground-truth day would be
      manufacturing a match, not decoding one (the §194 precedent).
    - **What the fields ARE:** exactly what the tag name says - `real_steps_FEATURES`, the *inputs* to a
      step-detection model, not its output. That is why they are always populated: they are continuous
      signal statistics computed every 30 s whether walking or asleep. Ranked by movement discrimination
      (sleep vs golf, Cohen's d): `f8` **+2.37**, `f0` **+2.35** (≈15 % distribution overlap), `f6`
      **−1.65** (inverse - a stillness feature), `f2`/`f10` +1.21, `f3`/`f11` −1.03; the remaining seven
      are near-flat (|d| ≤ 0.75). So `f0`/`f8` are genuine movement-intensity features - useful as an
      activity signal, useless as a count.
    - **Conclusion: a step count is NOT recoverable from `0x7E`/`0x7F` alone.** It would require
      reimplementing Oura's step model over these features, unvalidatable without many ground-truth days
      across varied activity. This closes the "decode steps from real_steps" line of investigation; `0x50`
      MET (above) already provides an activity signal with a validated cadence.
  - **⚠️ A SECOND ground-truth walk did NOT rehabilitate the fields — and shows how a fake r = 0.91 arises
    (NOOP, 2026-08-02).** An 86-min walk with per-second Suunto cadence gave 165 in-session `0x7E` records.
    Naively, `fields[0]` correlates with true steps at **r = 0.912** — which would look like a decisive
    result and is exactly the trap §194 warns about. It is an artifact, for two compounding reasons:
    - **The input barely varied.** A flat 6.5 km at constant 4.6 km·h⁻¹ produces true steps per 30 s window
      of p05 = 51.1, median = 55.2, max = 58.1 — 98 % of samples are effectively identical. Almost all the
      apparent correlation rests on the 3–4 transition samples at the stop. **Dropping the 3 lowest-step
      samples collapses r from 0.912 to 0.256**; restricted to the walking regime alone r = 0.355. A signal
      that only "works" via a handful of points has not been shown to track anything.
    - **The stop produced no rows to correlate.** Because recording is motion-gated (⚑ note at the top of
      §6.13), the ring emitted NOTHING for 174 s across the stationary period — the one interval with real
      contrast is precisely the interval with no data. At the single surviving low-motion sample
      `fields[0]` reads 177 vs 365 walking: it **halves, it does not go to zero**. A counter zeroes.
    - **Net: consistent with the fields being model features, not counts.** This walk neither refutes nor
      supports a decode — it simply cannot discriminate, and is recorded so the r = 0.91 is not
      rediscovered later and mistaken for validation. **A useful test needs cadence VARIATION** (mixed
      slow/fast walking, stairs, walk/jog intervals), not a longer metronomic walk.
  - **WHY there is no step count on the wire at all — the sensor side (NOOP, 2026-08-02).** Recorded so
    this is not re-investigated:
    - **The Gen 3 IMU is a Bosch Sensortec BMI160** (public teardowns: [TechInsights], [System Plus]). That
      part *does* have a hardware pedometer — a 16-bit `STEP_CNT` register at `0x78`–`0x79` plus a
      step-detector interrupt ([BMI160 datasheet] §2.11.36).
    - **It is not transmitted.** Over a full-day capture, every tag with ≥50 records was tested at every
      byte offset as u16LE / u16BE / u24LE / u32LE for a non-decreasing sequence. The only two hits were
      artifacts: `0x6D` byte 2 is a constant `0xFFFF` padding field (2 distinct values across 867 records),
      and the `0x73` hit is Exercise-HR trace data. **No monotonic counter exists in any tag** — the
      BMI160's step count never leaves the ring.
    - **Consistent with Oura's own description:** Oura documents "Real Steps" (shipped March 2025) as a
      **machine-learning model** deciding "when ring movement is a step" ([Oura blog]). A stock IMU
      pedometer assumes wrist/pocket gait and mis-fires on a finger (a gesturing hand resembles walking),
      so the generic `STEP_CNT` is the wrong tool for a ring — plausibly why it is unused and why a trained
      model exists instead.
    - **So `0x7E`/`0x7F` carrying that model's INPUTS, with the count produced downstream of the ring, is
      the coherent reading** — matching the ground-truth result above, the tag name
      (`real_steps_features`), and the absence of any counter on the wire. Accurate steps are available
      only from Oura's own export/API, not over BLE.
  - **🐛 `0x7F` IS NOT THE SAME LAYOUT AS `0x7E` — its payload is offset by +2 bytes (NOOP, 2026-08-01).**
    The pairing is exact (2561/2561 records, `0x7F` always at the `0x7E` record's `rt + 1`), and both bodies
    are 14 B, but the FIELD LAYOUT differs. Aligning `0x7F`'s per-byte statistics onto `0x7E`'s over 5,122
    records scores a **+2 shift** at total error 19.0 vs 58.6 for the next-best offset (a 3× separation);
    at that shift the per-byte mean, standard deviation AND MSB-set rate all match:

    | | b0 | b1 | b2 | b3 | b4 | b5 |
    |---|---|---|---|---|---|---|
    | `0x7E` mean / sd / MSB | 125 / 54 / 48 % | 110 / 72 / 39 % | 82 / 39 / 10 % | 94 / 71 / 50 % | 74 / 24 / 4 % | 67 / 39 / 4 % |
    | `0x7F` **bytes 2–7** | 124 / 54 / 48 % | 114 / 72 / 42 % | 82 / 38 / 10 % | 97 / 71 / 52 % | 74 / 25 / 4 % | 67 / 38 / 4 % |

    The carry-bit test is decisive: the unpack takes field 0's 9th bit from byte 3's MSB and field 8's from
    byte 11's, and a real carry bit is ~50 % set. `0x7E` reads **49.7 % / 49.0 %** ✓. `0x7F` at the CURRENT
    (unshifted) offsets reads **41.6 % / 17.5 %** ✗ - byte 11 at 17.5 % is plainly a data byte, not a carry
    bit. At the +2 shift `0x7F` reads **51.6 % / 45.3 %** ✓.
    - **What the old (unshifted) decode produced for `0x7F`'s `fields[0]`/`fields[8]`:** garbage - it stole
      the 9th bit from the wrong byte. Measured on the same sleep-vs-golf control, `0x7F.fields[0]` decoded
      to an **INVERTED** movement signal (d = **−1.72**, sleep 255.9 > golf 121.8); re-unpacked at +2 it
      becomes **+2.36** (sleep 146.9, golf 321.4) - statistically identical to `0x7E`'s own +2.35
      (147.4 / 322.8). Paired-window agreement `7E.f0` vs `7F.f0` goes from **r = −0.557** to **r = +0.790**.
    - **Corroborated three ways**, all on the same 5,122-record capture: (a) the ground-truth sleep-vs-golf
      contrast, mean |Δd| from `0x7E`'s reference 1.59 → **0.26** (fields 0-9: 1.62 → **0.11**); (b) an
      INDEPENDENT contrast (same night vs the previous afternoon, no golf data), 1.27 → **0.26** (fields 0-9:
      1.31 → **0.14**); (c) a window-free per-field distribution match over all records, where **+2 wins
      12/12 fields** - fields 0-7 match `0x7E`'s mean AND standard deviation to ~1 %.
    - **This retracts the "movement-correlated fields present in both [tags]" claim above** - that was read
      off the buggy `0x7F` decode. The two tags carry the SAME feature types at DIFFERENT byte offsets, not
      two different feature families.
    - **CONFIDENCE TIERS for the corrected `0x7F` decode** (same evidence): **fields 0-7 validated**
      (distribution ~1 %, Δd ≤ 0.13 on two contrasts); **field 8 likely right** (d +2.82 vs `0x7E`'s +2.33,
      r = +0.854, but its mean is offset); **fields 9-11 uncertain** (improve but do not converge). The
      degradation past field 7 is consistent with the block being truncated by the 14-byte record boundary.
    - **NOOP applies the +2 offset for `0x7F`** (`OuraDecoders.realStepsFieldOffset`, both platforms), so
      `0x7F` now yields **12 fields, not 14**: fields 12/13 would need record bytes 14/15, which do not
      exist, and are OMITTED rather than zero-filled (a fabricated zero is indistinguishable from a real
      one). All 12 are still emitted because the only consumer is the Tier-B research sidecar.
    - **Open:** `0x7F`'s bytes 0–1 are high-entropy data (199/204 distinct values), NOT a low-entropy header,
      and they do not continue `0x7E`'s bytes 12–13 (|r| ≤ 0.47). Their meaning is unknown.
  - Still Tier B end to end: decoded only behind `allowTierB`, logged once per session + appended to a
    diagnostic JSONL sidecar (`oura-real-steps-<id>.jsonl`, deduped by ring-time), never folded into
    `OuraStreamMapping`/scoring - not even from fields[0]/fields[8], which the ground-truth test above now
    shows are features, not counts. `OuraDecoders.decodeRealStepsFields` (Swift) /
    `Decoders.decodeRealStepsFields` (Kotlin), which apply the tag-dependent block offset above.

### 6.14 Raw PPG
- **`0x67` raw_ppg_summary** (12–13 B): start-UTC, type, scale, session header for following data. [ringverse]
- **`0x68` raw_ppg_data** (variable, delta-encoded): needs scale/accumulator from the paired `0x67`. [ringverse]
- **`0x81` cva_raw_ppg_data** (variable): delta + 24-bit absolute, session-stateful. Decode: byte `0x80` → next 3 bytes absolute u24 (LE); MSB-set byte → signed delta `b-0x100`; else signed 7-bit delta (`b-128` when `b>=64`, else `b`). Reset on ring-reset ack or 60 s gap. [open_ring] **First live observation 2026-07-30** (668 records, 18 B each) — in the same Advanced/Auth-Key-pairing + SpO2-enabled session as the `0x03`/`0x04` unlock (§3.7), i.e. this tag is server-gated like them.
  - **Wired into a decoder (both platforms, Tier B) and validated against a real capture** (2026-07-30, a
    2169-record Gen 3 session, plain NOOP pairing - no Advanced-key handshake in that session's log,
    server-gated-unlock persistence not otherwise investigated here): chaining the running total across
    records the whole session yields a SMOOTH series (median sample-to-sample jump 33, baseline
    ~390-400K counts) consistent with a real PPG channel, not noise - the strongest evidence yet that the
    [open_ring] formula's core (LE u24 absolute anchor + delta walk) is right. 4-of-22745 samples show an
    anomalous jump to ~8.39M and back within 2 anchor reads, cause not yet explained (candidates: a
    genuine sensor artifact, or the anchor's 3-byte field not being plain LE in that instance) - left
    unresolved, Tier B stays UNVERIFIED.
  - **Split markers are common, not exceptional:** in the same capture, roughly a quarter of records end
    on a `0x80` marker with fewer than 3 trailing bytes (the absolute value would span into the next BLE
    notification). Per this codebase's one-packet-per-notification / no-cross-notification-buffering rule
    (`Framing.swift` / `Framing.kt`), the decoder stops at the marker instead of guessing into the next
    notification - samples already decoded earlier in the record are still returned, honestly.
  - **"Ring-reset ack" is not a distinct documented opcode.** NOOP's decoder invalidates the running
    total on the 0x41 `ring_start_ind` lifecycle marker (the same signal that already invalidates the UTC
    anchor on rt regression) as the closest wire analogue - a best-current-interpretation, not a
    wire-confirmed mapping.
  - Still Tier B end to end: decoded only behind `allowTierB`, logged once per session + appended to a
    diagnostic JSONL sidecar (`oura-cva-ppg-<id>.jsonl`, deduped by ring-time), never folded into
    `OuraStreamMapping`/scoring. `OuraDecoders.decodeCvaRawPPG` (Swift) / `Decoders.decodeCvaRawPPG`
    (Kotlin).

### 6.15 Lifecycle / state
- **`0x41` ring_start_ind** (18 B): bytes6–10 = 40-bit device id; bytes15–19 config; triggers anchor invalidation on rt regress. [ringverse][open_ring]
- **`0x43` debug_event**: ASCII text (state strings). [open_ring][open_oura-r3]
- **`0x45` state_change_ind / `0x53` wear_event**: byte6 = STATE_* enum; optional trailing UTF-8 string if payload>5. STATE enum: `0 unspecified,1 not_in_finger,2 finger_detection,3 user_active,4 user_in_rest,5 hr_user_active,6 hr_user_in_rest,7 out_of_power,8 charging,9 hibernate_low_power,20–22 production,30 hw_test`. [open_ring]
  - **NOOP wear/charge signal (2026-07-19, both platforms):** the numeric enum is unreliable in captured data — the byte reuses a value across meanings (observed: code 5 as both `"hr enable"` and `"motion det"`; code 3 as `"fea off"` and `"motion det"`) — so NOOP keys on the optional trailing STRING. `"chg. detected"` / `"chg. stopped"` bracket an on-charger interval. Combined with the live-HR push (a beat streams only from a finger → WORN) and a live-HR silence watchdog (stream quiet past a grace window → REMOVED), this drives the On-wrist / Off-wrist indicator. There is NO dedicated "worn" event — see `0x86` below.
- **`0x86` `aohr_event` (NOT observed in NOOP):** open_health's `unvalidated-events.md` documents a `0x86` aohr record that "appears when worn", but that decoder is confirmed by CODE (ported from `libringeventparser.so`), not data — it has **never appeared in a NOOP capture** (0 records across the corpus; the ring does not emit it in the NOOP-only, no-server-gated-daytime-HR configuration). Wear is inferred from the live-HR stream + the `0x45/0x53` charger strings above, never from `0x86`.
- **`0x85` rtc_beacon_ind** (10 B): `unix_s:u32 LE`, reserved 4 B, trailer u16 LE ∈ {`0x01F6`,`0x01F8`}. [open_ring]

---

## 7. Per-Generation Capability + Difference Matrix

### 7.1 Feature IDs (write target for `0x2F…0x20/0x22/0x26`) [ringverse][open_oura-feat]
| ID | Feature | Gating |
|---|---|---|
| `0x00` | Background DFU | - |
| `0x01` | Research Data (RData) | often server-blocked; returns idle status 3 [open_oura-r3] |
| `0x02` | Daytime HR | Gen3+; **live-HR path (§5.6)** |
| `0x03` | Exercise HR (AWHR) | Gen3+; cap version ≥ 2; data arrives as `0x73` `ehr_trace_event` / `0x74` `ehr_acm_intensity_event` [ring4-ble]. **Gating is per-account, not per-ring/firmware:** a 2026-07-20 capture on stock NOOP-only pairing saw zero `0x73`/`0x74` (server-gated, like SpO2/steps below); a **2026-07-30 capture on the same physical ring, paired via the ring's own Advanced/Auth Key extracted from the real Oura app (§3.7) with SpO2 subsequently enabled in that app, observed 1023×`0x73` + 220×`0x74` records** in a single session. Pairing through the genuine app-issued key inherits that account's actual cloud `ClientConfiguration` (see `0x04` below), which evidently unlocked a feature bundle beyond just SpO2. Payloads: `0x74` is 14 B / 7×uint16-LE, a monotonic ramp (`001e 0048 006f 0099 00bc 00d0 00e2` → 30,72,111,153,188,208,226) consistent with an intensity trace; `0x73` alternates 18 B/9 B record lengths. Still **UNVERIFIED layout** — decode-only, not wired into scoring. |
| `0x04` | SpO2 | Gen3+; server-gated. **Confirmed OFF on a real Gen 3 ring** (2026-07-20 capture): the read-only `2f 02 20 04` feature-status probe NOOP ships (`spo2_status`, §7.4) decoded to `mode=0 status=0 state=0 subscription=0` - all-zero, i.e. the cloud never enabled SpO2 for that ring/account; it is not a NOOP decode issue. SpO2 also never arrives as a live push (unlike HR's feature `0x02`); it only ever arrives via history fetch (§5), same as skin temp. NOOP sends the diagnostic READ only; it does NOT enable/subscribe SpO2 (a live enable produces nothing during the day regardless). **2026-07-30, same ring, after enabling SpO2 in the real Oura app and pairing via its Advanced/Auth Key:** the same probe now reads `mode=1 (automatic) status=0 state=0 subscription=0` — `mode` flips 0→1 once the account entitlement is on, even though `status`/`state` stay 0 outside an active SpO2 session. Confirms gating tracks the Oura-cloud account config, not the ring hardware or NOOP's own commands. |
| `0x05` | Bundling | - |
| `0x06` | Encrypted API | (Oura's encrypted channel - NOOP does NOT use) |
| `0x07` | Tap-to-tag | - |
| `0x08` | Resting HR | firmware-computed, no app toggle |
| `0x09` | App auth | the §3 handshake feature |
| `0x0A` | BLE mode | - |
| `0x0B` | Real steps | Gen3+; server-flag-gated (`activity/real_steps`, default false). **Confirmed OFF on a real Gen 3 ring** (2026-07-20 capture): the read-only `2f 02 20 0b` probe (`realsteps_status`, §7.4) decoded to `mode=0 status=0 state=0 subscription=0` - all-zero, matching SpO2, which is why `0x7E`/`0x7F` never appear (§6.13). **2026-07-30, same ring, after enabling SpO2 + Advanced/Auth-Key pairing (see `0x04` above):** the probe now reads `mode=1 (automatic) status=1 state=2 subscription=0` — no longer all-zero, though `0x7E`/`0x7F` still weren't seen in that session. Same per-account gating mechanism as `0x03`/`0x04`, not a NOOP-side change. |
| `0x0C` | Experimental | server-flag-gated |
| `0x0D` | CVA PPG sampler | Gen3+; server-flag-gated; feeds `0x81` |
| `0x0E` | Charging control | [ring4-ble] |
| `0x0F` | Ambient light | capability-dependent [ring4-ble] |
| `0x10` | Special feature | [ring4-ble] |
| `0x11` | Raw-data sampler | [ring4-ble] |
| `0x12` | Atlas | [ring4-ble] |
| `0x16` | Long events | [ring4-ble] |

> **CORRECTION** [ring4-ble]: an earlier draft placed **Ambient light** at `0x10`; the APK enumerates `0x0F` = ambient_light and `0x10` = special_feature. The `0x0E`–`0x16` rows above are the APK's full feature list (22 features `0x00`–`0x12` + `0x16`).

**Feature modes** (write byte of `2f 03 22 <id> <mode>`): `0x00` off, `0x01` automatic, `0x02` requested, `0x03` connected_live. [ring4-ble] — an earlier draft read `0x03` as "requested-subscription" [ringverse]; the APK's `connected_live` is authoritative (it is the mode NOOP writes to enable the live-HR push, §5.6).
**Subscription modes** (write byte of `2f 03 26 <id> <sub>`): `0x00` off, `0x01` state, `0x02` latest, `0x04` feature_specific_data. [ring4-ble] — NOOP subscribes live HR with `0x02` = latest.
**Feature request-status** (result code of a `setFeatureMode` command): `0x00` success, `0x01` not_supported, `0x02` not_available, `0x03` not_in_finger, `0x04` message_too_short, `0x05` low_battery. [ring4-ble]
**Feature status/state values** (the `status`/`state` bytes of the `0x21` read reply, §7.4): `0x00` off, `0x01` on, `0x02` searching, `0x03` no-PPG, `0x04` cold, `0x05` movement, `0x06` identifying. [ringverse]
**Master gate:** `setFeatureMode` requires ring generation **> 2** (Gen 3+); Gen ≤2 reject all feature-mode changes. [open_oura-feat]

### 7.2 Generation differences

| Capability | Gen 3 (Horizon) | Gen 4 | Gen 5 |
|---|---|---|---|
| Service/char `…0001/2/3` | yes | yes | yes [open_oura-r5] |
| Extra chars `…0004/5/6` | no | no | **yes** (roles unconfirmed) [open_oura-r5] |
| MTU | 203 [open_oura-r3] | 247 [open_ring] | 247 [open_oura-r5] |
| Framing (TLV §2) | same | same (verified vs ~953k records) [open_ring] | same [open_oura-r5] |
| Auth handshake (§3) | same | same | same; control cmds need per-conn auth, fw/serial read unauth [open_oura-r5] |
| Opcode/sub-op set | same | same | same - no new opcodes/tags [open_oura-r5] |
| Event-tag dictionary | same | reference set [ringverse] | same [open_oura-r5] |
| Live-HR feature `0x02` (§5.6) | **verified** [relue] | expected same | expected same |
| Feature-mode (`>Gen2`) | yes | yes | yes [open_oura-feat] |
| Firmware string fields | API/FW/BL/BT/MAC | same | same/extended [open_oura-r5] |
| Test firmware in corpus | FW 3.4.3 | (Ring-4 verified corpus) | FW 2.1.3 [open_oura-feat] |

### 7.3 NOOP decoder build guidance
1. **Single TLV parser** (§2.3) for all generations - the framing is generation-invariant. Branch only on: MTU clamp (203 vs 247) and Gen-5 extra-char presence (ignore in v1).
2. **Generation detection:** read product info (`0x18 03 18 00 10`) → hardware id (e.g. `BLB_03`), and firmware (`0x08`). Map to Gen 3/4/5 to set MTU and pick verified-vs-unverified layout confidence.
3. **Trust tiers in the decoder:** Tier A (verified, ship now) = TLV framing, auth, GetEvents cursor, live-HR `0x02`, `0x60`/`0x80` IBI, `0x46`/`0x69`/`0x75` temp, `0x6F`/`0x7B` SpO2, `0x42` time-sync, `0x0D` battery, `0x45`/`0x53` state, `0x6B` motion. Tier B (UNVERIFIED, fixture-gate before use) = `0x49/0x4C/0x4F/0x57/0x58` sleep summaries, `0x50/0x51/0x52` activity-MET, `0x7E/0x7F` steps, `0x70` smoothed SpO2, the protobuf `0x55/0x59` interpretation (do **not** ship). (`0x4B` was reclassified out of the summaries — it is a Tier-A phase hypnogram, see §4.)
4. **HRV/sleep:** consume the ring's `0x5D` (HRV) and `0x4B/0x4E/0x5A` (2-bit phase codes; `0x4B/0x4E/0x5A => decode_sleep_phases` in open_oura) tags AND independently reconstruct from raw IBI/PPG for NOOP's own scoring. Never read Oura feature `0x06` (encrypted API).

### 7.4 Feature-status probe (read-only diagnostic)
NOOP ships a **read-only** probe that asks the ring to report a feature's own status, so an absent signal can be attributed to the server gate *from the ring's own mouth* rather than guessed. It sends the READ verb only — `2f 02 20 <id>` (sub-op `0x20`, the same verb as the live-HR `dhr_read` step, §5.6) — and **never** the `2f 03 22 <id> <mode>` set-mode/enable write. The `0x21` reply body decodes as five bytes: `feature, mode, status, state, subscription` (per §7.2 tables).

- **Shipped probes:** `spo2_status` (`2f 02 20 04`) and `realsteps_status` (`2f 02 20 0b`), sent once after `get_battery` on each connect; logged once per feature, never stored or scored.
- **All-zero = server-gated OFF.** A gated/unavailable feature reads back `mode=0 status=0 state=0 subscription=0`. Contrast the *streaming* daytime-HR (`0x02`), which reads `mode=1 status=0x11 state=2` — so **all-zero mode/status/state is the gated signature**, not `subscription==0` alone (daytime-HR is `subscription=0` yet active).
- **2026-07-20 Gen 3 capture:** both SpO2 (`0x04`) and real_steps (`0x0b`) returned all-zero — confirming §7.1 on live hardware. No local `setFeatureMode` can flip these; the gate is the Oura cloud `ClientConfiguration`, not the ring or NOOP.

---

## 8. Open Implementation Items (for the team)
- Confirm Ring-5 `…0004/0005/0006` roles before writing to them (currently unused).
- Resolve the `0x0D` battery percent-vs-voltage offset per generation via captured fixtures (§6.10).
- Validate all Tier-B sleep/activity/step layouts against real captures before enabling in scoring.
- Confirm live-HR `0x02` path on actual Gen-4/Gen-5 hardware (only Gen-3 is verified in the corpus).
- `0x68` and `0x86` are NOT emitted in the NOOP capture (0 of ~131k records) — do not hunt for them; wear inference uses `0x45/0x53` + live-HR (§6.15) and the `0x86` aohr never appears (§6.15).
- **A step-decoder test needs cadence VARIATION, not more walking.** Both ground-truth sessions so far
  (2026-08-01 golf, 2026-08-02 flat walk) were near-constant-cadence, which cannot discriminate a candidate
  step field from a generic movement feature — the 2026-08-02 walk produced a spurious r = 0.912 that
  collapses to 0.256 under a 3-sample drop (§6.13). Any future attempt should capture mixed slow/fast
  walking, stairs, or walk/jog intervals with a per-second reference, and must clear the robustness test
  (r must survive dropping the extreme samples) before being reported as a result. Note this is a test of
  the *features*, not a route to a count: §6.13 records two independent structural reasons a count is not
  on the wire at all.

---

## 9. Observed-but-undecoded tags (raw examples, NOOP Gen-3 corpus, 2026-07)

Tags that appear in the banked stream but NOOP does not decode. Payloads are the bytes AFTER the 6-byte
`type/len/rt` header, recorded verbatim for future RE — these are OBSERVATIONS, not confirmed layouts.

| tag | count | len (B) | example payload | shape hint (UNCONFIRMED) |
|---|---|---|---|---|
| `0x61` | 28760 | 3–14 | `1a18009c3700007c150000cb` | **SOLVED as a channel, see §9.1** — a subtype-multiplexed firmware DIAGNOSTIC stream, not one message and not a physiological signal. **NOT battery** — the `[open_oura-act]`-adjacent "`0x61` battery" label does not match here (non-percent, high-frequency) |
| `0x4a` | 8416 | 10 | `00000000000000000000` | payload observed all-zero — likely a keepalive / placeholder |
| `0x72` | 5723 | 12 | `120027000100150018000200` | six int16-LE small values — a vector (motion / accel?) |
| `0x6a` | 5689 | 10 | `7e00230b90140001f8b0` | mixed; a `0001f8b0` / `0001feb8` trailer recurs |
| `0x6d` | 3042 | 13 | `00c4ffffb5ffffd2ffffeaffff` | **`measurement_quality`** (24-bit signed) per [ring4-ble] — supersedes the earlier gravity/accel guess; our capture reads `00` + int16-LE-looking negatives |
| `0x6c` | 1750 | 4 | `02020400` | `02 NN 04 00` — small state / counter |
| `0x5b` | 416 | 10–13 | `030093dd10dbc7c00000` | variable, leading sub-type byte |
| `0x79` | 100 | 4–14 | `02000000` | `02` + an incrementing index (`00, 01, 02…`) |
| `0x76` | 8 | 8 | `4c876b00c0667000` | two u32-LE that look like ring-times — a window (start / end)? |
| `0x5c` | 6 | 4 | `284b02b0` | **constant** across every occurrence — a fixed marker / config |
| `0x56` | 1 | 1 | `01` | singleton |

Full-notification hex including the `type/len/rt` header is in the capture. For the highest-rate tags,
several full records are reproduced below (`type len rt(u32LE) | payload`) so a future RE pass sees the
record framing and cross-sample variation directly — a single stripped example once hid a truncated
prefix and tail fields. Note `0x61`'s payload length is **not fixed** (the `len` byte moves 0x10/0x11/0x12)
— §9.1 explains why: the length follows the subtype.

- `0x61` (highest-rate): `6110 ff756600 | 1a18009c3700007c150000cb` · `6111 00766600 | 23230000090000fd02003a0000` · `6112 f9766600 | 095b914700e9e00000fe81010005`
  (these three are subtypes `0x1a`, `0x23`, `0x09` — one example per message, which is exactly why the
  layout looked variable)
- `0x72` (`len` 0x10, 6×int16-LE): `7210 499b6b00 | 120027000100150018000200` · `7210 729c6b00 | 130029000100150018000200` · `7210 9c9d6b00 | 05000e000200160019000500`
- `0x6d` (`len` 0x11, leading `00` + 4×int16-LE negatives): `6d11 ec856600 | 00c4ffffb5ffffd2ffffeaffff` · `6d11 98976600 | 00b2fffffaffffeeffffd9ffff` · `6d11 419d6600 | 00a1fffffaffffd9fffff5ffff`
- `0x76`: `760c c2cf7100 | 4c876b00c0667000`

### 9.1 `0x61` is a subtype-multiplexed firmware diagnostic channel (2026-08-05)

Measured on the **first raw-writer capture** (`oura-raw.jsonl`, iOS build `9.3.1`,
`noop-master-iOS-v9.3.1-260805-0754`): **10,208 × `0x61`** of 84,815 records, ring-time span
9,391,251 → 10,105,610, every frame `len == bytes − 2`.

**Independently corroborated by the name:** [open_oura]'s `EVENT_TAGS` map (`tools/oura_protocol.py`,
derived from the ring's own event-parser library) lists `0x61` as **`debug_data`** — cited as a fact,
no code taken. The structure below is NOOP's own measurement of what that debug channel contains.

**Payload byte 0 is a SUBTYPE selector; the length follows the subtype.** 22 subtypes observed. This is
why every attempt to fit one layout failed and why the count/length column above reads as a range — the
earlier corpus was averaging ~22 different messages together.

**Proof it is a log channel: subtype `0x04` is ASCII.**

```
04 4d4f5420524920323b32    → "MOT RI 2;2"
04 45485274733b3633        → "EHRts;63"
04 547366733b3131          → "Tsfs;11"
04 626c655f74783a66756c6c  → "ble_tx:full"
```

These are the same class of firmware log line `0x43` `debug_text` already carries (`DHR_state:4`,
`PPG_cont;220`, `EHRst;1;0;1`, `CVA_state;2`), so `0x61` is a **second** diagnostics stream, keyed by
subtype rather than free text. `EHRts;N` appears in the same capture where Exercise-HR (`0x73`/`0x74`,
§7.1) was flowing.

| sub | n | layout (UNCONFIRMED) | median rt cadence | observed range |
|---|---|---|---|---|
| `0x09` | 2,104 | 3 × u32-LE + 1 tail byte | 11 | f0 med 3.1 M / max 124 M |
| `0x28` | 2,070 | flag + 6 × u16-LE | **1** | repeated identical values (`780,0,0,0,780,780`) |
| `0x33` | 1,399 | 8 B and 14 B variants | 3 | |
| `0x0a` | 1,066 | 3 × u32-LE | 729 | f2 always 0 |
| `0x0d` | 1,062 | 3 × u32-LE | 729 | f1 always 0; f2 max 125,829,080 |
| `0x0c` | 1,060 | 2 × u32-LE + 1 tail byte | 729 | f0 max 125,829,085 |
| `0x29` | 507 | 8 B | 658 | |
| `0x14` | 435 | 3 × **i32**-LE (signed) + tail | 4,826 | f0 ≈ 2.6×10⁸ tight; f1 med −106 |
| `0x2d` | 152 | 13 B | | |
| `0x04` | 63 | **ASCII** | | log lines, above |
| `0x24` `0x26` `0x15` `0x3c` `0x1a` `0x23` `0x2a` `0x2e` `0x25` `0x2b` `0x32` `0x34` | ≤ 49 each | | | |

`0x0a`/`0x0c`/`0x0d` share one ~729-tick period and are mostly-zero with a single live field — a
periodic statistics dump with several unused slots. `0x14`'s ~4,826-tick period, near-constant
~2.6×10⁸ field and small negative deltas look like a clock/drift record.

**Consequence for NOOP: nothing to decode into data.** `0x61` is 12 % of the bank by volume and carries
no physiological signal — it should be *dropped* from the "worth reverse-engineering" list, not promoted
because it is the highest-rate tag.

**One line is operationally useful: `ble_tx:full`** — the ring reporting its own BLE transmit buffer
overflow. Ten occurrences in this capture (15:34:43, 15:36:25, 15:38:44, 15:57:14, and 05:48:17 — the
final second of the drain), each logged twice. That is direct ring-side evidence of a drop, and a better
signal for diagnosing a truncated bank or a mid-drain gap than inferring loss from missing rows.
