# Self-hosted push protocol

This document specifies the wire contract for NOOP's **Experimental**, default-off export to a
user-owned HTTP(S) endpoint. Protocol versions **1.0** and **1.1** cover the Android-first client.
Version 1.1 adds explicit nullable daily `sleepPerformance` and `sleepConsistency` projections; it does
not add a stream or export the general metric-series table. This is a one-way export protocol: the on-device
database is authoritative, the receiver acknowledges writes and may advertise only which fixed v1
streams it accepts. NOOP never reads health data, commands, URLs, field names, or other configuration
back from the receiver.

NOOP does not ship, operate, or endorse a receiver. A receiver is not part of this repository, and
this contract must not be interpreted as an account, hosted-sync, restore, or two-way-sync API.

## Transport and authentication

The configured endpoint serves authenticated capabilities on `GET` and accepts one `POST` per batch.
The settings screen may issue this `GET` alone when the user selects **Test connection**; that action
does not open the health database or send a batch.

```http
GET /the/user-configured-path HTTP/1.1
Accept: application/json
Authorization: Bearer <user-supplied-token>
NOOP-Push-Accept-Version: 1.1, 1.0
```

A successful capability response has these required members:

```json
{"type":"capabilities","protocolVersion":"1.0","receiverStateId":"5fc7b9a0-8055-4e49-a308-3a290f98d81a","streams":["hrSample","rrInterval","dailyMetric"]}
```

`NOOP-Push-Accept-Version` is a comma-separated, sender-preferred list of exact versions it can emit.
The receiver selects the first version in that order it supports and returns it as `protocolVersion`; no common version fails
with `406` before health data is read. `receiverStateId` is a canonical UUID persisted with receiver
state. It remains stable across upgrades, database backups and migrations, and changes whenever the
receiver no longer has continuity with previously acknowledged data. Restoring a stale receiver backup
therefore requires the operator to rotate this ID. Rotation starts a new idempotency generation: the
receiver retains health records but atomically discards old batch acknowledgements, replacement staging,
and generation fences so deterministic baseline batch IDs are applied again rather than short-circuited.

`streams` is a duplicate-free subset of the twelve names in the selected v1 registry; array order has
no semantic meaning. An empty array is valid. Unknown names, duplicate names, a missing required member,
an unsupported version, malformed JSON, or a response over 16 KiB fail closed before Room is opened or
health data is encoded. Unknown optional object members are ignored within a supported major version. The
receiver cannot add tables or fields: the effective registry is always the intersection of its list
and the client's compiled v1 registry. Android performs no snapshot read and no batch `POST` for an
unadvertised stream.

Capability changes affect future attempts only. A client retains progress for an unadvertised
stream, so advertising it again resumes from the existing cursor. Removing a stream from the list
is not a deletion command and cannot remove records already stored by the receiver.

There is no implicit capability fallback: `404`, `405`, a missing version response, and every invalid
capability document send no health data. Transport failures, `408`, `429`, and `5xx` are retryable and
send no batch in that attempt; other failures are visible protocol/configuration errors. Redirects are
never followed and the bearer token is never forwarded.

Batch delivery then uses:

```http
POST /the/user-configured-path HTTP/1.1
Content-Type: application/x-ndjson; charset=utf-8
Accept: application/json
Authorization: Bearer <user-supplied-token>
Content-Encoding: gzip
```

- HTTPS endpoints may be public. Plain HTTP is accepted only when the URL uses a numeric loopback,
  RFC 1918 private IPv4, IPv4/IPv6 link-local, or IPv6 ULA address. Cleartext hostnames (including
  `.local`) and public cleartext destinations are rejected, eliminating a DNS-rebinding boundary. A
  bearer token sent over allowed local HTTP is still visible locally, so HTTPS remains preferable.
- The token and endpoint are supplied by the user. Neither identifies a NOOP account; no such account
  exists.
- One request contains exactly one device and one stream. A v1 request contains at most **5,000 record
  lines** and at most **4 MiB (4,194,304 bytes)** of decoded UTF-8 NDJSON, including newlines.
