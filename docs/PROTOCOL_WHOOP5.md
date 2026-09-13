# WHOOP 5 / MG profile

Read the [scope and compatibility](PROTOCOL.md#scope-and-compatibility) before applying this page.

## WHOOP 5.0 / MG — service `fd4b0001-…`

The 5.0 transport ("puffin") adds a fifth characteristic (`…0007`). UUID strings are in
`DeviceFamily.characteristicUUIDStrings`.

| Role | UUID |
|------|------|
| Custom service | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Command write | `fd4b0002-cce1-4033-93ce-002d5875f58a` |
| Notify channels | `fd4b0003`, `fd4b0004`, `fd4b0005`, `fd4b0007` (`…-cce1-4033-93ce-002d5875f58a`) |

NOOP's historical "puffin" label refers to this fd4b Maverick/Goose framing. Decompiled WHOOP app
taxonomy also names a separate `PUFFIN` service family at
`11500001-6215-11ee-8c99-0242ac120002`; NOOP names that metadata `puffin1150` to avoid confusing it
with the implemented fd4b path.

<a id="9-whoop-50-vs-mg--telling-the-hardware-apart"></a>

## WHOOP 5.0 vs MG — telling the hardware apart

Both labels share the `fd4b…` GATT family and the same puffin envelope: the shared framing and parser family is represented by `DeviceFamily.whoop5`. Hardware capabilities and record availability still need to be checked separately. What differs is hardware —
an MG carries the ECG-conductive clasp, a 5.0 does not.

NOOP's `Whoop5Variant` resolver uses the standard BLE Device Information Service,
separately from `DeviceFamily`. Its current identification policy is listed below;
these matching rules do not change frame parsing.

| Signal | DIS characteristic | Reads |
|---|---|---|
| Model number `MG` (case-insensitive, surrounding whitespace ignored) | Model Number String (`0x2A24`) | MG; takes priority over the fallback signals below |
| Serial prefix `5AM` | Serial Number String (`0x2A25`) | MG |
| Serial prefix `5AG` | Serial Number String (`0x2A25`) | 5.0 |
| Hardware revision contains `WG50` | Hardware Revision String (`0x2A27`) | 5.0 |

Without an explicit `MG` model number, conflicting `5AM` serial and `WG50` hardware
signals resolve to `.unknown`. Unknown variants do not enable MG-only features.
An MG has also been observed with a different serial prefix and hardware revision;
there is no universal MG hardware-revision token in this resolver. Absence of a
recognized prefix therefore does not establish that the strap lacks MG hardware.

## Connection and frame format

Subscribe to the fd4b notification channels and write the static client hello below to the command characteristic with response. WHOOP 4’s bond/hello sequence is a separate profile. Framing, padding, response correlation and recovery are defined once in [transport](PROTOCOL_TRANSPORT.md).

```text
AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D
```

## Operations and measurements

Use [commands](PROTOCOL_COMMANDS.md), [configuration](PROTOCOL_CONFIGURATION.md) and [sensor records](PROTOCOL_SENSORS.md) together. Packet type, record layout and inner version are different selectors; the receiver must decode what was emitted. MG [ECG](PROTOCOL_ECG.md) requires the appropriate hardware capability. A successful request alone does not prove sensor initialization or delivered data.
