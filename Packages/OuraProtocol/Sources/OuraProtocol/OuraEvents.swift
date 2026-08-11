import Foundation

// OuraEvents: the decoded value structs the driver emits (OURA_PROTOCOL.md s6). Each carries the
// record's ringTimestamp (the ring-clock value; the app anchors it to UTC via the 0x42 time-sync /
// 0x85 RTC events) plus the decoded signal. Pure value types, no CoreBluetooth.
//
// Per-sample timestamps inside a record (IBI/temp/HRV/SpO2) walk backward from the event time by each
// sample's own duration (OURA_PROTOCOL.md s6); to stay platform-pure and avoid baking a clock model
// into the decoders, the structs carry the raw ring/sample offsets and let the app's mapping layer
// (OuraStreamMapping) apply the anchor. Honest-data invariant: a short/malformed record decodes to
// nil upstream, so these structs only ever hold real decoded values.

/// WHICH optical channel decoded an `OuraIBI` (#1071).
///
/// The ring reports the SAME heartbeats on more than one tag. They are not different beats and not
/// duplicate records — they are independent measurements of one beat train, so a consumer that folds
/// them together holds two copies of every night and every variability statistic built on successive
/// differences (RMSSD, SDNN) breaks. The tag is the only thing that separates them at ingest; after the
/// fact the two are only separable by the accident that their quantisation grids differ.
///
/// The raw values are the DURABLE cross-platform storage codes (they reach `rrInterval.srcChannel` via
/// `WhoopProtocol.RRSourceChannel`, which pins the same numbers, and the Kotlin twin `OuraIbiChannel`).
/// Never renumber a case; only append.
public enum OuraIBIChannel: Int, Equatable, Sendable, Codable, CaseIterable {
    /// 0x80 `green_ibi_quality_event` (s6.4) — green LED, gated on the ring's own `quality == 1` flag
    /// and a 300-2000 ms physiological window, and it runs for the WHOLE wear period.
    case greenQuality = 1
    /// 0x6E `spo2_ibi_and_amplitude_event` (s6.3) — the SpO2 measurement's own beat train, quantised to
    /// an 8 ms grid with NO quality gate, and only present while an SpO2 measurement is running.
    case spo2Ibi = 2
    /// 0x60 `ibi_and_amplitude_event` (s6.1) — the bit-packed IBI + amplitude family.
    case ibiAmplitude = 3
    /// 0x44 `ibi_event` (s6 / s0) — the SAME bit-packed layout as 0x60 and decoded by the same routine,
    /// but a DIFFERENT tag on the wire, so it gets its own code.
    ///
    /// Both tags stamped `ibiAmplitude` until now, which made them indistinguishable once stored. That
    /// hid the question the scoring-channel choice turns on: when that channel covers 1.25x the
    /// wall-clock it spans, is ONE tag repeating beats across its records, or are TWO tags reporting the
    /// same beats to each other? No stored night could answer it, because the label collapsed them.
    /// Separating the codes costs nothing and makes the next capture decisive. Labelling only — both
    /// tags decode and are read exactly as before.
    case ibiBare = 4
}

/// One decoded inter-beat interval (and optional amplitude), in milliseconds.
public struct OuraIBI: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let ibiMs: Int
    public let amplitude: Int?
    /// Which optical channel measured this beat (#1071). Every decoder stamps its own; nil only for a
    /// value built by something that is not one of them.
    public let channel: OuraIBIChannel?
    public init(ringTimestamp: UInt32, ibiMs: Int, amplitude: Int? = nil,
                channel: OuraIBIChannel? = nil) {
        self.ringTimestamp = ringTimestamp; self.ibiMs = ibiMs; self.amplitude = amplitude
        self.channel = channel
    }
}

/// One decoded heart-rate value in BPM (derived from a live-HR push IBI, OURA_PROTOCOL.md s5.6).
public struct OuraHR: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let bpm: Int
    public let ibiMs: Int
    public init(ringTimestamp: UInt32, bpm: Int, ibiMs: Int) {
        self.ringTimestamp = ringTimestamp; self.bpm = bpm; self.ibiMs = ibiMs
    }
}

