import Foundation

// MARK: - Decoded stream rows (the durable, compact local record)
// Phase E and WhoopStore depend on these EXACT shapes. ts is wall-clock unix seconds
// EXCEPT inside extractStreams' inputs; the structs themselves always carry wall-clock ts.

public struct HRSample: Equatable, Codable {
    public let ts: Int          // wall-clock unix seconds
    public let bpm: Int
    public init(ts: Int, bpm: Int) { self.ts = ts; self.bpm = bpm }
}

/// WHICH sensor channel produced an R-R interval (#1071).
///
/// A WHOOP strap has ONE beat source, so its rows carry no channel (nil) and nothing here changes for
/// them. An Oura ring has more than one: the green-quality tag (0x80) and the SpO2 tag (0x6E) both
/// decode to R-R and both were stored, so the table held roughly TWO complete copies of every night —
/// not duplicate rows to de-duplicate, but the SAME heartbeats measured twice. Labelling the channel is
/// what lets scoring read one copy while both stay on disk as each other's cross-check.
///
/// The raw values are the DURABLE, cross-platform storage codes for `rrInterval.srcChannel` and must
/// stay in lockstep with Kotlin `RrSourceChannel` — they are written to SQLite and cross the `.noopbak`
/// boundary, so they are a wire format, not an implementation detail. Never renumber a case; only append.
public enum RRSourceChannel: Int, Equatable, Codable, Sendable, CaseIterable {
    /// Oura 0x80 `green_ibi_quality_event` — the green-LED beat train, gated on the ring's own
    /// `quality == 1` flag and a 300-2000 ms physiological window, running the whole night.
    case greenQuality = 1
    /// Oura 0x6E `spo2_ibi_and_amplitude_event` — the SpO2/red-channel beat train, on an 8 ms
    /// quantisation grid with no quality gate, and present ONLY while SpO2 measurement is running.
    case spo2Ibi = 2
    /// Oura 0x60 `ibi_and_amplitude_event` — the bit-packed IBI+amplitude family.
    case ibiAmplitude = 3
    /// Oura 0x44 `ibi_event` — the SAME bit-packed layout family as 0x60, decoded by the same routine,
    /// but a DIFFERENT tag on the wire.
    ///
    /// Split out (#1071 follow-up) because both tags used to stamp `ibiAmplitude`, which made them
    /// indistinguishable once stored: a capture showing that channel over-covering its own wall-clock
    /// could not say whether one tag repeats beats or two tags report the same beats to each other. That
    /// is the question the channel choice for scoring rests on, and no stored night could answer it.
    /// Labelling only — both are read exactly as before.
    case ibiBare = 4
}

public struct RRInterval: Equatable, Codable {
    public let ts: Int          // wall-clock unix seconds
    public let rrMs: Int
    /// The sensor channel this beat came from, or nil when the source does not distinguish one (every
    /// WHOOP row, and every row written before the column existed). See `RRSourceChannel`.
    public let srcChannel: RRSourceChannel?
    /// #1008 diagnostics: this beat's EMISSION ORDER within the batch that delivered it, as stored in
    /// `rrInterval.ord`. nil on a decode (nothing has been stored yet) and on rows written before the
    /// column was surfaced to reads.
    ///
    /// It is the one field that separates the two remaining explanations for a second carrying seven
    /// beats: contiguous ords mean ONE record's array carried them all, so the over-count is in the
    /// record's contents; repeated or non-monotonic ords mean SEPARATE deliveries each contributed to
    /// that second, so the over-count is accumulation across offloads. WHOOP's wire format has no
    /// channel field, so `srcChannel` can never answer this for a strap — `ord` is what is left.
    public let ord: Int?
    public init(ts: Int, rrMs: Int, srcChannel: RRSourceChannel? = nil, ord: Int? = nil) {
        self.ts = ts; self.rrMs = rrMs; self.srcChannel = srcChannel; self.ord = ord
    }
}

public extension Array where Element == RRInterval {
    /// Ascending by `ts`, GUARANTEED stable — same-second beats keep the relative order they came in.
    ///
    /// Swift's `sorted(by:)` is explicitly documented as NOT stable. Since #823 the store returns a
    /// second's beats in EMISSION order, and RMSSD is built entirely from successive differences, so an
    /// unstable sort anywhere downstream could silently re-scramble them and reintroduce exactly the
    /// bias the store fix removes. Every analytics entry point re-sorts defensively ("the table read is
    /// already ordered, but we don't assume it"), which is where that would happen.
    ///
    /// Decorating with the original offset makes the comparator TOTAL, so no two elements compare equal
    /// and stability becomes a property of this code rather than of the current stdlib implementation.
    /// (Swift's sort is timsort today and stable in practice — but that is unguaranteed, and a metric
    /// that silently drifts if the stdlib changes is not one you can trust.)
    ///
    /// Kotlin needs no equivalent: `sortedBy` delegates to `java.util.Arrays.sort`, which is stable by
    /// contract. This makes the twins match on paper as well as in behaviour.
    func sortedByTsStable() -> [RRInterval] {
        enumerated()
            .sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }
            .map(\.element)
    }
}

public struct WhoopEvent: Equatable, Codable {
    public let ts: Int          // real unix seconds (event RTC; never offset)
    public let kind: String
    public let payload: [String: ParsedValue]
    public init(ts: Int, kind: String, payload: [String: ParsedValue]) {
        self.ts = ts; self.kind = kind; self.payload = payload
    }
}

public struct BatterySample: Equatable, Codable {
    public let ts: Int          // unix seconds — event RTC for BATTERY_LEVEL events, else wallClockRef
    public let soc: Double?
    public let mv: Int?
    public let charging: Bool?  // only the BATTERY_LEVEL event reports this; nil otherwise
    public init(ts: Int, soc: Double?, mv: Int?, charging: Bool? = nil) {
        self.ts = ts; self.soc = soc; self.mv = mv; self.charging = charging
    }
}

// MARK: - type-47 HISTORICAL_DATA biometric rows. JSON keys MUST match
// biometric_streams_golden.json exactly (see extract_historical_streams).

public struct SpO2Sample: Equatable, Codable {
    public let ts: Int
    public let red: Int
    public let ir: Int
    public let unit: String     // "raw_adc"
    public init(ts: Int, red: Int, ir: Int, unit: String = "raw_adc") {
        self.ts = ts; self.red = red; self.ir = ir; self.unit = unit
    }
}

