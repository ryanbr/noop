# Firmware updates and device authorization

This chapter follows the [shared scope](PROTOCOL.md#scope-and-compatibility). Image integrity, boot acceptance and session authorization are distinct mechanisms. These contracts describe boundaries, not a validated installation procedure.

## Image-transfer command boundaries

| Command | Request body | Response and limits |
|---:|---|---|
| 83 | `revision:u8=1` | Starts incremental image verification. Immediate completion/failure has body `[1]`; unfinished verification continues asynchronously. The final response retains the original request correlation, body `[1]`, and outer result 1 for integrity success or 0 for failure. |
| 142 | `revision:u8=1` | `[1, detail]`; success detail 0, preparation failure detail 10. |
| 143 | `revision:u8=1, offset:u32le, length:u8, data[length]` | Length at most 224. `[1, detail]`; success detail 0, otherwise a lower-layer error or preparation detail 10. Partition, alignment and storage constraints also apply. |
| 144 | `revision:u8=1` | Image integrity acceptance returns `[1,1]` with result 1 and queues lifecycle work. Preparation, integrity or revision failure returns `[1,0]` with result 0. Later boot acceptance remains a separate boundary. |

An incomplete successful command 83 verification step schedules another step without
sending a final response. The normal continuation needs no additional client
command. Failure to close update storage does not replace the saved integrity
result. Timeout, disconnection and overlapping requests remain unresolved; wait
for the correlated result and do not treat silence as success.

Command 144 success confirms the application image CRC gate and requests storage
coordination plus a delayed board reset. Those requests do not establish completed
reset, installation, authenticity or boot acceptance. A reconnect does not by
itself identify the accepted image. Signature, compression and rollback policies
remain unspecified; CRC equality and version fields do not establish them.
These contracts do not supply an installation sequence.

## Image container and integrity fields

The documented container format has a **512-byte header** followed by its
payload. Offsets below are offsets within the file, not Bluetooth-frame or memory
addresses. Multibyte numeric fields are little-endian.

| File offset | Width | Meaning |
|---:|---:|---|
| 0 | 4 | CRC32 of all payload bytes starting at offset 512; this is not a magic value |
| 4 | 4 | Payload length, excluding the 512-byte header |
| 8 | 4 | Unresolved header word |
| 12 | 4 | Image-type selector |
| 16 | 4 | Unresolved header word |
| 504 | 4 | Header CRC32 over bytes 8–503 inclusive |

Both checks use the conventional CRC32 result format used by `zlib.crc32`.
Unlisted header bytes include version/build information and unresolved fields;
this table does not define them as zero or freely editable. The payload CRC and
length are outside the header-CRC range.

The compressed `.zbin` container and its decompressed image each carry their own
header and payload checks. In the compared artifacts, type 5 carries a gzip
payload and type 1 carries the decompressed payload. This is a bounded type
mapping, not a complete type enumeration. Do not substitute one representation's
length or checksums for the other's.

The application checks partition bounds and payload integrity. Chunk writes of
the documented size are read back and compared; that comparison is separate from
whole-image verification and eventual boot acceptance. These fields support
container inspection; they do not establish which representation a complete
installation procedure must transfer or that a modified container will boot.

## Certificate command boundaries

| Command | Request body | Response and limits |
|---:|---|---|
| 155 | `revision:u8=1` | `[1]`; starts a fresh certificate transfer. |
| 156 | `revision:u8=1, offset:u16le, length:u8, data[length]` | `[1]`; chunks are at most 225 bytes and the transfer capacity is 2458 bytes. Use nonwrapping, in-range slices. An immediately repeated offset is acknowledged without comparing replacement content. |
| 157 | `revision:u8=1, declared_total:u16le` | `[1, detail]`: 1 validation success, 2 validation failure, 3 accumulated/declared length mismatch, 0 unsupported revision. Outer result is 1 only for validation success. |
| 158 | `revision:u8=1` | `[1]`; revalidates and processes the certificate. Result 1 reports processing success. Certificate and metadata storage are separate operations, so failure does not promise that persistent state is unchanged. |
| 159 | `revision:u8=1` | `[1]`; acknowledges a queued BLE authorization lock. Certificate clearing depends on the prior authorization state; eventual storage success is not reported. |

Accumulated transfer length does not prove contiguous byte coverage. The certificate
has three nonempty, period-separated segments. Payload and signature use unpadded
URL-safe Base64. Verification covers the original encoded first and second
segments and their separating period; the uploaded payload does not supply the
trust key. Complete header-validation and issuer-provisioning policies remain
unspecified.

Certificate verification uses SHA-256 with the P-256 signature
operation. The decoded signature is exactly 64 bytes: a 32-byte `r` followed by a
32-byte `s`, rather than an ASN.1 DER signature. Payload and signature decoding
each have a 512-byte output bound; the signature must also satisfy its exact
64-byte length. This algorithm contract does not establish complete cryptographic
implementation validation or firmware-image authentication and rollback policy.

Required claims are strings `aud` and `sub`, bounded to 30 and 11 bytes and compared
to stored device identity fields, plus decimal unsigned 32-bit numeric `iat` and
`exp`, with `exp >= iat`. New transfers require `iat` to be strictly greater than the stored accepted value. If reading
that metadata fails, the comparison uses a zero-filled fallback instead; a read
failure does not itself force rejection. Identity-storage reads also initialize
buffers and continue to the identity comparisons after read errors; those errors
do not independently force certificate rejection. The separate remaining authorization duration is derived
from `exp - iat`; it is not the freshness value or an established direct wall-clock
comparison against `exp`. One accounting path charges elapsed monotonic seconds
during flash work, capped at the remaining amount. A successful write commits the
reduced amount and advances that accounting timestamp; failure behavior and reboot
restoration remain separate limits. A saved certificate is parsed during cold initialization
without requiring its
own saved `iat` to be newer than itself. That differs from accepting a new
transfer. JSON edge cases and complete duration restoration after reboot remain
unresolved.

Command 158 revalidates, stores the certificate, updates accepted `iat`, requests
the remaining duration and queues an unlocked-state update. Storage operations
are separate and failure may follow a partial persistent change. Equal `exp` and
`iat` provide zero duration, so processing success does not guarantee a lasting
unlocked state.

Command 159 queues an authorization lock. Applied to a previously unlocked state,
it also attempts to clear the stored certificate and requests zero duration;
already locked, it skips that clearing step. Its response does not report the
later storage result. This behavior does not establish irreversible fuse
programming. A later properly signed, identity-matching certificate that processes
successfully can request an unlocked state again; the persistent freshness
requirement still applies when its metadata is readable. This is not a tested
recovery procedure or a source of issuer authorization.

A transfer acknowledgement, validation, storage, authorization update and lock
completion are distinct outcomes. No installation or lock/recovery operation has
been validated on a device for these contracts.

For sensor production, live/save policy, typed configuration and flag behavior use [configuration](PROTOCOL_CONFIGURATION.md); for ECG wrist/start/stop and independent raw/filtered routing use [ECG](PROTOCOL_ECG.md). Those pages separate requested state from applied state and packet delivery. Exact timing, energy cost, all reset paths and all hardware variants remain open unless a specific contract says otherwise.