/// One decoded 5-minute HRV bucket from the ring's own 0x5D tag (OURA_PROTOCOL.md s6.9): the ring's
/// OWN average HR and RMSSD for that bucket. The 0x5D body is a run of `(u8 avg HR bpm, u8 avg RMSSD ms)`
/// pairs, one per 5 min; `index` is the pair's position in the record. This is the ring's open HRV tag,
/// NOT Oura's encrypted readiness score. NOOP also reconstructs RMSSD from the IBI streams for its own
/// scoring; this tag is the ring's own summary (validated overnight — the hr byte tracks sleeping HR).
public struct OuraHRV: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    /// 0-based pair index within the record, counting from the record's FIRST byte-pair — which is its
    /// **OLDEST** bucket (#1167). The consumer needs `count` as well as `index` to place the bucket:
    /// `bucketTs = ts - (count - index) * 300`.
    public let index: Int
    /// The ring's average HR for the 5-min bucket, in bpm (u8, no scaling).
    public let hrBpm: Int
    /// The ring's average RMSSD for the 5-min bucket, in ms (u8, no scaling).
    public let rmssdMs: Int
    /// Total pairs in the record this bucket came from — INCLUDING any `00 00` padding pair the decoder
    /// dropped (#1128/#1131). `index` is always in `0..<count`. Needed because the record's timestamp
    /// marks the END of the span it covers, so a bucket's offset is measured from the record's tail, not
    /// its head: dropping a pad without counting it would slide every surviving bucket in the record.
    /// Mirrors `OuraSpO2.count`, which the SpO2 path already uses for the same reason.
    public let count: Int
    public init(ringTimestamp: UInt32, index: Int, hrBpm: Int, rmssdMs: Int, count: Int = 1) {
        self.ringTimestamp = ringTimestamp; self.index = index; self.hrBpm = hrBpm
        self.rmssdMs = rmssdMs; self.count = count
    }
}

/// One decoded SpO2 sample. `value` is the raw SpO2 reading; `unit` documents its scale.
///
/// A single 0x6F / 0x77 record carries MANY samples, all sharing the record's `ringTimestamp`.
/// `index`/`count` carry the sample's position within its record so the consumer can give each one its
/// own second — without them the position is lost at decode time and cannot be recovered downstream,
/// which is exactly how 12 of every 13 samples were silently dropped on the `(deviceId, ts)` primary
/// key (#1070). `ringTimestamp` is deliberately left at the RECORD's time: it is the wire anchor, and
/// the per-sample offset is applied where the durable row is minted (`OuraStreamMapping`), the same
/// split the hypnogram path already uses. `index` mirrors `OuraSleepPhase.index`.
///
/// Both default (`index: 0, count: 1` = "the only sample in its record"), so single-sample decoders
/// like 0x7B keep the record's own second unchanged.
public struct OuraSpO2: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let value: Int
    public let unit: String
    /// 0-based position of this sample within its record; samples are 1 s apart (consumer applies it).
    public let index: Int
    /// Total samples decoded from the same record. `index` is always in `0..<count`.
    public let count: Int
    public init(ringTimestamp: UInt32, value: Int, unit: String = "raw", index: Int = 0, count: Int = 1) {
        self.ringTimestamp = ringTimestamp; self.value = value; self.unit = unit
        self.index = index; self.count = count
    }
}

/// One decoded skin-temperature sample in hundredths of a degree C scaled to C (value already / 100).
public struct OuraTemp: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let celsius: Double
    public init(ringTimestamp: UInt32, celsius: Double) {
        self.ringTimestamp = ringTimestamp; self.celsius = celsius
    }
}