/// A skin-temperature reading, plus the two AUXILIARY thermal channels that ride the same 5/MG v18
/// record (`temp_aux_1_raw@69`, `temp_aux_2_raw@71`).
///
/// `raw` is the primary channel (`skin_temp_raw@73`) and is unchanged. `aux1Raw` / `aux2Raw` are signed
/// i16 registers on their OWN scale — °C = value/10, not the primary's /100 — decoded since the v18
/// layout was mapped and dropped at this boundary until now. They track the primary closely (corr ~0.92
/// and ~0.97 over the captured corpus) with the same diurnal curve, so they are plausibly a second and
/// third thermistor rather than a copy; nothing here asserts what they measure, and no analytic reads
/// them. Both optional: nil on WHOOP 4.0, on any record whose byte failed the decoder's thermal gate,
/// and on every row banked before the channels were persisted. Mirrors Android `SkinTempRow`.
public struct SkinTempSample: Equatable, Codable {
    public let ts: Int
    public let raw: Int
    public let unit: String     // "raw_adc"
    /// `temp_aux_1_raw@69`, signed i16; °C = value/10. nil when absent/out of gate.
    public let aux1Raw: Int?
    /// `temp_aux_2_raw@71`, signed i16; °C = value/10. nil when absent/out of gate.
    public let aux2Raw: Int?
    public init(ts: Int, raw: Int, unit: String = "raw_adc",
                aux1Raw: Int? = nil, aux2Raw: Int? = nil) {
        self.ts = ts; self.raw = raw; self.unit = unit
        self.aux1Raw = aux1Raw; self.aux2Raw = aux2Raw
    }
}

/// Convert a raw `skin_temp_raw` register value to °C, DEVICE-FAMILY-AWARE (#938).
///
/// The two families bank skin temp on DIFFERENT scales, and applying one family's scale to the other
/// is a real decode bug: the historical `skin_temp_raw` field is a RAW ADC on the WHOOP 4.0 (v24
/// `@72`, "degC computed server-side" per the schema) but a CENTIDEGREE register on the 5/MG (v18
/// `@73`). A single family-blind `raw/100` sent every 4.0 night ~8 °C low, below the 28 °C worn gate,
/// so skin temp and the illness signal vanished (issue #938, reporter dpguglielmi's 4.0 capture).
///
/// - `.whoop5`: `raw / 100`. PROVEN on real 5/MG captures — `Whoop5HistoricalTests` reads worn 3057 =
///   30.6 °C and off-wrist 2247 = 22.5 °C, physically right on both ends. Unchanged.
///
/// - `.whoop4`: a single-anchor affine map. The 4.0 firmware (41.17.6.0) banks byte-72 at 1 Hz
///   ON-WRIST ONLY, so there is ONE solid anchor and NO clean off-wrist room anchor from the strap.
///   The reporter's doff/don capture gives a steady worn resting value of raw ~826 (worn steady
///   ~830–865; a no-contact floor ~510–520 at removal, then banking stops). Under `/100` that worn
///   value reads ~8.3 °C — impossible for a wrist streaming a resting HR (~52 bpm). We anchor the
///   worn value at a defensible nocturnal wrist skin temperature (33.0 °C ↔ the worn anchor raw) and
///   carry a PROVISIONAL slope until a second calibration point exists. Because the downstream use is a
///   deviation from the user's OWN nightly baseline (`skinTempDevC`), the offset is what must be right
///   to clear the absolute 28–42 °C worn gate + 20–42 °C baseline clamp; a slope error only rescales
///   the deviation and stays directionally correct. All 4.0 values APPROXIMATE.
///
///   PER-DEVICE ANCHOR (#938 second capture): `anchorRaw` is the raw that maps to 33.0 °C. It defaults to
///   the global `Whoop4SkinTemp.anchorRaw` (826, first reporter's strap) so every existing caller is
///   byte-identical, but the register OFFSET is per-device — a second real 4.0 strap shows the SAME floor
///   (~509) and saturation (2047) yet a worn band of ~1100–1600 (nightly mean raw ~1290), which the global
///   826 anchor maps to 47–72 °C (all samples fail the worn gate). The analytics caller therefore learns
///   `anchorRaw` from the device's OWN worn median (`Whoop4SkinTemp.deviceAnchorRaw`) so the worn band lands
///   in range; the constant offset cancels in the deviation-from-own-baseline the app consumes.
///
///   TODO(#938): replace the provisional slope with the exact two-point anchor once a second worn
///   point at a markedly different ambient (the reporter offered a colder + a warmer room) pins the
///   ADC→°C transfer — including whether it is linear at all. Until then this is a defensible
///   worn-range mapping, NOT a claimed-accurate absolute thermometer.
public func skinTempCelsius(raw: Int, family: DeviceFamily,
                            anchorRaw: Double = Whoop4SkinTemp.anchorRaw) -> Double {
    switch family {
    case .whoop5:
        return Double(raw) / 100.0
    case .whoop4:
        // Anchor: worn resting raw `anchorRaw` (per-device, default 826) → 33.0 °C. Provisional slope 0.05 °C
        // per raw unit (a ~35-unit worn-steady spread ≈ ~1.75 °C of nocturnal variation). See TODO above.
        return Whoop4SkinTemp.anchorCelsius
            + (Double(raw) - anchorRaw) * Whoop4SkinTemp.provisionalSlopeCPerRaw
    }
}

/// WHOOP 4.0 (v24) skin-temp mapping constants (#938). Named so the single provisional slope + anchor
/// live in ONE place and the two-point-calibration TODO has an obvious home. Kept in lockstep with the
/// Android `Whoop4SkinTemp`.
public enum Whoop4SkinTemp {
    /// Worn resting raw register value the GLOBAL anchor pins (first reporter's steady worn baseline, ~826).
    /// Used as the fallback anchor when a device has too few in-band samples to learn its own (#938).
    public static let anchorRaw: Double = 826.0
    /// Physiological nocturnal wrist skin temperature the anchor raw maps to (°C).
    public static let anchorCelsius: Double = 33.0
    /// PROVISIONAL °C-per-raw-unit slope. TODO(#938): replace with the two-point anchor slope.
    public static let provisionalSlopeCPerRaw: Double = 0.05

