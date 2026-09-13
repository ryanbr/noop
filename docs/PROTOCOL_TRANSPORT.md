# WHOOP transport and core behavior

Applicability: [central scope and compatibility](PROTOCOL.md#scope-and-compatibility).

This extends [the protocol entry page](PROTOCOL.md) with WHOOP 5/MG contracts. Earlier WHOOP 4 and 5 observations are labeled separately. A defined command does not establish identical behavior on every hardware variant or connection state. See the [complete command reference](PROTOCOL_COMMANDS.md) for individual operations.

## Format 1 framing

All multibyte integers below are little-endian. Offsets are from the beginning of the complete frame.

| Offset | Width | Meaning |
|---:|---:|---|
| 0 | 1 | Start byte `aa` |
| 1 | 1 | Format `01` |
| 2 | 2 | Declared length: complete frame length minus 8 |
| 4 | 2 | Header fields; requests commonly use `00 01`, responses `01 00` |
| 6 | 2 | CRC16 over bytes 0–5 |
| 8 | 1 | Packet type: 35 for a command |
| 9 | 1 | Request sequence |
| 10 | 1 | Command number |
| 11 | variable | Request body, followed by zero padding to a four-byte body boundary |
| end − 4 | 4 | CRC32 over the padded body beginning at offset 8 |

Construct the body as packet type, sequence, command and command-specific bytes; append zero bytes until its size is divisible by four. The declared length is that padded size plus four, and the complete frame size is the padded size plus twelve. Padding is not a semantic argument: an explicit request byte `00` and a missing argument must not be treated as interchangeable merely because padding can make their frames look alike.

The baseline format-1 acceptance constraints require a complete frame longer than 15 bytes, exact agreement between declared and supplied length, and `(declared length − 4)` divisible by four. Do not require one constant value for bytes 4–5. Header CRC is reflected Modbus CRC16, polynomial `0xa001`, initial value `0xffff`. NOOP format-1 bodies use the standard reflected CRC32 convention, polynomial `0xedb88320`, initial and final XOR `0xffffffff`, including padding.

NOOP's existing generic verifier is more permissive about minimum length, trailing bytes and format selection. Reassemble complete frames first, distinguish outer formats, and validate the exact selected frame rather than letting a permissive checksum check imply support for another format. Parser errors for unsupported format, size, header CRC and body CRC are local failures, **not** command-result values on the wire.

WHOOP 4 uses its separate envelope: `aa`, two-byte length, CRC8 over those two length bytes, then the inner body at offset 4 and its CRC32. Complete size is declared length plus four. Keep the family-specific GATT and fragment handling in [the entry page](PROTOCOL.md#2-frame-envelope).

## Responses and correlation

A format-1 command response has type 36 at offset 8, a generated response sequence at 9, command at 10, **originating request sequence at 11**, result at 12, and command body at 13. The request-origin byte is the correlation field; the response frame's sequence is not the request echo. Match command and origin, with connection/session context and a bounded outstanding-request policy. Sequence wrap and duplicate responses remain possible. WHOOP 4's corresponding command/origin/result/body offsets are 6/7/8/9.

| Result | Meaning | Application consequence |
|---:|---|---|
| 0 | Failure | Preserve the refusal; do not infer its cause without command-specific information. |
| 1 | Success | Request accepted at that command's response boundary; not proof of completed asynchronous work, sensor initialization, live packets or durable storage. |
| 2 | Pending | Keep the request open for its later result within a bounded client timeout. |
| 3 | Unsupported | This command is not supported in the applicable command context. |
| Other | Unknown | Preserve the numeric value; do not coerce it to success. |

Check lengths before accessing the response prefix or body; the CRC trailer and outer padding are not response fields. The first command-body byte is command-specific: for several revision-1 controls it is a revision marker, whereas command 26 begins a four-byte whole-percent value in this version. It is not a universal success flag or state echo. The 88 unsupported command IDs in the reference return result 3 with an empty semantic body command context.

NOOP increments an eight-bit request sequence before sending and wraps it. Resetting it on disconnect is a client policy, not a guarantee that a late notification belongs to the new session. A command can produce multiple responses, and a retransmitted request is not automatically safe to execute twice.

## Format 2 boundary

A second outer format exists, but its runtime availability and session negotiation are unresolved. Normal NOOP traffic remains format 1; do not switch formats automatically. For incoming format-2 commands, inner type 7 is at offset 25, the normalized request sequence comes from byte 17, command from byte 29 and payload starts at 31. The wider outgoing fields do not establish a wider incoming command namespace.

| Reply offset | Width | Meaning |
|---:|---:|---|
| 8 | 1 | Outer type `0x40` |
| 9 | 1 | Revision 1 |
| 11 | 4 | Seconds |
| 15 | 2 | Fractional ticks |
| 17 | 4 | Generated response sequence |
| 25 | 1 | Inner response type 8 |
| 26 | 1 | Zero |
| 27 | 1 | Revision 1 |
| 28 | 2 | Command |
| 30 | 4 | Originating request sequence |
| 34 | 1 | Marker 3 |
| 35 | 4 | Result |
| 39 | 1 | Marker 1 |
| 40 | variable | Command response body |

Unassigned gaps are zero in this reply layout. The reply length calculation narrows `(body length + 32)` to eight bits. This is not an unrestricted large-payload interface; behavior for oversized bodies remains unresolved. Format-1 offsets must never be applied to this format.

## Clock and identity contracts

SET_CLOCK uses revision 1, Unix seconds `u32`, and fractional ticks `u16` in units of 1/32768 second. Use a canonical fractional value 0–32767. The stored clock precision is hundredths: the fraction is converted using `floor(ticks × 100 / 32768)`. The reply is a one-byte revision-1 body with success or failure. Behavior of noncanonical fractional values is not specified here.

GET_CLOCK takes revision 1 and returns seven bytes: revision, seconds `u32`, fractional ticks `u16`. Returned ticks are `floor(hundredths × 32768 / 100)`, so a set/get round trip can lose precision. An unsupported revision returns failure with revision 1 and zero time. A clock-read failure can also produce zero time with a success result; there is no independent validity flag. Applications must not treat success alone as evidence of a valid wall clock.

One initialization path consumes a pending saved time. It requires a valid stored
request, saved seconds strictly above Unix timestamp `1293840001`, and a saved time newer
than the current valid seconds value. These eligibility comparisons use seconds,
not the fractional field. The fractional field is supplied to the time setter
when restoration is attempted.

The pending saved time is cleared after the selected attempt, including when
the time setter reports failure; rejected stale or invalid saved times are also
cleared. Clearing the persistent request can itself fail. Applications should
read the current device time after reconnecting before relying on it for
scheduled operations. A pending saved time is not a guarantee that initialization
restored the clock or will retry until it succeeds.

The deprecated low-number clock pair has different legacy request shapes. Do not substitute its seconds-plus-four-zero-bytes body or its WHOOP 4 response offsets for the new pair.

LINK_VALID returns success with a fixed 13-byte NUL-terminated acknowledgement; it is not an identity token. GET_HELLO accepts revisions 1 and 3, initially returning pending with respectively 107 or 111 body bytes, the revision echoed and other bytes zero. Invalid revision returns failure with a 107-byte body beginning with revision 1. The final layout is specified below; earlier Hello decoder offsets are not universal. Hello and battery-pack records may contain identifiers; a protocol decoder should extract only the fields needed by its feature.

## History sequencing and storage ownership

The existing [backfill state machine](PROTOCOL.md#7-historical-data-offload-backfill) remains the operational contract. WHOOP 5/MG clients request the range before history and wait for success or a two-second client fallback; WHOOP 4 clients can request history directly. The timeout is an application choice, not a device timing promise. The current range request first returns pending with an empty body; its final 65-byte body is specified below, with opaque cursor and timestamp roles retained. Lack of a response does not mean that history is empty.

History transmission uses an explicit `00` request byte. Metadata start/end/complete values are 1/2/3. Packet types 49 and 56 both participate in known history routing; the current START/END/COMPLETE path uses type 49; other-version routing remains separately scoped. A command acknowledgement is not delivery of a chunk.

For each HISTORY_END, preserve its eight-byte acknowledgement block verbatim. The first four bytes are the trim cursor in known layouts; the second four reflect write-wrap state in this version. Send the history-result body `01` followed by that block **only after committing** the chunk's decoded records, rejected-record diagnostics and cursor locally. Do not reconstruct that block from decoded timestamps. Maintain arrival order where duplicate handling and cursor association depend on it.

A successful chunk acknowledgement can allow the strap to reclaim history. Local storage failure therefore withholds it. An end marker closes a chunk; transfer-complete closes the overall session. Timeouts do not authorize acknowledging an uncommitted open chunk. NOOP's watchdog, retries and backlog handling are client policies; cross-disconnect replay guarantees remain unknown; local retry and cursor roles are specified below. ABORT_HISTORICAL_TRANSMITS is a stop request, not a trim, and local cleanup must not depend on a reply arriving. FORCE_TRIM and SET_READ_POINTER are separate invasive cursor mutations and are not substitutes for normal chunk acknowledgement.

## Scheduled-control timing

The [high-frequency sync scheduler](PROTOCOL_COMMANDS.md#high-frequency-sync-scheduler)
uses wall-clock seconds for duration and a separate callback counter for its period.
It schedules events; it is not a demonstrated Bluetooth throughput control. Command
96/97 and events 96/97/98 occupy separate namespaces.

[Alarms](PROTOCOL_ALARMS.md) likewise compare whole wall-clock seconds for due status.
Clock validity, stored configuration, command acknowledgement and eventual physical
execution are distinct. Preserve the pending/final RUN response sequence and do not
assume that manual RUN leaves the saved schedule intact.


## Complete response bodies

Offsets in the following tables begin after command, origin sequence and result. Lengths exclude framing, CRC and padding. All integers are little-endian. Pending is not completion.

## Battery level — command 26

The final response body is **four bytes**, an unsigned whole-percent value.
The fractional part is discarded. A successful response carries result 1;
a nonzero error on the ordinary completion callback carries result 0 and four zero bytes. Actual measurement timeout/error handling follows a different continuation and does not guarantee that reply. A zero value
can also be a conversion fallback, so it does not by itself prove a depleted
battery. Do not interpret this version's logical body as a one-byte response.

## Hello — command 145

Send revision 1 or 3. Initial PENDING has a zero-filled body except the revision:
107 bytes for revision 1, 111 for revision 3. Unsupported request revisions return
FAILURE with revision 1 and 106 zero bytes. Final supported responses have the
following layout. Identity blocks can contain personal device information;
applications generally need selected identity/version fields, not a raw body dump.

| Offset | Width | Field |
|---:|---:|---|
| 0 | 1 | Revision 1 or 3 |
| 1 | 4 | Battery, tenths of a percent |
| 5 | 1 | Opaque state byte |
| 6 | 4 | Unix seconds |
| 10 | 4 | Fractional ticks, units 1/32768 second |
| 14 | 11 | Identity text block A |
| 25 | 24 | Opaque identity block |
| 49 | 30 | Identity text block B |
| 79 | 4 | Version-specific word, value 13 |
| 83 | 4 | Opaque cached word |
| 87 | 4 | Opaque state word |
| 91 | 3 | Version components 50, 42, 1 |
| 94 | 4 | Version suffix 0 |
| 98 | 3 | Opaque three-byte field |
| 101 | 1 | Profile/configuration value, 0–2 |
| 102 | 1 | Opaque cached state byte |
| 103 | 4 | Preparation status bits |
| 107 | 4 | Revision 3 only: opaque cached state word |

The final reply reports SUCCESS even if preparation status bits are set. Retain
those bits and do not assume every field is valid merely because the result is 1.
Preparation bit `0x10` marks the failed identity-block-A helper condition, and
`0x20` marks the failed identity-block-B helper condition. Revision 3 can additionally
set `0x40` from its extra preparation check; that check's full meaning remains
unresolved. Other preparation bits must also be preserved.
Revision 3 adds the trailing word and an additional preparation-status check.
The fractional field occupies four bytes despite the underlying clock fraction
having only 16 significant bits. Text blocks must be bounded by their field width.
The legacy command 35 does not build a reply on its command handler path; do not
use it as an interchangeable command-145 request.

## Battery pack — command 151

Send revision 1. The immediate response reports cached information, with SUCCESS
even when no pack is present. Its body is 28 bytes. Other request revisions return
FAILURE with revision 1 and 27 zero bytes.

| Offset | Width | Field |
|---:|---:|---|
| 0 | 1 | Revision 1 |
| 1 | 1 | Presence flag |
| 2 | 6 | Address/identifier block |
| 8 | 16 | Serial/text block; handle as bounded bytes |
| 24 | 2 | Charge value; scale requires separate confirmation |
| 26 | 1 | Opaque cached field |
| 27 | 1 | Opaque cached field |

A successful response is not a live query or a freshness guarantee.

## Data range — command 34

An empty PENDING body precedes completion. Final SUCCESS contains revision 1
followed by 16 unsigned 32-bit fields, totalling **65 bytes**. Failure, including
the response timeout path, returns revision 1 followed by 64 zero bytes.

| Offset | Width | Field |
|---:|---:|---|
| 0 | 1 | Revision 1 |
| 1 | 4 | Ring boundary A; full oldest/erase role unresolved |
| 5 | 4 | Read-page cursor B |
| 9 | 4 | Write-page cursor C |
| 13 | 4 | Acknowledged/trim boundary D |
| 17 | 4 | Write-wrap state/count |
| 21 | 4 | Ring capacity in page slots |
| 25 | 4 | Record-count estimate; may fall back to 15 records per page |
| 29 | 4 | Derived quantity: 15 × (adjusted D + capacity − adjusted C) |
| 33, 37 | 4 each | Clock pair from boundary-A page |
| 41, 45 | 4 each | Clock pair from trim-side page, preceding page if equal to write |
| 49, 53 | 4 each | Clock pair from read-side page, preceding page if equal to write |
| 57, 61 | 4 each | Clock pair from last-written page |

For the derived quantity, C and D are each increased by capacity if below A.
The record-count estimate is zero when adjusted trim and write positions coincide.
On the successful record-sequence extraction path, it is the greater of the
unsigned 32-bit expression `currentSequence − extractedSequence + 1` and the page
distance. Other paths use fallback estimates, so this is not an exact record count
or an all-path formula.
For accepted format-1 records, the first three clock pairs use the inner record
clock for packet 47 and the header clock for packets 48 and 54. Unsupported
header/type combinations yield a zero pair. The last pair prefers the page's
stored final clock and uses a compatible record/header fallback only when both
stored components are zero. These fallbacks do not establish valid dates.

The second member of each pair is a 16-bit value widened to 32 bits. Boundary A and the complete units of every retained clock form remain unresolved. Treat the estimates as counts/distances, not durations. Failed page reads produce seconds-like 0xffffffff and widened companion 65535; unsupported headers can produce zero pairs. The history contract below specifies local retries and current type-49 routing without a universal cross-version guarantee.


### Historical synchronization: boundaries, retries and range interpretation

a history command response is an acceptance
result, separate from the history stream. START opens the stream, END marks a
consumer acknowledgement boundary, and COMPLETE closes the current attempt.
Completion alone is insufficient to assert that every stored record has reached
persistent application storage. Use saved progress and the available range to
decide whether another bounded attempt is useful.

The current START, END and COMPLETE messages use metadata packet type 49.
This establishes the current implementation's particular history path, not a
universal firmware boundary between types 49 and 56. Keep support for other metadata
routes where independently required by supported-device evidence.

An END token contains eight bytes. Keep and echo the entire original token after
persisting both the completed chunk and its local progress marker. The first word
is a read-page position modulo ring capacity; the second reflects write-wrap state.
The ordinary acknowledgement path uses the first word for its boundary operation,
but this does not make the trailing bytes optional. Do not construct a replacement
token from an independently saved cursor.

The ordinary boundary operation maps the supplied first word into the ring
geometry, handles boundary crossing and reduces the selected position modulo
capacity before updating the acknowledged/trim boundary. When write-wrap state
is zero, an ahead-of-write target is clamped to the write position. This does
not change the requirement to echo the original END token unchanged.

Special tokens are separate from ordinary chunk acknowledgements. With a first
word of `0xffffffff`, the storage handler skips the normal boundary operation but
still signals completion. A pair of `0xfefefefe` words enables a special mode and
arms its timer; the current write-page position replaces the normal boundary
input. A pair of `0xfdfdfdfd` words clears that mode and invokes a separate cursor-restoration path using a
stored history boundary before the subsequent boundary operation. That boundary
is distinct from the acknowledged/trim boundary; its complete retention role is
unresolved. While the special
mode is set, an ordinary pair also uses the current write position. These are
wire-reachable control cases, not replacement tokens to synthesize for a committed
chunk, nor a validated recovery or erase procedure.

The selected history sender forwards positive, already-framed records only up to
2140 bytes. Zero is handled separately. This is a record-forwarding bound, not the
BLE MTU or a maximum for every protocol packet.

The device has bounded local retries. Its END-wait timeout path resends END on
its first four expirations and changes state on the fifth. The repeated END may
have a new clock value while preserving its token. Non-success acknowledgements
use a separate counter and do not perform the normal successful boundary operation;
the fifth such outcome changes a local transfer limit. Neither branch provides an
exactly-once delivery promise across disconnects. The application should tolerate
repeated boundaries and records, retain arrival order, and stop an incomplete
attempt without acknowledging data it could not persist.

The read cursor and the acknowledged/trim boundary are separate. A backing-page
read error can advance the read cursor and return an error. That observation does
not prove physical deletion or advancement of the acknowledged boundary. It does
mean the client must not assume that the very next read automatically retries the
same failed page. Preserve decode/read failures as part of synchronization evidence.

The extended range response contains page positions, capacity, estimates and four
clock pairs. Read and write positions are page slots, not timestamps. The selected
ring uses 4096-byte page slots, which can contain multiple records. The count
estimate can fall back to fifteen records per page, so it should not be treated as
an exact number of application rows or a duration. The clock pairs are selected
from a boundary page, the trim-side page, the read-side page, and the last written
page. Empty-side cases can select the preceding page. Failed reads use an all-ones
six-byte sentinel; its two-byte companion becomes 65535 when widened for the
response. Keep sentinel and zero fallbacks separate from usable time values.

### Battery replies and cached accessory information

The normal battery request schedules a measurement before returning its percentage.
The physical measurement's error/timeout event takes a preparation continuation
that differs from the normal percentage callback. Therefore the ordinary callback's
failure-body layout does not establish a guaranteed battery reply after every
measurement timeout. Correlate the requested command and apply a bounded client wait.

Battery-pack information is cached. Both the full accessory record and its smaller
charge update copy received values without local scale conversion. The strap-side message contract alone does not independently establish a physical percentage
scale for that raw charge value. Preserve the raw value and apply only a separately
verified interpretation. A successful cache query is not proof of a live accessory
measurement or freshness.

### Interruption and recovery

a fresh history preparation restores the read position to the
acknowledged boundary when all stored ring positions are valid. Previously
received but unacknowledged records can therefore recur. Preparation failure can
also enter streaming, so START does not prove that restoration succeeded.

Connection loss exits history preparation, streaming or END wait and cancels their
transfer timers and subscriptions. Leaving history can itself queue COMPLETE when
the cached backlog is at most six; queueing proves neither delivery nor that all
source records were acknowledged. Reconcile completion metadata with persisted
progress and backlog. On the fifth END-wait timeout the attempt leaves history;
a later preparation performs the rewind, rather than that timeout immediately
restarting it. Earlier timeout retries resend END in the existing wait.

Persist data before ACK, retain the complete original token and tolerate duplicate
records. After reconnect, restore the application's subscriptions and reconcile
requested collection with actual output; automatic restoration of every sensor
request is not established.

Connection loss, a Bluetooth controller restart and full application startup are
distinct operations. Controller restart does not prove sensor session requests
were initialized again. On the successful application-start path, sensor
initialization clears temporary
collection requests and staged/live state. Later policy evaluation can reassert
persistent or continuous collection preferences. This startup initialization does
not establish that every reset command completes that path.
Temporary silence does not prove acquisition or history
recording stopped. Track persistent collection preferences separately from
temporary collection requests.

Connection establishment is not an acknowledgement that ECG or sensor sessions
were restored. Avoid blindly resending ECG start; [repeated starts](PROTOCOL_ECG.md#repeated-ecg-start-and-companion-collection)
can lose the bookkeeping used for companion collection cleanup.

## Connection and error recovery boundaries

Connection establishment is not a sensor-session restoration acknowledgement.
Selected connection handling cancels a connection-related timer and finishes
internal duration measurements; it does not establish that the app's previous
ECG or raw-sensor requests have been restored.

Diagnostic records are best-effort evidence of lifecycle activity. A record can
be created and submitted internally but rejected later when the storage service's
queue has no free slot. Missing diagnostic records therefore do not prove that
an error or connection transition did not occur, and submission does not certify
durable storage.

Error handling is conditional. The selected recovery policy distinguishes its
error reason from the ordinary link-loss reason, checks a matching occurrence
count, checks pending-state guards and stored bookkeeping, and schedules deferred
storage coordination. Do not treat every disconnect as an application reset or
as a request that clears all sensor sessions. Neither recovery scheduling nor a
new connection certifies acquisition state, completed reboot or durable storage.

A guarded internal recovery sequence coordinates with storage and then enters a
fault-handling path after deferred steps. This sequence provides no application
acknowledgement guaranteeing that storage completed, a restart succeeded, or a
previous sensor session returned. It is not the generic behavior of ordinary
link loss. Clearing a related failure indicator does not, in the corresponding
handlers, cancel an already pending recovery sequence.