/// One decoded battery reading (OURA_PROTOCOL.md s6.10). `percent` is read at body[0]; `voltageMv`
/// is the [4..6] fallback estimate (fixture-validated per generation, may be nil).
public struct OuraBattery: Equatable, Sendable, Codable {
    public let percent: Int
    public let voltageMv: Int?
    public let charging: Bool?
    public init(percent: Int, voltageMv: Int? = nil, charging: Bool? = nil) {
        self.percent = percent; self.voltageMv = voltageMv; self.charging = charging
    }
}

/// The 2-bit sleep-phase code values, per open_oura's VALIDATED `decode_sleep_phases` mapping
/// (events.rs `PHASE = ["deep", "light", "rem", "awake"]`): 0=deep, 1=light, 2=rem, 3=awake.
///
/// CORRECTION (2026-07-11): NOOP previously mapped 0=awake/2=deep/3=rem from the same unverified doc
/// as the rest of s6.12. Two live captures contradict that: phase records decoded AT WAKE (wearer
/// demonstrably awake) carry code 3 — awake under open_oura's mapping, "REM" under the old one. The
/// raw code is what persists (`stage.rawValue`); only these LABELS changed, so stored rows are stable.
public enum OuraSleepStage: Int, Sendable, Equatable, Codable {
    case deep  = 0
    case light = 1
    case rem   = 2
    case awake = 3
}

/// One decoded sleep-phase code in order within a 0x4E/0x5A record (OURA_PROTOCOL.md s6.12).
public struct OuraSleepPhase: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let index: Int          // position within the record's phase sequence
    public let stage: OuraSleepStage
    /// #1246: this epoch came from an UNWRITTEN hypnogram page (a whole record of the erased-flash value
    /// `0xFF`, which the 2-bit decode would otherwise read as four `awake` codes). It keeps a placeholder
    /// `stage` so it still OCCUPIES its 30 s slot in the burst's time axis (dropping it would mis-time the
    /// real codes laid around it), but the assembler EXCLUDES it from the reconstructed hypnogram — a gap,
    /// not `awake`. Defaults false so every real decoded/constructed phase is a written epoch.
    public let unwritten: Bool
    public init(ringTimestamp: UInt32, index: Int, stage: OuraSleepStage, unwritten: Bool = false) {
        self.ringTimestamp = ringTimestamp; self.index = index; self.stage = stage
        self.unwritten = unwritten
    }
}

/// Motion state (OURA_PROTOCOL.md s6.13): 0 NO_MOTION, 1 RESTLESS, 2 TOSSING, 3 ACTIVE.
public enum OuraMotionState: Int, Sendable, Equatable, Codable {
    case noMotion = 0
    case restless = 1
    case tossing = 2
    case active = 3
}

/// One decoded motion-state code from a 0x6B motion_period record (OURA_PROTOCOL.md s6.13).
public struct OuraMotion: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let index: Int
    public let state: OuraMotionState
    public init(ringTimestamp: UInt32, index: Int, state: OuraMotionState) {
        self.ringTimestamp = ringTimestamp; self.index = index; self.state = state
    }
}

/// One decoded 0x47 `motion_events` record: the ring's OWN averaged accelerometer vector for the period,
/// plus an orientation code and a high-intensity count (open_oura `decode_motion`, clean-room fact
/// citation; OURA_PROTOCOL.md s6.13). This is the SAME shape as a WHOOP 4.0 gravity sample — an averaged
/// `(x, y, z)` vector, NOT a per-sample raw accel — so it can feed the same motion pipeline. Axis values
/// are the signed record bytes scaled ×8 (open_oura's convention); the LSB→g scale for NOOP's stager is
/// a downstream calibration, so this struct carries the ring's raw ×8 integers, unscaled and honest.
public struct OuraMotionEvent: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    /// Orientation code 0…7 (record byte0, TOP 3 bits: `b0 >> 5`).
    public let orientation: Int
    /// Seconds of motion in the window (record byte0, low 5 bits: `b0 & 0x1f`, 0…31). A direct
    /// motion-intensity measure — arguably the cleanest activity signal for sleep staging.
    public let motionSeconds: Int
    /// Averaged X/Y/Z, signed record byte × 8 (open_oura `decode_motion`).
    public let avgX: Int
    public let avgY: Int
    public let avgZ: Int
    /// Low/high-intensity counts (record byte4/byte5, `& 0x3f`, 0…63). nil when the record is short
    /// (< 5 / < 6 bytes) — both are optional in the wire format.
    public let lowIntensity: Int?
    public let highIntensity: Int?
    public init(ringTimestamp: UInt32, orientation: Int, motionSeconds: Int, avgX: Int, avgY: Int,
                avgZ: Int, lowIntensity: Int?, highIntensity: Int?) {
        self.ringTimestamp = ringTimestamp; self.orientation = orientation
        self.motionSeconds = motionSeconds
        self.avgX = avgX; self.avgY = avgY; self.avgZ = avgZ
        self.lowIntensity = lowIntensity; self.highIntensity = highIntensity
    }
}