    // ── Per-device worn anchor (#938, second capture) ─────────────────────────────────────────────────
    // The @72 skin-temp field is a raw ADC whose register OFFSET is per-device: two real 4.0 straps show the
    // IDENTICAL no-contact floor (~509) and 11-bit saturation ceiling (2047), but DIFFERENT worn bands — the
    // first strap ~760–865 (anchored anchorRaw=826), a second ~1100–1600 (nightly mean raw ~1290). Under the
    // single global anchor the second strap maps to 47–72 °C, so 100% of its samples fail the 28–42 °C worn
    // gate: kept=0, no nightly mean, no baseline, no skin-temp/illness signal. The floor and ceiling agree
    // across devices; only the worn offset differs → the anchor must be learned per device from that device's
    // own worn band. Safe because downstream use is deviation-from-own-baseline (skinTempDevC) and the skin
    // baseline is re-folded from the same scan window's nightly means every run, so a constant per-run offset
    // cancels in the deviation.

    /// Lower raw bound of the plausible WORN band. Clear of the no-contact floor (~509–520 observed on two
    /// devices); banking stops at removal, so floor-and-below values are doff transients, never worn skin —
    /// excluding them keeps the learned anchor (a median of worn raws) from being dragged down. (#938)
    public static let wornMinRaw: Int = 550
    /// Upper raw bound of the plausible WORN band. Clear of the 11-bit register saturation (2047 observed
    /// pegged during device charging/fault) — a pegged raw is not a worn reading, so it must not enter the
    /// anchor median or the nightly mean. (#938)
    public static let wornMaxRaw: Int = 2040
    /// Minimum in-band samples before a per-device anchor is trusted. Below this, callers fall back to the
    /// global reporter anchor (`anchorRaw`=826) so sparse-data behavior is byte-identical to today — a
    /// handful of stray worn raws must not define a device's whole ADC offset. (#938)
    public static let minAnchorSamples: Int = 100

    /// Per-device worn anchor: median of the in-band raws across the caller's scan window, or nil when fewer
    /// than `minAnchorSamples` in-band samples exist (caller falls back to `anchorRaw`). Median (not mean) so
    /// doff/don transients and tails can't drag the anchor. (#938)
    public static func deviceAnchorRaw(_ raws: [Int]) -> Double? {
        let inBand = raws.filter { $0 >= wornMinRaw && $0 <= wornMaxRaw }.sorted()
        if inBand.count < minAnchorSamples { return nil }
        let n = inBand.count
        return n % 2 == 1 ? Double(inBand[n / 2])
            : Double(inBand[n / 2 - 1] + inBand[n / 2]) / 2.0
    }
}

public struct RespSample: Equatable, Codable {
    public let ts: Int
    public let raw: Int
    public let unit: String     // "raw_adc"
    public init(ts: Int, raw: Int, unit: String = "raw_adc") {
        self.ts = ts; self.raw = raw; self.unit = unit
    }
}

/// The 1 Hz gravity vector, plus the strap's OWN gravity-removed motion magnitude from the same record
/// (`dynamic_acceleration@41`, f32 g).
///
/// The two are different measurements of the same second and belong together. NOOP's motion spine
/// derives its stillness signal from `gravityDeltas` — the L2 distance between CONSECUTIVE 1 Hz gravity
/// vectors — which is a proxy: it only sees motion that survives the strap's own 1 Hz downsample, and it
/// measures orientation CHANGE, not acceleration. `dynAccel` is the strap's absolute gravity-removed
/// magnitude at one instant, computed on-device from the full-rate IMU. Persisting it BESIDE the proxy
/// (never instead of it) is what makes a later comparison on real nights possible at all; before this,
/// the field was computed and discarded one line after decode, and the strap trims its banked history
/// as soon as an offload is acked, so every second of it was lost permanently.
///
/// Optional: nil on WHOOP 4.0 (whose v24/v25 layouts have no such field), on any record whose f32 fell
/// outside the decoder's `[0, 8] g` gate, and on every row banked before this column existed. Nothing
/// scores it — see the #520 `DynAccelDiag` summary for the observability half. Mirrors Android `GravityRow`.
public struct GravitySample: Equatable, Codable {
    public let ts: Int
    public let x: Double
    public let y: Double
    public let z: Double
    public let unit: String     // "g"
    /// `dynamic_acceleration@41` in g — gravity-removed motion magnitude. nil when absent/out of gate.
    public let dynAccel: Double?
    public init(ts: Int, x: Double, y: Double, z: Double, unit: String = "g",
                dynAccel: Double? = nil) {
        self.ts = ts; self.x = x; self.y = y; self.z = z; self.unit = unit
        self.dynAccel = dynAccel
    }
}

/// WHOOP 5/MG cumulative u16 step / motion counter (step_motion_counter@57). APPROXIMATE — the @57
/// step semantics are unverified against the official WHOOP app (#78). Mirrors Android StepSample.
///
/// `activityClass` is the per-record activity-class enum decoded from @63 (community finding #316):
/// 0=still, 1=walk, 2=run; nil when the byte was 0xFF/invalid or absent. A lightweight, no-cloud
/// activity readout that rides alongside the counter. Optional + defaulted so existing call sites and
/// the persisted store (which carries only ts/counter today) are unchanged.
public struct StepSample: Equatable, Codable {
    public let ts: Int
    public let counter: Int
    public let activityClass: Int?
    public init(ts: Int, counter: Int, activityClass: Int? = nil) {
        self.ts = ts; self.counter = counter; self.activityClass = activityClass
    }
}

/// The strap's OWN per-record band sleep_state (task #175). The Interpreter reads the high nibble of the
/// v18 @81 flag byte (`(sb>>4)&3`) as 0 wake / 1 still / 2 asleep / 3 up. The BYTE and its offset are read
/// off real captured frames (Whoop5HistoricalTests) exactly like every other v18 field; ONLY the
/// meaning of the non-zero codes is community/structure inference (every real capture we hold reads 0, a
/// worn daytime wake). So this stream is carried VERBATIM (the strap's own byte, never fabricated) and is
/// surfaced/persisted as the strap's reported state, NOT trusted to override the derived hypnogram. It
/// feeds the existing, already-verified H7 morning-stillness re-onset CONFIRM guard (KEEP-biased, never
/// overrides) and a Deep Timeline display track. Mirrors Android `SleepStateRow`.
///
/// `rawByte` carries the WHOLE @81 byte alongside the interpreted `state`, so the bits `state` masks off
/// are not thrown away: b0-1 `onwrist` and b2-3 `wake_quality` are both decoded by the Interpreter and
/// were discarded at this boundary, and b6-7 have no interpretation at all (0 across every capture held
/// here). `state` stays exactly `(rawByte >> 4) & 3` and is untouched, so every existing consumer is
/// bit-identical; `rawByte` is nil on WHOOP 4.0, on any record without the byte, and on every row banked
/// before the column existed. Instrumentation only — nothing reads the extra bits yet.
public struct SleepStateSample: Equatable, Codable {
    public let ts: Int
    public let state: Int       // 0 wake / 1 still / 2 asleep / 3 up (band's own high-nibble code)
    /// The RAW @81 flag byte, all 8 bits, verbatim. nil when the record carried no @81 byte.
    public let rawByte: Int?
    public init(ts: Int, state: Int, rawByte: Int? = nil) {
        self.ts = ts; self.state = state; self.rawByte = rawByte
    }
}

