# WHOOP BLE protocol

An interoperability reference for apps communicating directly with WHOOP straps.
Start with the device profile, then follow the operation or record you need.
Documentation coverage is broader than NOOP’s implemented command and decoder subset.

<a id="whoop-40--service-61080001-"></a>
<a id="whoop-50--mg--service-fd4b0001-"></a>
<a id="21-whoop-40-envelope"></a>
<a id="22-whoop-50--mg-envelope"></a>
<a id="5-bond-handshake--connect-lifecycle-whoop-40"></a>
<a id="9-whoop-50-vs-mg--telling-the-hardware-apart"></a>
<a id="get_hello_harvard-35-response--the-whoop-40-serial"></a>

## Scope and compatibility

WHOOP 4 and WHOOP 5/MG share protocol concepts, but have different GATT services,
frame headers and connection flows. A shared command name does not establish the
same request or response bytes. WHOOP 5 historical data is not a WHOOP 4 layout
with shifted offsets.

The WHOOP 5/MG topic references use **firmware 50.42.1.0** as their common baseline
unless a passage explicitly identifies an earlier observation or a client-only
interpretation. The compared WHOOP 5 and MG firmware images were byte-identical;
this supports one shared profile, while ECG still depends on hardware capability.
It does not establish identical images across every release or identical features
on both devices. These baseline contracts do not claim device validation.

Earlier NOOP observations cover ECG on MG **50.39.1.0**, optical/IMU decoding and
reboot on **50.40.1.0**, R-R conversion on **50.41.1.0**, and older Hello decoding
on **50.38.1.0**. The WHOOP 4 enumeration report used **41.16.6.0**. Client-only IMU
stream descriptions refer to Android app **5.465.0**. Their distinct limits remain
at the relevant operation; they do not override the baseline. WHOOP 4 is a legacy
implementation/capture profile, with no equivalent complete command coverage here.

| Profile | Start here | Interpretation |
|---|---|---|
| WHOOP 4 | [WHOOP 4 profile](PROTOCOL_WHOOP4.md) | Legacy connection, framing, identity and record conventions |
| WHOOP 5 / MG | [WHOOP 5 / MG profile](PROTOCOL_WHOOP5.md) | Shared transport; check capabilities independently |
| All readers | [Shared concepts](PROTOCOL_CONCEPTS.md) | Integrity, request lifecycle and durable history handling |

Command revision, record layout and inner record version remain explicit byte
selectors throughout the reference. Unknown means unresolved, not unsupported.
“Defined” does not mean available in every state or fully implemented by NOOP.

<a id="extended-protocol-reference"></a>
<a id="1-gatt-topology"></a>
<a id="diagnostic-only-whoop-service-families"></a>
<a id="standard-sig-services-both-generations"></a>
<a id="2-frame-envelope"></a>
<a id="23-family-aware-entry-points"></a>
<a id="24-command_response-body"></a>
<a id="25-checksums"></a>
<a id="26-reassembly"></a>
<a id="3-packettype-offset-4-or-8-on-50"></a>
<a id="4-eventnumber-event-type-48"></a>
<a id="6-commandnumber-sending--the-safe-subset"></a>
<a id="additional-5-class-command-numbers"></a>
<a id="destructive-commands--do-not-send"></a>
<a id="7-historical-data-offload-backfill"></a>
<a id="71-metadatatype-metadata6"></a>
<a id="72-history_end-payload-layout"></a>
<a id="73-session-state-machine"></a>
<a id="74-safe-trim-invariant"></a>
<a id="75-watchdog--liveness"></a>
<a id="8-decoded-output-parsedframe"></a>
<a id="91-ecg-labrador-on-the-mg"></a>
<a id="10-spo₂-on-50--mg--what-the-wire-does-and-does-not-carry"></a>
<a id="companion-reference-corrections--504210"></a>
<a id="previous-section-links"></a>

## Reading guide

| Task | Authoritative topic |
|---|---|
| Frame, correlate and recover a connection | [Transport](PROTOCOL_TRANSPORT.md) |
| Find an operation or its limitations | [Command reference](PROTOCOL_COMMANDS.md): 159 IDs, 71 defined and 88 unsupported in the baseline context |
| Configure collection and output | [Configuration](PROTOCOL_CONFIGURATION.md): 8 device keys and 25 feature descriptors |
| Decode measurements | [Sensor records](PROTOCOL_SENSORS.md) |
| Control and decode MG ECG | [ECG](PROTOCOL_ECG.md) |
| Schedule or stop an alarm | [Alarms](PROTOCOL_ALARMS.md) |
| Understand image transfer and authorization | [Updates and authorization](PROTOCOL_UPDATES.md) |
| Work on NOOP’s integration | [Implementation and historical observations](PROTOCOL_IMPLEMENTATION.md) |
| Reproduce selected parsing rules | [Constructed examples](protocol-examples/validate_examples.py) |

Each contract has one authoritative topic. Historical experiments, client timers
and decoder conventions are labeled separately. In particular, the older
[deep-data experiment](WHOOP5_DEEP_DATA.md) is not a universal enable recipe.

## Remaining boundaries

Absolute ECG sample timing and voltage calibration, some physiological field
meanings, complete bootloader acceptance and several runtime/error interactions
remain unresolved. Local limits are recorded beside each contract. Constructed
examples check selected arithmetic and state rules; they are not device tests.

<a id="11-file-map"></a>

## Project and credits

NOOP is an independent, offline companion and is not affiliated with WHOOP or a
medical device. See [disclaimer](../DISCLAIMER.md) and [attribution](../ATTRIBUTION.md).
The existing work builds on `johnmiddleton12/my-whoop` (WHOOP 4) and
`b-nnett/goose` (WHOOP 5); further credits remain with the historical observations.
The Swift protocol package and Android implementation are indexed in the
[file map](PROTOCOL_IMPLEMENTATION.md#11-file-map).