/// Device lifecycle state (OURA_PROTOCOL.md s6.15) decoded from a 0x45/0x53 record.
public struct OuraState: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let stateCode: Int
    public let text: String?
    public init(ringTimestamp: UInt32, stateCode: Int, text: String? = nil) {
        self.ringTimestamp = ringTimestamp; self.stateCode = stateCode; self.text = text
    }
}

/// A decoded feature-status read reply (the `0x2F` sub-op `0x21` response): the ring's own report of a
/// feature's mode / status / state / subscription. Read-only diagnostic — used to confirm the server-flag
/// gate on SpO2 (`0x04`) / real_steps (`0x0b`): a `subscription == 0` with no emitted records is the ring
/// saying "the cloud has not enabled this", which NOOP cannot override offline. Never scored, never stored.
public struct OuraFeatureStatus: Equatable, Sendable, Codable {
    public let feature: Int
    public let mode: Int
    public let status: Int
    public let state: Int
    public let subscription: Int
    public init(feature: Int, mode: Int, status: Int, state: Int, subscription: Int) {
        self.feature = feature; self.mode = mode; self.status = status
        self.state = state; self.subscription = subscription
    }
}

/// A UTC anchor / time-sync event (OURA_PROTOCOL.md s6.11): epoch ms + timezone offset seconds.
public struct OuraTimeSync: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let epochMs: Int64
    public let tzOffsetSeconds: Int
    public init(ringTimestamp: UInt32, epochMs: Int64, tzOffsetSeconds: Int) {
        self.ringTimestamp = ringTimestamp; self.epochMs = epochMs; self.tzOffsetSeconds = tzOffsetSeconds
    }
}

/// A secondary 1-second-granularity RTC beacon (OURA_PROTOCOL.md s6.15, tag 0x85).
public struct OuraRtcBeacon: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let unixSeconds: Int
    public init(ringTimestamp: UInt32, unixSeconds: Int) {
        self.ringTimestamp = ringTimestamp; self.unixSeconds = unixSeconds
    }
}

// MARK: - Tier-B (UNVERIFIED) decoded events

/// A Tier-B sleep summary value (OURA_PROTOCOL.md s6.12). UNVERIFIED layout; carries the raw payload
/// bytes plus the tag so a fixture test can validate before scoring trusts it. The driver only emits
/// this when allowTierB is set, and it is never folded into scoring silently.
public struct OuraTierBSummary: Equatable, Sendable, Codable {
    public let tag: UInt8
    public let ringTimestamp: UInt32
    public let rawPayload: [UInt8]
    public let kind: String        // "sleep_summary" / "activity" / "real_steps" / "spo2_smoothed"
    public init(tag: UInt8, ringTimestamp: UInt32, rawPayload: [UInt8], kind: String) {
        self.tag = tag; self.ringTimestamp = ringTimestamp; self.rawPayload = rawPayload; self.kind = kind
    }
}