/// The WHOOP 5.0 v26 optical PPG buffer's RAW waveform, one record per second (issue #156 follow-up).
/// `PpgHr.derivePpgHr` already turns these into a per-second HR estimate (`ppgHr`), but until now the
/// 24 Hz samples themselves were discarded the moment that estimate was taken — HistoricalStreams
/// collected them into a transient `ppgRecords` buffer purely to feed the estimator, and nothing else
/// ever saw them. Persisted here (and, in WhoopStore, its own table) so a future re-analysis — a better
/// HR estimator, HRV-from-PPG, a waveform viewer — can run over the ORIGINAL samples, not just the
/// derived bpm. `samples` are raw AC-coupled ADC counts, no invented scale (see
/// `decodeWhoop5HistoricalV26`); a truncated frame can yield fewer than 24.
public struct PpgWaveformSample: Equatable, Codable, Sendable {
    public let ts: Int          // wall-clock unix seconds (one record per second)
    public let samples: [Int]   // raw i16 ADC counts @24 Hz, verbatim from `ppg_waveform` (usually 24)
    public let burstIndex: Int?  // raw per-burst counter @21; nil for legacy archives
    public init(ts: Int, samples: [Int], burstIndex: Int? = nil) {
        self.ts = ts
        self.samples = samples
        self.burstIndex = burstIndex
    }
}

/// One wire slot in the 5/MG v18 auxiliary-field record. The `rawValue` is the slot's bit position in
/// the persisted presence bitmap, so it is a STORAGE CONTRACT: never reorder, renumber, or reuse a case.
/// Appending a new case at the end is the only safe evolution (an old reader ignores a bit it has no case
/// for; a new reader sees the bit absent on old rows).
///
/// Every slot is carried as an UNSIGNED integer of `width` bytes, little-endian, exactly as it sits on the
/// wire — including `unknownF32At113`, which is banked as its raw 32-bit pattern rather than a decoded
/// float. One uniform integer path is what makes the Swift and Kotlin codecs verifiably byte-identical,
/// and banking the bit pattern means a future reader can re-interpret those 4 bytes as something other
/// than a float if the census says so.
///
/// Every slot value is an unsigned integer up to 32 bits wide, so the DECODED domain has to be at least
/// 33 bits on both platforms or the two disagree on a u32 with bit 31 set (which `unknown_f32_113`
/// routinely has). Swift's `Int` is 64-bit on every supported target; the Kotlin twin therefore carries
/// `Long`, not `Int`. `V18AuxCodecParityTests` pins the same decimal literal on both sides.
///
/// Names are the DECODER's own names, verbatim (`decoderKey`) — no exceptions. Several slots are frankly
/// unpinned bytes: `cardiac_flags`/`cardiac_status` are outside-report names for bytes that sit near the
/// HR fields and do not decode consistently across firmwares, and `optical_amp_a`/`_b` are optical channel
/// amplitudes, not a named physiological quantity. Nothing here is renamed to imply a meaning it has not
/// earned — but nothing is renamed AWAY from the decoder either, because `decoderKey` is a string lookup
/// into the parsed dictionary and a slot whose key does not exist banks silence, not an error. See
/// `testEverySlotDecoderKeyExistsInARealV18Decode`, which is the tripwire for exactly that.
///
/// `@36`/`@37` and `@106`/`@107` are each TWO one-byte slots rather than one u16, because the decoder
/// reads them as two u8 channels: #861 showed `@36` is a flag byte with `@37` a duplicate HR beside it,
/// and that `@106`/`@107` cannot be a u16 at all (the high byte steps without a low-byte carry). Storage
/// mirrors the wire shape the decoder actually pins — the bytes on the wire are the same either way, but
/// the slot boundary is where a reader learns which channel is which.
public enum V18AuxSlot: Int, CaseIterable, Sendable {
    case recordIndex = 0        // @11  u32 — per-record counter, +1 per record, advances across gaps
    case rrCount                // @23  u8  — the strap's OWN R-R count (the stream itself caps at 4)
    case cardiacFlags           // @33  u8  — raw byte near the HR fields; meaning not pinned
    // @36/@37 were banked as ONE u16 (`hr_fixed_8_8`, "higher-precision HR, bpm = value/256"). #861
    // retired that: over 18,650 real v18 records bit 4 of @36 is NEVER set (a genuine 8.8 fraction sets it
    // ~50% of the time), 95.02% of values land in 0x80-0x8F, and the "corr 0.989 with heart_rate@22" was
    // circular — the u16 is literally the duplicate HR at @37 plus the @36 flag byte over 256. They are
    // two independent bytes, so they are two slots. Both are still carried RAW: bit 7 of @36 reads as a
    // validity bit and @37 tracks HR only while it is set, but storage asserts neither.
    case hrQualityFlags         // @36  u8  — flag byte (bit7 = HR/R-R valid); NOT a fixed-point HR
    case heartRateAlt           // @37  u8  — duplicate of heart_rate@22 (99.6% exact); raw, ungated
    case rrPacked               // @38  u16 — raw u16 near the R-R fields; meaning not pinned
    case cardiacStatus          // @40  u8  — raw status-like byte near the HR fields
    case stepCadence            // @59  u8  — cadence-like byte (never 0; lower when moving faster)
    case statusWord             // @75  u16 — packed status word; NOT a deep-sleep marker
    case statusWord1            // @77  u16 — near-static sibling of @75 (low nibble 1)
    case statusWord2            // @79  u16 — sibling of @75 (low nibble 2)
    case auxByte82              // @82  u8  — RAW byte; `spo2_candidate_82` is the gated 70-100 view of it
    // @106/@107 were banked as one u16 optical baseline. #861 showed a u16 is structurally impossible
    // there: across 18,599 consecutive-second pairs the HIGH byte moved while the LOW byte stayed frozen
    // in 3,514 of them, with ZERO low-byte wrap events in the corpus. Two correlated but independent u8
    // channels, so two slots — and `0`, not `128`, is the off-wrist reading on both.
    case opticalBaselineA       // @106 u8  — optical/ADC baseline channel; wanders overnight, 0 = off-wrist
    case opticalBaselineB       // @107 u8  — the other baseline channel (see @106)
    // @108/@109 are a pair and 128 is a RECORD-level marker, not a per-channel invalid sentinel: in the
    // #845 census `optical_amp_a == 128` and `optical_amp_b == 128` co-occur 757/757 and never
    // independently, so one channel reading 128 while the other does not has never been observed. Banked
    // raw either way — nothing here decides what the marker means.
    case opticalAmpA            // @108 u8  — paired amplitude/quality-like channel
    case opticalAmpB            // @109 u8  — the other half of the @108/@109 pair
    case unknownF32At113        // @113 f32 — carried as its raw u32 bit pattern; purpose unknown