- Android sends request entities with `Content-Encoding: gzip` and an explicit `Content-Length`.
  The decoded NDJSON bound is authoritative; the sender also caps the encoded wire entity at
  **4 MiB + 64 KiB** so compression cannot introduce unbounded buffering. Receivers must decode
  before enforcing the NDJSON limit. Other conforming senders may use identity encoding while
  applying the same 4-MiB decoded bound.
- For compatibility with protocol-1.0 identity-only receivers, Android retries once without
  `Content-Encoding` only after a definitive HTTP `415 Unsupported Media Type`. The fallback uses
  the same endpoint, authorization, `batchId`, and byte-identical decoded NDJSON entity. Redirects,
  transient failures, and every other status never trigger this fallback.
- A sender run also caps one mutable-window snapshot at **1,000 records / 2 MiB encoded record
  data**. Larger local windows fail visibly before the first HTTP request instead of growing memory
  without bound or sending an incomplete authoritative replacement.
- Before reading an append page (at most 5,001 queried rows) or mutable snapshot (at most 1,001
  queried rows), Android performs a length preflight over that exact ordered, limited selection in
  the same database transaction. The conservative estimate charges every text value at six times
  its UTF-8 byte length for worst-case JSON escaping plus fixed per-row/object overhead. Oversized
  snapshots fail without truncation or cursor movement before unrestricted text enters app memory.
- Network or receiver failure must not block strap offload, local writes, analytics, or UI. Delivery
  is retried by the independent background worker.
- Android coalesces triggers that arrive during a running worker, processes at most one remembered
  device scope per attempt, and rotates that durable device cursor only after the slice completes.
  Per-call DNS and HTTP deadlines keep the attempt below WorkManager's execution window; automatic
  retries stop after a finite attempt budget and resume on a later successful offload or app launch.

## Identity and storage scope

`sourceId` is a random UUID generated locally and persisted for that app installation. `deviceId` is
the identifier already used by NOOP's local `device` table. Neither is an account or a globally
resolved user identity. The device name and MAC address are not part of this protocol.

A receiver must scope every row and idempotency record by at least:

```text
(sourceId, deviceId, stream, primary key)
```

Two installations that happen to use the same strap identifier must therefore not overwrite one
another. Reinstalling NOOP may create a new `sourceId`; reconciliation between installations is
deliberately outside v1.

Local progress is scoped by `(sourceId, normalized endpoint, selected protocolVersion,
receiverStateId)`. A changed endpoint, negotiated version, or receiver state ID forces a fresh
baseline. Rotating only the bearer token preserves progress. This prevents a newly initialized
receiver at the same URL from silently missing data and lets a protocol upgrade replay older append
records when their representation gains fields.

## NDJSON request

Every line is one complete JSON object followed by LF (`0x0a`). There is no BOM, blank line, JSON
array, or trailing material. The first line is the batch header; exactly `recordCount` record lines
follow it.

### Header

An append batch has this shape (spacing is illustrative, not canonical):

```json
{"type":"batch","protocolVersion":"1.0","batchId":"e835f32f-60e7-4c93-90a0-51eb6830119a","sourceId":"3a3486dd-5030-4e17-a00d-a781399890f9","deviceId":"strap-local-id","stream":"hrSample","delivery":"append","recordCount":2,"startCursor":{"rowId":48110,"keySha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"endCursor":{"rowId":48119,"keySha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}
{"type":"record","key":{"ts":1723939201},"data":{"bpm":61}}
{"type":"record","key":{"ts":1723939202},"data":{"bpm":62}}
```

Header members are:

| Member | Meaning |
|---|---|
| `type` | Always `"batch"`. |
| `protocolVersion` | `"1.0"` for this contract. |
| `batchId` | UUID identifying these exact decoded NDJSON entity bytes. Stable across retries and content codings. |
| `sourceId` | Locally generated installation UUID. |
| `deviceId` | Local device identifier; scopes every record in the batch. |
| `stream` | A name in the versioned stream registry below. |
| `delivery` | `"append"` or `"replace_window"`, as fixed by the registry. |
| `recordCount` | Number of record lines, `0...5000`. |
| `startCursor` | Exclusive append insertion highwater, or `null` for the first append batch and replace-window parts. |
| `endCursor` | Inclusive insertion highwater of the final append record, or `null` for replace-window parts. |
| `window` | Required only for `replace_window` delivery; absent for append delivery. |