/// One decoded `0x50` activity_info record: a `state` code (activity-category; meaning unconfirmed)
/// plus a per-sample MET (metabolic-equivalent) series. THIRD-PARTY FORMULA (OURA_PROTOCOL.md s6.13,
/// [oura-rs] - clean-room fact citation, no code copied): plausible against six real Gen 3 captures
/// from PR #960's investigation (resting ~0.9 MET through a vigorous-activity burst at 7.4 MET, all
/// physiologically sane), but NOT independently ground-truth-validated against the Oura app's own
/// numbers. It therefore stays Tier B: emitted only behind `OuraDriver.allowTierB`, and NEVER folded
/// into `OuraStreamMapping`/`Streams`/scoring (steps stay honest - no step count is minted from MET).
public struct OuraActivityInfo: Equatable, Sendable, Codable {
    public let ringTimestamp: UInt32
    public let state: Int
    public let met: [Double]
    public init(ringTimestamp: UInt32, state: Int, met: [Double]) {
        self.ringTimestamp = ringTimestamp; self.state = state; self.met = met
    }
}

// MARK: - The emitted event union

/// What OuraDriver.ingest(record:) emits. A single record can yield several events (e.g. an IBI+amp
/// record carries up to 6 IBIs). Tier-B events are wrapped in .tierB (or .activityInfo) and only
/// emitted when the driver is configured to allow them; they must never feed scoring without passing
/// a real-capture fixture.
public enum OuraEvent: Equatable, Sendable {
    case hr(OuraHR)
    case ibi(OuraIBI)
    case hrv(OuraHRV)
    case spo2(OuraSpO2)
    case temp(OuraTemp)
    case battery(OuraBattery)
    case sleepPhase(OuraSleepPhase)
    case motion(OuraMotion)
    /// A decoded `0x47` motion_events record: the ring's averaged accel vector (Tier-A). Distinct from
    /// `.motion` (the 0x6B period's 2-bit state codes).
    case motionEvent(OuraMotionEvent)
    case state(OuraState)
    case timeSync(OuraTimeSync)
    case rtcBeacon(OuraRtcBeacon)
    case debugText(ringTimestamp: UInt32, text: String)
    /// A Tier-B (UNVERIFIED) decoded value. Gated behind OuraDriver.allowTierB. Per the brief's TIER
    /// DISCIPLINE: do not let Tier B feed values silently.
    case tierB(OuraTierBSummary)
    /// A decoded `0x50` activity_info record (state + MET series). Still Tier-B (see `OuraActivityInfo`
    /// doc) - split out of the raw-bytes `.tierB` wrapper because this ONE tag has a plausible decode
    /// formula, so an investigating consumer can log real MET numbers instead of hex. Same gate
    /// (`allowTierB`), same discipline (never reaches `OuraStreamMapping`).
    case activityInfo(OuraActivityInfo)

    /// True for Tier-B events, so a consumer can assert none leaked into a Tier-A-only sink.
    public var isTierB: Bool {
        switch self {
        case .tierB, .activityInfo: return true
        default: return false
        }
    }

    /// The record's envelope ring-time, when it carries one (battery is a plain response, not a log
    /// record). Feeds the history drain's in-session continuation cursor: open_oura's `drain_events`
    /// advances `start` past the max timestamp of EVERY event in a batch, whatever its tag.
    public var envelopeRingTimestamp: UInt32? {
        switch self {
        case .hr(let v): return v.ringTimestamp
        case .ibi(let v): return v.ringTimestamp
        case .hrv(let v): return v.ringTimestamp
        case .spo2(let v): return v.ringTimestamp
        case .temp(let v): return v.ringTimestamp
        case .battery: return nil
        case .sleepPhase(let v): return v.ringTimestamp
        case .motion(let v): return v.ringTimestamp
        case .motionEvent(let v): return v.ringTimestamp
        case .state(let v): return v.ringTimestamp
        case .timeSync(let v): return v.ringTimestamp
        case .rtcBeacon(let v): return v.ringTimestamp
        case .debugText(let rt, _): return rt
        case .tierB(let v): return v.ringTimestamp
        case .activityInfo(let v): return v.ringTimestamp
        }
    }
}