    /// Wire width in bytes. Fixed per slot — part of the storage contract.
    public var width: Int {
        switch self {
        case .recordIndex, .unknownF32At113: return 4
        case .rrPacked, .statusWord, .statusWord1, .statusWord2:
            return 2
        case .rrCount, .cardiacFlags, .hrQualityFlags, .heartRateAlt, .cardiacStatus, .stepCadence,
             .auxByte82, .opticalBaselineA, .opticalBaselineB, .opticalAmpA, .opticalAmpB:
            return 1
        }
    }

    /// The Interpreter's own key for this slot, verbatim — this is the LOOKUP key `extractHistoricalStreams`
    /// reads the parsed dictionary with, so it MUST be exactly what the decoder emits today. A key the
    /// decoder no longer produces does not fail to compile (the lookup is `Int?`) and does not fail at
    /// runtime (absence is a first-class state in this format); it just banks nothing, forever, for a
    /// field the strap has already trimmed. `testEverySlotDecoderKeyExistsInARealV18Decode` is what turns
    /// that into a test failure.
    public var decoderKey: String {
        switch self {
        case .recordIndex: return "record_index"
        case .rrCount: return "rr_count"
        case .cardiacFlags: return "cardiac_flags"
        case .hrQualityFlags: return "hr_quality_flags"
        case .heartRateAlt: return "heart_rate_alt"
        case .rrPacked: return "rr_packed"
        case .cardiacStatus: return "cardiac_status"
        case .stepCadence: return "step_cadence"
        case .statusWord: return "status_word"
        case .statusWord1: return "status_word_1"
        case .statusWord2: return "status_word_2"
        case .auxByte82: return "aux_byte_82"
        case .opticalBaselineA: return "optical_baseline_a"
        case .opticalBaselineB: return "optical_baseline_b"
        case .opticalAmpA: return "optical_amp_a"
        case .opticalAmpB: return "optical_amp_b"
        case .unknownF32At113: return "unknown_f32_113"
        }
    }
}

/// Every remaining 5/MG v18 per-second field the decoder produces and the storage funnel used to DROP.
///
/// `extractHistoricalStreams` names a dozen fields and silently discards the rest; the strap trims its
/// banked history as soon as NOOP acks the offload, so a field not banked here is gone permanently and
/// can never be censused, correlated, or validated. These fifteen bytes-worth of slots are what was left
/// on the floor. They are carried VERBATIM under the decoder's own names — no scaling, no renaming, no
/// physiological claim — precisely so a later census decides what they are rather than this commit
/// pre-judging it.
///
/// Fields that already have a durable home are deliberately NOT duplicated here: `heart_rate`,
/// `rr_intervals`, `gravity_*`, `skin_temp_raw`, `step_motion_counter`, `activity_class`, `sleep_state`,
/// and `unix` all have their own columns. `motion_wear_quality@63` is the same byte as `activity_class`
/// under a second name and the same 0-2 gate, so banking it again would store one byte twice.
/// `spo2_candidate_82` is a gated 70-100 view of `auxByte82` and is recoverable from the raw byte.
///
/// INSTRUMENTATION ONLY: nothing reads this stream. Every slot is optional, so an absent field stays
/// absent and never becomes a fabricated 0.
public struct V18AuxSample: Equatable, Codable, Sendable {
    public let ts: Int
    public let recordIndex: Int?
    public let rrCount: Int?
    public let cardiacFlags: Int?
    /// The `@36` flag byte, raw. Bit 7 reads as an HR/R-R validity bit and bit 4 is never set (#861);
    /// storage carries all 8 bits and interprets none of them.
    public let hrQualityFlags: Int?
    /// The `@37` duplicate heart rate, raw and UNGATED — it equals `heart_rate@22` in 99.6% of records
    /// but only tracks HR while `hrQualityFlags` bit 7 is set, so it is banked as the byte it is rather
    /// than as a bpm. Reading it as one is a consumer's decision, made against the flag byte beside it.
    public let heartRateAlt: Int?
    public let rrPacked: Int?
    public let cardiacStatus: Int?
    public let stepCadence: Int?
    public let statusWord: Int?
    public let statusWord1: Int?
    public let statusWord2: Int?
    public let auxByte82: Int?
    /// The two `@106`/`@107` optical/ADC baseline channels, raw. Independent bytes, NOT a u16 — see
    /// `V18AuxSlot.opticalBaselineA`. `0` on both is the off-wrist reading; `128` is unremarkable here.
    public let opticalBaselineA: Int?
    public let opticalBaselineB: Int?
    public let opticalAmpA: Int?
    public let opticalAmpB: Int?
    /// The raw 32-bit pattern of `unknown_f32_113`, NOT a decoded float. See `unknownF32At113`.
    public let unknownF32Bits: Int?

    public init(ts: Int, recordIndex: Int? = nil, rrCount: Int? = nil, cardiacFlags: Int? = nil,
                hrQualityFlags: Int? = nil, heartRateAlt: Int? = nil, rrPacked: Int? = nil,
                cardiacStatus: Int? = nil, stepCadence: Int? = nil, statusWord: Int? = nil,
                statusWord1: Int? = nil, statusWord2: Int? = nil, auxByte82: Int? = nil,
                opticalBaselineA: Int? = nil, opticalBaselineB: Int? = nil,
                opticalAmpA: Int? = nil, opticalAmpB: Int? = nil, unknownF32Bits: Int? = nil) {
        self.ts = ts; self.recordIndex = recordIndex; self.rrCount = rrCount
        self.cardiacFlags = cardiacFlags; self.hrQualityFlags = hrQualityFlags
        self.heartRateAlt = heartRateAlt; self.rrPacked = rrPacked
        self.cardiacStatus = cardiacStatus; self.stepCadence = stepCadence
        self.statusWord = statusWord; self.statusWord1 = statusWord1; self.statusWord2 = statusWord2
        self.auxByte82 = auxByte82; self.opticalBaselineA = opticalBaselineA
        self.opticalBaselineB = opticalBaselineB
        self.opticalAmpA = opticalAmpA; self.opticalAmpB = opticalAmpB
        self.unknownF32Bits = unknownF32Bits
    }