All UUIDs are lowercase canonical UUID strings. JSON object member order is not semantically
significant, but the sender must retain the exact decoded NDJSON entity bytes until that batch is
acknowledged.

### Records

Each subsequent object has `type: "record"`, a `key` containing every primary-key column other than
the header's `deviceId`, and a `data` object containing the exported non-key columns. Local-only
bookkeeping such as the vestigial `synced` column is never exported. SQL `NULL` is JSON `null`, integer
and real values are JSON numbers, text is a JSON string, and database booleans are JSON booleans.
Text columns whose names end in `JSON` remain strings; their contents are not promoted into nested
wire objects.

Keys must contain exactly the registry columns. Append records are ordered by their local insertion
position; replace-window records are sorted by natural key. Natural-key integer components compare
numerically and text components use unsigned UTF-8 byte order (SQLite `BINARY` order). A receiver
must reject duplicate keys within a batch or complete replacement window.

## Append delivery and cursors

Each append highwater is local state scoped by `(sourceId, deviceId, stream)` inside the destination
namespace above. It is an opaque receiver value carrying the sender's persistent monotonic insertion
position, not a measurement timestamp or natural primary key. The v1 member is named `rowId` because
NOOP's Android and Apple SQLite stores both map it to SQLite insertion `rowid`; a conforming non-SQLite
sender may supply an equivalent durable insertion sequence. Receivers validate and echo it but must not
interpret it as receiver state.
The sender selects rows for that device whose `rowid` is greater than `startCursor.rowId`, orders by
`rowid ASC`, and sets `endCursor.rowId` to the final row's insertion position. This matters because a
later offload can insert old measurement timestamps; a timestamp or lexicographic natural-key
highwater would permanently strand that backfill.

Each non-null cursor also contains `keySha256`, the lowercase SHA-256 of the UTF-8 bytes formed by
`stream`, LF, `deviceId`, LF, and the compact JSON natural-key object with members in registry order.
Before using a saved cursor, the sender must read
that row and verify the natural-key fingerprint. A missing row or mismatch means a restore, prune,
`VACUUM`/rowid rewrite, or database replacement invalidated the insertion positions. The sender must
reset that stream's cursor to null and replay it; receiver primary-key upserts make the replay safe.
Changing `sourceId`, normalized endpoint, selected version, or `receiverStateId` selects a fresh
progress namespace and sends a full baseline, avoiding acknowledgements being carried between
destinations. Implementations may store additional local database-generation evidence, but it is not
transmitted.

The sender also remembers, per endpoint namespace, every device scope it has considered. Live
database discovery is unioned with that encrypted set so deleting the final mutable row still emits
an empty authoritative replacement instead of leaving stale receiver data behind.

An append batch must contain at least one record. Its keys must satisfy:

```text
startCursor.rowId < first rowid < ... <= final rowid == endCursor.rowId
```

For an initial batch, `startCursor` is `null` and all insertion positions are eligible. Batches stop before either
the 5,000-record or 4-MiB decoded bound is exceeded. A receiver applies records as idempotent upserts using the
scoped primary key. Append streams do not communicate deletions.

The sender advances a stream's local highwater to `endCursor` only after a valid acceptance response
for the whole batch. A timeout, non-2xx response, invalid body, partial acceptance, or mismatched
acknowledgement leaves the highwater unchanged and retries the identical `batchId` and decoded
NDJSON entity bytes. Other
streams have independent highwaters and may continue.

## Authoritative rolling-window delivery

Mutable and recomputed tables use authoritative `replace_window` operations rather than append cursors.
After an offload, the sender evaluates the current local calendar day plus the preceding 13 local days
(approximately 14 times 24 hours across daylight-saving changes). On a fresh destination it sends that
complete 14-day baseline. Afterwards Android stores a canonical SHA-256 separately for every local day,
device, stream, source, and endpoint namespace. These hashes are local progress metadata and are never
transmitted.

