#!/usr/bin/env python3
"""Constructed protocol arithmetic examples, never device captures.

Checks selected field/count arithmetic only. Buffers have no framing/checksums
and are not valid transport frames. Does not test NOOP, firmware execution,
physical units, device compatibility, sensor rate or clinical interpretation.
"""
from bisect import bisect_left
import struct


def filtered_words(buffer):
    if len(buffer) != 240 or buffer[9] != 17:
        raise ValueError("unsupported illustrative layout")
    count = struct.unpack_from("<H", buffer, 32)[0]
    if count > 100:
        raise ValueError("count exceeds fixed capacity")
    return list(struct.unpack_from(f"<{count}h", buffer, 34))


def imu_stream_spans(buffer, data_end):
    """Illustrative count bounds; caller must validate framing and data_end first."""
    if not 28 <= data_end <= len(buffer):
        raise ValueError("missing count header or invalid data boundary")
    a, g = struct.unpack_from("<HH", buffer, 24)
    end = 28 + 6 * a + 6 * g
    if end > data_end:
        raise ValueError("sample arrays exceed data boundary")
    starts = [28, 28 + 2*a, 28 + 4*a, 28 + 6*a,
              28 + 6*a + 2*g, 28 + 6*a + 4*g, end]
    return list(zip(starts, starts[1:]))


def raw_ecg_value(b0, b1, b2):
    """Decode the signed 18-bit wire value and its separate two flags."""
    raw = ((b0 & 3) << 16) | (b1 << 8) | b2
    signed = raw if raw < 131072 else raw - 262144
    return signed, (b0 >> 6) & 1, (b0 >> 7) & 1


def contact_index_500_10(sample_index):
    """Application lookup of the documented group ends, not a general timing model."""
    if not 0 <= sample_index < 500:
        raise ValueError("sample outside the specified 500-entry case")
    return bisect_left([50, 100, 150, 200, 250, 300, 350, 400, 450, 499], sample_index)


def config_value(result, body, requested_key):
    """Client-side bounded adoption of an already separated logical GET body."""
    if result != 1 or len(body) != 65 or body[0] != 1:
        raise ValueError("no successful revision-1 value")
    canonical = requested_key[:31].ljust(32, b"\0")
    if body[1:33] != canonical or b"\0" not in body[33:65]:
        raise ValueError("mismatched key or unbounded text")
    return body[33:65].split(b"\0", 1)[0]


def battery_percent(result, body):
    if result != 1 or len(body) != 4:
        raise ValueError("no complete successful battery value")
    return struct.unpack("<I", body)[0]