    /// Rebuild from the codec's slot array. `values` is indexed by `V18AuxSlot.rawValue`; a short array
    /// (a blob written by an older build) leaves the missing tail nil rather than throwing.
    public init(ts: Int, slotValues values: [Int?]) {
        func v(_ s: V18AuxSlot) -> Int? { s.rawValue < values.count ? values[s.rawValue] : nil }
        self.init(ts: ts, recordIndex: v(.recordIndex), rrCount: v(.rrCount),
                  cardiacFlags: v(.cardiacFlags), hrQualityFlags: v(.hrQualityFlags),
                  heartRateAlt: v(.heartRateAlt), rrPacked: v(.rrPacked),
                  cardiacStatus: v(.cardiacStatus), stepCadence: v(.stepCadence),
                  statusWord: v(.statusWord), statusWord1: v(.statusWord1),
                  statusWord2: v(.statusWord2), auxByte82: v(.auxByte82),
                  opticalBaselineA: v(.opticalBaselineA), opticalBaselineB: v(.opticalBaselineB),
                  opticalAmpA: v(.opticalAmpA), opticalAmpB: v(.opticalAmpB),
                  unknownF32Bits: v(.unknownF32At113))
    }

    /// The slot values in wire order — index == `V18AuxSlot.rawValue`. The storage codec's only view of
    /// this struct, so the field order lives in exactly one place on each platform.
    public var slotValues: [Int?] {
        [recordIndex, rrCount, cardiacFlags, hrQualityFlags, heartRateAlt, rrPacked, cardiacStatus,
         stepCadence, statusWord, statusWord1, statusWord2, auxByte82, opticalBaselineA,
         opticalBaselineB, opticalAmpA, opticalAmpB, unknownF32Bits]
    }

    /// `unknown_f32_113` re-read as the float the decoder saw. The BITS are what is stored; this is a
    /// convenience view, and it is the only place the four bytes are interpreted as a number at all.
    public var unknownF32At113: Double? {
        unknownF32Bits.map { Double(Float(bitPattern: UInt32(truncatingIfNeeded: $0))) }
    }

    /// True when the record carried none of the slots — such a sample is never banked (no empty rows).
    public var isEmpty: Bool { slotValues.allSatisfy { $0 == nil } }
}

public struct Streams: Equatable, Codable {
    public var hr: [HRSample]
    public var rr: [RRInterval]
    public var spo2: [SpO2Sample]
    public var skinTemp: [SkinTempSample]
    public var resp: [RespSample]
    public var gravity: [GravitySample]
    public var steps: [StepSample]
    /// The strap's own per-record band sleep_state (#175), carried verbatim off @81's high nibble. Optional
    /// signal (only 5/MG v18 records emit it today; a WHOOP 4.0 leaves it empty), consumed by the H7
    /// re-onset CONFIRM guard and shown as a Deep Timeline track. Never overrides the derived stage.
    public var sleepState: [SleepStateSample]
    /// PPG-derived per-second HR from the WHOOP 5.0 v26 optical buffer (issue #156). Kept separate from
    /// `hr` (the measured stream) so consumers can COALESCE without conflating the two sources.
    public var ppgHr: [PpgHrSample]
    /// The RAW v26 optical PPG waveform itself (issue #156 follow-up), one record per second — the
    /// samples `ppgHr` is derived FROM. Kept separate so a consumer that only wants the HR estimate
    /// never pays for the 24x-larger raw stream, and so the two can be persisted/pruned independently.
    public var ppgWaveform: [PpgWaveformSample]
    /// Every remaining 5/MG v18 per-second field the decoder produces and this funnel used to discard —
    /// carried verbatim for a later census. Empty on WHOOP 4.0 and on the live path. Nothing reads it.
    public var v18Aux: [V18AuxSample]
    public var events: [WhoopEvent]
    public var battery: [BatterySample]
    /// #547 diagnostic: how many historical records `extractHistoricalStreams` DROPPED this chunk for an
    /// implausible own-timestamp (a bad-clock strap: far-past / bogus-2027 / future-dated). NOT persisted
    /// and NOT round-tripped through Codable (excluded from `CodingKeys`) — it is a transient observability
    /// count the Backfiller surfaces to the strap log. Defaults to 0 so it never affects golden fixtures.
    public var droppedImplausible: Int = 0
    /// #324 diagnostic: the OLDEST / NEWEST own-timestamp (unix seconds, the strap's OWN dated value) among
    /// records DROPPED this chunk for an implausible ts. Lets the Backfiller log the epoch SPAN of a bad-clock
    /// strap's poisoned range - so a future-dated strap shows "2028-06-24 -> 2029-07" and we can tell a
    /// WHOLE-range-future strap (safe to fast-forward-discard) from one mixed with real data. Transient (not
    /// in CodingKeys), nil when nothing dropped. Defaults keep golden fixtures byte-identical.
    public var droppedImplausibleOldestTs: Int? = nil
    public var droppedImplausibleNewestTs: Int? = nil
    /// #324 diagnostic: strap RTC-STATE events (RTC_LOST / BOOT / SET_RTC) DROPPED for an implausible own-ts.
    /// The #547 gate discards them like any bad-ts record, but these are the GROUND TRUTH that the clock reset
    /// - so we capture (kind, rawTs) for the strap log before dropping. Transient, empty by default, not encoded.
    public var droppedRtcEvents: [DroppedRtcEvent] = []
    /// #891 diagnostic: packet types this funnel DROPPED this chunk because it has no `case` for them —
    /// keyed by the rendered type name (`schema.typeName`, so a byte the schema does not name renders
    /// `type53`), value = how many records carried it.
    ///
    /// An offload records nothing about a type it does not handle. `extractHistoricalStreams` switches on
    /// four of the schema's sixteen packet types and `default: continue`s the rest, and
    /// `rejectedHistoricalRecords` only archives type-47 — non-47 frames are, in its own words, "excluded
    /// by construction". So a record type nobody has mapped is dropped twice and counted zero times, and
    /// the sync reports clean. That is not hypothetical: `HISTORICAL_IMU_DATA_STREAM(52)` is a banked
    /// raw-stream type our own schema names, and every one of them would vanish here.
    ///
    /// The immediate use is #891 — whether a 5/MG banks ECG to flash after the Labrador toggles is the
    /// leading hypothesis, and it currently cannot be answered by running the experiment, because nothing
    /// would show the result. The general use is that any future firmware record type is invisible today.
    ///
    /// `METADATA` and `CONSOLE_LOGS` are deliberately NOT counted: an offload legitimately carries both,
    /// they decode to zero rows by design, and tallying them every sync would bury the signal this exists
    /// to surface. Everything else falls through, including named-but-unhandled types — those are the
    /// interesting ones.
    ///
    /// Transient observability only, like `droppedImplausible`: not persisted, not in `CodingKeys`, empty
    /// by default so golden fixtures stay byte-identical.
    public var unhandledPacketTypes: [String: Int] = [:]
    /// #520 diagnostic: a summary of `dynamic_acceleration@41` (the strap's own gravity-removed motion
    /// magnitude) over this chunk's v18 records. The field is decoded but has never been persisted or
    /// scored, so there is no evidence about whether it is a usable stillness signal; this counts what
    /// arrived so the strap log can answer that from real nights before anyone pays for a migration.
    /// Transient like the counters above — not in `CodingKeys`, defaults keep golden fixtures identical.
    public var dynAccel = DynAccelDiag()