If every daily hash is unchanged, no replacement request is necessary. If days changed, Android sends the
smallest contiguous window spanning those days; unchanged days between the first and last changed day may
be included. A formerly populated day whose canonical snapshot is now empty is changed and must be sent as
an empty authoritative window. Hash progress advances only after every part receives an exact durable
acknowledgement. Therefore a timeout or failed acknowledgement repeats the same deletion or replacement
instead of losing it. Receivers must accept any non-empty half-open subwindow inside the mutable horizon;
they must not require every replacement to be exactly 14 days wide.

Day-keyed windows use `YYYY-MM-DD`; timestamp-keyed windows use the corresponding local-midnight bounds
converted to Unix seconds. Bounds are always half-open:
`startInclusive <= selector < endExclusive`.

The window header member is:

```json
"window":{"replacementId":"bf8b735e-f157-4a35-beb2-9b086d10d5bd","selector":"day","startInclusive":"2026-08-05","endExclusive":"2026-08-19","part":1,"parts":1}
```

For `startTs` selectors the bounds are integer Unix seconds instead of strings. A replacement that fits
in one request uses `part: 1, parts: 1`. If it exceeds either batch bound, the sender divides the
sorted records into `parts` bounded requests. Every part has the same `replacementId`, scope, window and
positive `parts` value; `part` runs from 1 through `parts`; each part has its own stable `batchId`.
An empty window is represented by one zero-record part and is still authoritative: it deletes all
receiver rows in that scope and window. `startCursor` and `endCursor` are `null` for all parts.

Daily checksums are an upload-elision mechanism, not receiver state or a synchronization command. A
receiver remains responsible for durable storage once it acknowledges a batch. A changed destination
namespace forces the complete baseline; rotating only the bearer token preserves accepted daily hashes.

The receiver durably stages accepted parts. Only when every part is present does it atomically:

1. upsert all replacement records by the scoped primary key; and
2. delete receiver rows in the declared window whose keys are absent from the complete replacement.

An acknowledgement for the part that completes the set must not be returned until that atomic apply
succeeds. Retrying any part is harmless. Conflicting reuse of a `replacementId`, part number, or
`batchId` must be rejected. Rows outside the declared window are untouched. This absence-means-delete
rule makes edits and deletions within the rolling window converge to NOOP's local state; v1 carries no
tombstone for a row that has already aged out of that window.

A sender must have at most one incomplete replacement generation per `(sourceId, deviceId, stream)`.
Observing the first part of a different generation supersedes every older incomplete generation in that
scope, even when its exact window bounds differ. A receiver rejects late parts of a superseded
generation with `409`. Senders serialize replacement generations for a scope; retries remain safe and
parts may arrive out of numerical order.

## Version 1 stream registry

The v1 registry is deliberately finite. A table present in NOOP's database is **not** implicitly part
of the protocol.

### Append streams

| `stream` | Natural key | `data` members |
|---|---|---|
| `hrSample` | `ts` | `bpm` |
| `rrInterval` | `ts`, `rrMs`, `seq` | `ord` (nullable), `srcChannel` (nullable), `tsSuspect` (nullable) |
| `event` | `ts`, `kind` | `payloadJSON` |
| `battery` | `ts` | `soc` (nullable), `mv` (nullable), `charging` (nullable) |
| `spo2Sample` | `ts` | `red`, `ir` |
| `skinTempSample` | `ts` | `raw`, `aux1Raw` (nullable), `aux2Raw` (nullable) |
| `respSample` | `ts` | `raw` |
| `gravitySample` | `ts` | `x`, `y`, `z`, `dynAccel` (nullable) |

`ts`, `rrMs`, `seq`, `bpm`, `red`, `ir`, and `raw` are integers. `soc`, `x`, `y`, `z`, and
`dynAccel` are finite numbers. The nullable RR metadata is integer-valued. `charging` is boolean or
null. The database's `deviceId` is supplied by the header and `synced` is intentionally omitted.

### Mutable replace-window streams