def completion_examples():
    # Constructed logical bodies only, with no identity values or real captures.
    key = b"cont_collection_mode"
    good = b"\1" + key.ljust(32, b"\0") + b"1".ljust(32, b"\0")
    assert config_value(1, good, key) == b"1"
    invalid = [(0, good, key), (2, good, key), (1, good[:-1], key),
               (1, good, b"enable_rfid"), (1, good[:33] + b"1" * 32, key)]
    for args in invalid:
        try:
            config_value(*args)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid readback adopted")
    long_key = b"k" * 32
    normalized = b"\1" + long_key[:31] + b"\0" + b"0".ljust(32, b"\0")
    assert config_value(1, normalized, long_key) == b"0"
    assert battery_percent(1, struct.pack("<I", 47)) == 47
    assert battery_percent(1, b"\0" * 4) == 0  # Valid value, not proof of depletion.
    for result, body in [(0, b"\0" * 4), (2, b"\0" * 4), (1, b"\x2f")]:
        try:
            battery_percent(result, body)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid battery reply adopted")

    # Wire timing math for valid R21 RTC hundredths; no jitter/rate assumption.
    fractions = [hundredths * 32768 // 100 for hundredths in range(100)]
    assert [fractions[i] for i in (0, 1, 50, 99)] == [0, 327, 16384, 32440]
    assert all(0 <= h / 100 - f / 32768 < 1 / 32768
               for h, f in enumerate(fractions))

    # App expectation after delivered events: shared requests are not leases.
    session = {"optical": False, "imu": False}
    persistent_imu = True
    shared_raw = True
    session.update(optical=True, imu=True)  # ECG companion start delivered.
    session.update(optical=False, imu=False)  # Individual/ECG session stops.
    assert shared_raw  # Raw still owns the additional shared request.
    shared_raw = False  # Later raw stop also clears this request.
    assert not any(session.values())
    assert persistent_imu or session["imu"]  # Other policy can still request IMU.
    assert not (100 > 100) and 101 > 100  # Strict maximum-backlog comparison.

    # Constructed request/application ordering; not a timing or device test.
    active, staged, pending = False, False, False
    for requested in (True, False):
        if requested != active:
            staged, pending = requested, True
    assert requested is False and staged is True and pending
    active, pending = staged, False  # Successful deferred application.
    assert active is True and requested is False

    token = struct.pack("<II", 7, 2)
    persisted_token = bytes(token)
    acknowledgement = b"\1" + persisted_token
    assert acknowledgement[1:] == token and len(acknowledgement) == 9
    sentinel_pair = struct.pack("<II", 0xffffffff, 0xffff)
    assert struct.unpack("<II", sentinel_pair) == (4294967295, 65535)

    # Constructed client comparisons against the documented AFE readback rules.
    contribution, setting3 = 100, 20
    assert (contribution + setting3) % 2**32 == 120
    setting3 = 30
    assert (contribution + setting3) % 2**32 == 130
    assert ((2**32 - 1) + 1) % 2**32 == 0


def main():
    completion_examples()
    # Construct fields directly: these are not checksum-valid transport frames.
    buffer = bytearray(240)
    buffer[9] = 17
    struct.pack_into("<H", buffer, 32, 3)
    struct.pack_into("<3H", buffer, 34, 17, 0, 65530)
    struct.pack_into("<H", buffer, 234, 54321)  # Deliberate padding poison.
    assert filtered_words(buffer) == [17, 0, -6]
    struct.pack_into("<3h", buffer, 34, -32768, 0, 32767)
    assert filtered_words(buffer) == [-32768, 0, 32767]
    struct.pack_into("<H", buffer, 32, 100)
    assert len(filtered_words(buffer)) == 100
    assert -11215 not in filtered_words(buffer)  # Signed interpretation of padding poison.
    assert filtered_words(buffer)[-1] == 0
    struct.pack_into("<H", buffer, 32, 101)
    try:
        filtered_words(buffer)
    except ValueError:
        pass
    else:
        raise AssertionError("out-of-capacity count accepted")

    # Independent wire decoding, including signed endpoints and separate flags.
    assert raw_ecg_value(0xC2, 0x35, 0x79) == (-117383, 1, 1)
    for b0, b1, b2, expected in [(0, 0, 0, 0), (1, 255, 255, 131071),
                                  (2, 0, 0, -131072), (3, 255, 255, -1)]:
        for flags in (0, 0x40, 0x80, 0xC0):
            assert raw_ecg_value(b0 | flags, b1, b2) == (
                expected, (flags >> 6) & 1, (flags >> 7) & 1)

    # Application lookup for the documented 500-raw/10-slower case only.
    boundaries = {0: 0, 50: 0, 51: 1, 100: 1, 101: 2, 450: 8, 451: 9, 499: 9}
    assert {i: contact_index_500_10(i) for i in boundaries} == boundaries
    indices = [contact_index_500_10(i) for i in range(500)]
    assert [indices.count(i) for i in range(10)] == [51] + [50] * 8 + [49]
    for invalid in (-1, 500):
        try:
            contact_index_500_10(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError("out-of-range contact index accepted")

    # Transmitted clipped deltas reconstruct an approximation, not the source.
    original = [1000, 51000, 50900]
    deltas = [max(-32768, min(32767, b - a))
              for a, b in zip(original, original[1:])]
    reconstructed = [original[0]]
    for delta in deltas:
        reconstructed.append(reconstructed[-1] + delta)
    assert deltas == [32767, -100]
    assert reconstructed == [1000, 33767, 33667]
    assert original[-1] - reconstructed[-1] == 17233

    # Synthetic unequal counts expose wrong interleaving and A/G reuse.
    imu = bytearray(62)
    struct.pack_into("<HH", imu, 24, 2, 3)
    assert imu_stream_spans(imu, 58) == [(28, 32), (32, 36), (36, 40),
                                                   (40, 46), (46, 52), (52, 58)]
    for end in (27, 57, 63):
        try:
            imu_stream_spans(imu, end)
        except ValueError:
            pass
        else:
            raise AssertionError("invalid IMU boundary accepted")
    struct.pack_into("<HH", imu, 24, 65535, 65535)
    try:
        imu_stream_spans(imu, 58)
    except ValueError:
        pass
    else:
        raise AssertionError("oversized IMU counts accepted")
    struct.pack_into("<HH", imu, 24, 0, 0)
    assert imu_stream_spans(imu, 28) == [(28, 28)] * 6

    assert [(n * 1000 + 512) // 1024 for n in (512, 1024, 1536)] == [500, 1000, 1500]
    print("PASS: constructed R17 bounds/padding, signed ECG values/flags, contact boundaries, R26 clipping, RR arithmetic, response adoption, R21 ticks, shared requests, AFE sums, partial IMU count bounds")
    print("Coverage: field arithmetic only; no CRC, device, firmware or calibration validation")


if __name__ == "__main__":
    main()