    /// #520 diagnostic: distribution of `dynamic_acceleration` over one decoded chunk. Deliberately a
    /// summary, not a stream — at 1 Hz a night is ~30k values and the open question needs a shape, not
    /// samples. `still` counts values under `SleepStager.gravityStillThresholdG` (0.01 g) — borrowed as a
    /// REFERENCE CUT, not because the two quantities are the same thing. The stager thresholds a per-sample
    /// DELTA (how much the gravity vector moved between consecutive samples); this field is an ABSOLUTE
    /// gravity-removed magnitude at one instant. Both go to ~0 when the wrist is still, so the same cut is a
    /// sensible starting point, but the two still-fractions are not measuring the same thing and should not
    /// be read as if a match proved equivalence. `min`/`max`/`mean` are here so a reader can re-derive any
    /// other cut from the logs — picking the right one is what this diagnostic exists to inform.
    public struct DynAccelDiag: Equatable, Codable, Sendable {
        public var count = 0
        public var still = 0
        public var min: Double?
        public var max: Double?
        /// Mean over `count` values, or nil when nothing arrived. Kept as a running sum so a chunk of any
        /// size costs O(1) memory.
        public var sum = 0.0
        public var mean: Double? { count > 0 ? sum / Double(count) : nil }
        /// Fraction of values below the stillness threshold, or nil when nothing arrived.
        public var stillFraction: Double? { count > 0 ? Double(still) / Double(count) : nil }

        public init() {}

        /// Fold another chunk's summary into this one. A chunk is an arbitrary slice of an offload, so the
        /// still-fraction only means anything once a whole session is merged — the Backfiller accumulates
        /// with this and logs once at the session boundary. Merging an empty diag is a no-op.
        public mutating func merge(_ other: DynAccelDiag) {
            guard other.count > 0 else { return }
            count += other.count
            still += other.still
            sum += other.sum
            if let lo = other.min { min = min.map { Swift.min($0, lo) } ?? lo }
            if let hi = other.max { max = max.map { Swift.max($0, hi) } ?? hi }
        }

        /// Milli-g, rounded half-away-from-zero. Integers are the ONLY safe way to render this across the
        /// two platforms: C's `%.3f` (what Swift's `String(format:)` uses) rounds half-to-EVEN while Java's
        /// `String.format` rounds HALF_UP, so a tie diverges — 0.0625 g prints `0.062` on Swift and `0.063`
        /// on Kotlin, and 0.0625 is exactly representable in the f32 the strap sends. Swift's `.rounded()`
        /// and Kotlin's `round()` agree for non-negative input, and the decoder gates this field to
        /// `[0, 8] g`, so the two sides round identically here.
        static func mg(_ g: Double) -> Int { Int((g * 1000).rounded()) }

        /// Whole percent, same rounding rule and the same reason (`%.0f` of 66.5 is 66 on Swift, 67 on Kotlin).
        static func pct(_ fraction: Double) -> Int { Int((fraction * 100).rounded()) }

        /// The strap-log line for a whole offload session, or nil when nothing arrived (so a WHOOP 4.0 or a
        /// caught-up session stays quiet). Every field is an Int rendered by interpolation — no `String(format:)`,
        /// so neither locale nor printf rounding mode can make the two platforms disagree.
        public func logLine(threshold: Double) -> String? {
            guard count > 0, let lo = min, let hi = max, let avg = mean, let frac = stillFraction else {
                return nil
            }
            return "Backfill: dynaccel n=\(count) still=\(Self.pct(frac))% mean=\(Self.mg(avg))mg "
                + "range=\(Self.mg(lo))..\(Self.mg(hi))mg (thr \(Self.mg(threshold))mg) "
                + "— diagnostic only, not stored or scored (#520)"
        }

        /// Fold one decoded value in. `threshold` is passed rather than imported so WhoopProtocol keeps no
        /// dependency on StrandAnalytics; the caller supplies the stager's own constant.
        public mutating func add(_ g: Double, threshold: Double) {
            guard g.isFinite else { return }
            count += 1
            sum += g
            if g < threshold { still += 1 }
            if let m = min { self.min = Swift.min(m, g) } else { min = g }
            if let m = max { self.max = Swift.max(m, g) } else { max = g }
        }
    }
    public init(hr: [HRSample] = [], rr: [RRInterval] = [],
                spo2: [SpO2Sample] = [], skinTemp: [SkinTempSample] = [],
                resp: [RespSample] = [], gravity: [GravitySample] = [],
                steps: [StepSample] = [], sleepState: [SleepStateSample] = [],
                ppgHr: [PpgHrSample] = [], ppgWaveform: [PpgWaveformSample] = [],
                v18Aux: [V18AuxSample] = [],
                events: [WhoopEvent] = [], battery: [BatterySample] = []) {
        self.hr = hr; self.rr = rr
        self.spo2 = spo2; self.skinTemp = skinTemp; self.resp = resp; self.gravity = gravity
        self.steps = steps; self.sleepState = sleepState; self.ppgHr = ppgHr
        self.ppgWaveform = ppgWaveform
        self.v18Aux = v18Aux
        self.events = events; self.battery = battery
    }