| `stream` | Key | Window selector | `data` members |
|---|---|---|---|
| `dailyMetric` | `day` | `day` | `totalSleepMin`, `efficiency`, `deepMin`, `remMin`, `lightMin`, `disturbances`, `restingHr`, `avgHrv`, `recovery`, `strain`, `exerciseCount`, `spo2Pct`, `skinTempDevC`, `respRateBpm`, `steps`, `activeKcalEst`, `spo2Red`, `spo2Ir` (all nullable); v1.1 adds nullable `sleepPerformance` and `sleepConsistency` |
| `sleepSession` | `startTs` | `startTs` | `endTs`, `efficiency`, `restingHr`, `avgHrv`, `stagesJSON`, `userEdited`, `startTsAdjusted`, `motionJSON`, `sleepStateJSON`, `stagingSparse` |
| `workout` | `startTs`, `sport` | `startTs` | `endTs`, `source`, `durationS`, `energyKcal`, `avgHr`, `maxHr`, `strain`, `distanceM`, `zonesJSON`, `notes`, `routePolyline`, `steps` |
| `journal` | `day`, `question` | `day` | `answeredYes`, `notes`, `numericValue` |

Unless inherent above, mutable data members are nullable exactly as in the current Room schema.
`sleepSession.endTs`, `workout.endTs`, `workout.source`, and `journal.answeredYes` are required;
`sleepSession.userEdited` is a required boolean. `day` is `YYYY-MM-DD`; timestamp and count fields
are integers; metric and measurement fields are finite numbers. See [DATA_MODEL.md](DATA_MODEL.md)
and `android/app/src/main/java/com/noop/data/Entities.kt` for the local meanings and units. The wire
registry, not automatic reflection over either database, determines what is sent.

The `dailyMetric` field list in protocol 1.0 is unchanged. Protocol 1.1 adds two nullable 0–100 values:

- `data.sleepPerformance` is sourced from the matching `metricSeries` row whose key is
  `sleep_performance` and whose source/day match the enclosing `dailyMetric` row. It is not mapped from
  `recovery`. When there is no matching score point, the field is JSON `null`.
- `data.sleepConsistency` uses the matching `metricSeries` row whose key is `sleep_consistency` when the
  latest exported daily day has a point, matching SleepModel's imported-series preference. Otherwise
  Android reproduces the Sleep screen's existing bedtime-onset consistency for the same source: for each
  local wake day, it uses the trailing up-to-14 sleep sessions ordered by detected `startTs`, with an
  edited onset (`startTsAdjusted`) taking precedence. After wrapping after-midnight bedtimes past noon,
  population SD of bedtime minutes maps to `100 * (1 - SD / 120)`, clamped to 0–100; fewer than three
  sessions yields JSON `null`. A day with multiple sessions uses its last session's point. It is not
  mapped from `recovery` or `sleepPerformance`.

Both values are source-local: Sleep Performance may be an imported value or NOOP's locally computed
approximate Rest composite; sleep consistency may be imported or the NOOP bedtime-regularity calculation
above. The Rest composite is not WHOOP's proprietary score. The exporter does not merge values across
device/source scopes; receivers can distinguish scopes from the batch `deviceId` and should label the
scores honestly. Neither field is a recovery score.

A receiver that selects protocol 1.0 receives the original field set. It does not receive either new
field, preserving compatibility with existing receivers.

Newer tables such as `ppgHrSample`, `stepSample`, `sleepStateSample`, raw waveform / IMU tables,
and any future schema additions are not silently exported. The general `metricSeries` table is not
a stream: v1.1 projects only the matching `sleep_performance` and `sleep_consistency` values for each
exported `dailyMetric` source/day (the latter falls back to the documented session calculation when the
latest exported day has no imported consistency point). Other metric-series keys remain local. Adding a
stream or optional `data` member requires a documented registry update and protocol minor version.

## Acceptance, errors, and retry idempotency

After atomically accepting an append batch or durably accepting a replace-window part, the receiver returns
2xx with `Content-Type: application/json` and exactly one acknowledgement object:

```json
{"protocolVersion":"1.0","batchId":"e835f32f-60e7-4c93-90a0-51eb6830119a","stream":"hrSample","deviceId":"strap-local-id","endCursor":{"rowId":48119,"keySha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"acceptedRows":2,"status":"accepted"}
```

Acceptance is valid only if all of these exactly match the request:

- `protocolVersion`
- `batchId`
- `stream`
- `deviceId`
- `endCursor` (including `null` for replace-window parts)
- `acceptedRows == recordCount`
- `status == "accepted"`

Any missing or mismatched member is a failed delivery even when the HTTP status is 2xx. There is no
partial success. The acknowledgement contains metadata only; it must not contain source records,
remote changes, commands, cursors chosen by the server, or configuration for NOOP to apply.
Capability metadata is confined to the separate authenticated `GET` defined above.

A receiver must remember the hash and acceptance result of each batch under
`(sourceId, deviceId, batchId)`. Repeating the same `batchId` with byte-identical **decoded NDJSON
entity bytes** returns the same acknowledgement without duplicating effects. Content coding is not
part of batch identity: gzip and identity representations of the same decoded entity are the same
batch. Reusing a `batchId` with different decoded entity bytes is a conflict and must not modify
data. Recommended failures are `400` for malformed NDJSON, `401`/`403` for auth,
`409` for conflicting identifiers or replace-window parts, `413` for a decoded body over 4 MiB (or
an encoded body over the receiver's documented wire limit), `422` for an
unsupported protocol/stream or invalid record, and `5xx` for a transient receiver failure. NOOP
automatically retries transport errors, `408`, `429`, and `5xx`. Other `4xx` responses and malformed
or mismatched acknowledgements retain progress and surface a visible configuration/protocol error;
they are retried only after a later trigger or configuration change. Responses are never consumed as
health data.

A receiver should return a bounded machine-readable body for non-2xx responses:

```json
{"type":"error","protocolVersion":"1.0","code":"registry_mismatch"}
```

`code` contains 1–64 lowercase ASCII letters, digits, or underscores and starts with a letter. Android
may display and persist only this validated code alongside the HTTP status; it never retains arbitrary
response text. Unknown error members are ignored.

The Android client reports a safe, structured cause for self-hosting diagnostics: DNS resolution,
TLS certificate or handshake, connection timeout/refused/unreachable/reset, numeric HTTP status,
invalid capabilities or acknowledgement, local encoding limits, or local database state. These
categories survive bounded continuation work so the final status keeps the original cause. Raw
exception messages and response bodies are deliberately neither displayed nor persisted because
network stacks and receiver errors can contain endpoint details, credentials, or health data.

## Versioning and forward compatibility

`protocolVersion` is `MAJOR.MINOR`. Capability discovery negotiates one exact version before Room is
opened; senders never optimistically emit a version the receiver did not select.

- A major version changes framing, required members, keys, or existing semantics. A receiver must
  reject an unsupported major version.
- A minor version may add an optional header/data member or a registry stream. Receivers supporting
  the same major must ignore unknown object members. They may reject an unknown stream without
  rejecting batches for supported streams. Specifically, v1.1 adds only the nullable
  `dailyMetric.data.sleepPerformance` and `dailyMetric.data.sleepConsistency` fields described above.
- A sender must not emit a new stream or field while claiming an older minor version. Removing or
  changing the meaning/type of a field, or changing a stream key or delivery mode, requires a new
  major version.
- Receivers must reject malformed known members rather than guessing. They should preserve unknown
  `data` members if their storage model permits, but must not assign semantics to them.

Capability discovery only selects an offered version and narrows the sender's compiled registry for it.
It is not general negotiation: the receiver cannot add schemas, change delivery modes, select an
endpoint, request diagnostics, set cadence, or otherwise control NOOP.

## Apple compatibility

The contract is platform-neutral. NOOP on iOS/macOS uses GRDB/SQLite with the same natural keys and
logical v1 streams, but every implementation uses explicit registry projections rather than reflection
or `SELECT *`. A sender may continue to negotiate protocol 1.0. A sender that advertises 1.1 must
project `sleepPerformance` from the matching `sleep_performance` metric-series point and `sleepConsistency`
from either the matching `sleep_consistency` metric-series point or the documented same-source sleep-session
calculation. Missing values emit `null`. Other metric-series keys and platform-only columns stay absent.
Scheduling and credential storage are platform concerns and do not change NDJSON, acknowledgement,
idempotency, or replacement semantics.