    /// True when no decoded rows landed in any stream — used to flag a historical chunk whose frames
    /// all dropped (CRC fail / unmapped layout / out-of-range timestamp), the silent-data-loss
    /// diagnostic in `Backfiller.finishChunk` (#77).
    public var isEmpty: Bool {
        hr.isEmpty && rr.isEmpty && spo2.isEmpty && skinTemp.isEmpty && resp.isEmpty
            && gravity.isEmpty && steps.isEmpty && sleepState.isEmpty && ppgHr.isEmpty
            && ppgWaveform.isEmpty && v18Aux.isEmpty && events.isEmpty && battery.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case hr, rr, spo2, skinTemp = "skin_temp", resp, gravity, steps
        case sleepState = "sleep_state"
        case ppgHr = "ppg_hr"
        case ppgWaveform = "ppg_waveform"
        case v18Aux = "v18_aux"
        case events, battery
    }

    // Custom decode so older fixtures (streams_golden.json / historical_golden.json) that
    // lack the new biometric keys still decode — missing arrays default to empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hr = try c.decodeIfPresent([HRSample].self, forKey: .hr) ?? []
        rr = try c.decodeIfPresent([RRInterval].self, forKey: .rr) ?? []
        spo2 = try c.decodeIfPresent([SpO2Sample].self, forKey: .spo2) ?? []
        skinTemp = try c.decodeIfPresent([SkinTempSample].self, forKey: .skinTemp) ?? []
        resp = try c.decodeIfPresent([RespSample].self, forKey: .resp) ?? []
        gravity = try c.decodeIfPresent([GravitySample].self, forKey: .gravity) ?? []
        steps = try c.decodeIfPresent([StepSample].self, forKey: .steps) ?? []
        sleepState = try c.decodeIfPresent([SleepStateSample].self, forKey: .sleepState) ?? []
        ppgHr = try c.decodeIfPresent([PpgHrSample].self, forKey: .ppgHr) ?? []
        ppgWaveform = try c.decodeIfPresent([PpgWaveformSample].self, forKey: .ppgWaveform) ?? []
        v18Aux = try c.decodeIfPresent([V18AuxSample].self, forKey: .v18Aux) ?? []
        events = try c.decodeIfPresent([WhoopEvent].self, forKey: .events) ?? []
        battery = try c.decodeIfPresent([BatterySample].self, forKey: .battery) ?? []
    }
}

extension Streams { public static let empty = Streams() }

/// #324 diagnostic record: a strap RTC-STATE event (RTC_LOST / BOOT / SET_RTC) that the #547 plausibility
/// gate dropped for an implausible own-timestamp. `rawTs` is the event's OWN dated value (unix seconds) - on
/// a future-dated strap this is the bad epoch the RTC jumped to, the single most useful signal for #324.
public struct DroppedRtcEvent: Equatable, Codable, Sendable {
    public let kind: String
    public let rawTs: Int
    public init(kind: String, rawTs: Int) { self.kind = kind; self.rawTs = rawTs }

    /// The RTC-state event kinds worth capturing when dropped. Kinds are formatted "NAME(n)" (e.g.
    /// "RTC_LOST(13)"), matched by prefix - "BOOT" covers both BOOT and BOOT_REPORT.
    public static func isRtcStateKind(_ kind: String) -> Bool {
        kind.hasPrefix("RTC_LOST") || kind.hasPrefix("SET_RTC") || kind.hasPrefix("BOOT")
    }
}

/// Map a device-epoch timestamp to wall-clock unix seconds via a pure linear offset.
/// Assumes strap clock and wall clock tick at the same rate (no skew/drift). Port of _to_wall.
private func toWall(_ deviceTs: Int?, _ deviceClockRef: Int, _ wallClockRef: Int) -> Int? {
    guard let deviceTs = deviceTs else { return nil }
    return wallClockRef + (deviceTs - deviceClockRef)
}

/// Turn parsed frames into datastore rows. Port of interpreter.extract_streams.
///
/// HR/R-R are taken ONLY from REALTIME_DATA (type 40). REALTIME_RAW_DATA (type 43) also
/// carries an HR byte but streams alongside type-40 during raw collection, so routing both
/// would double-count HR for the same instants. CRC-failed and non-ok frames are skipped.
public func extractStreams(_ parsed: [ParsedFrame],
                           deviceClockRef: Int, wallClockRef: Int) -> Streams {
    var out = Streams()
    for r in parsed {
        if !r.ok || r.crcOK == false { continue }
        let p = r.parsed
        switch r.typeName {
        case "REALTIME_DATA":
            let ts = toWall(p["timestamp"]?.intValue, deviceClockRef, wallClockRef)
            if let ts = ts, let bpm = p["heart_rate"]?.intValue {
                out.hr.append(HRSample(ts: ts, bpm: bpm))
            }
            // Unlike Python, drop RR rows when timestamp is absent (a ts-less RR row is unstorable).
            if let ts = ts, let rrs = p["rr_intervals"]?.intArrayValue {
                for rr in rrs { out.rr.append(RRInterval(ts: ts, rrMs: rr)) }
            }
        case "EVENT":
            // EVENT timestamps are real RTC unix seconds — already wall-clock, NOT offset.
            guard let ts = p["event_timestamp"]?.intValue else { continue }
            let kind = p["event"]?.stringValue ?? ""
            // BATTERY_LEVEL events (every ~8 min) carry SoC/mV/charging + a real RTC ts →
            // the DENSE battery series (the post-hook decoded the fields).
            if kind.hasPrefix("BATTERY_LEVEL") { appendBattery(&out, ts: ts, p: p) }  // "BATTERY_LEVEL(3)"
            var payload = p
            payload.removeValue(forKey: "event")
            payload.removeValue(forKey: "event_timestamp")
            out.events.append(WhoopEvent(ts: ts, kind: kind, payload: payload))
        case "COMMAND_RESPONSE":
            // No device timestamp on COMMAND_RESPONSE → stamp battery at wallClockRef.
            appendBattery(&out, ts: wallClockRef, p: p)
        default:
            continue
        }
    }
    return out
}

/// Append a BatterySample from a parsed frame's battery_pct/battery_mV/battery_charging
/// fields (no-op when neither soc nor mv is present). charging is a real Bool only when the
/// frame reported it (BATTERY_LEVEL events); command responses leave it nil.
func appendBattery(_ out: inout Streams, ts: Int, p: [String: ParsedValue]) {
    let soc = p["battery_pct"]?.doubleValue
    let mv = p["battery_mV"]?.intValue
    guard soc != nil || mv != nil else { return }
    let charging = p["battery_charging"]?.intValue.map { $0 != 0 }
    out.battery.append(BatterySample(ts: ts, soc: soc, mv: mv, charging: charging))
}
