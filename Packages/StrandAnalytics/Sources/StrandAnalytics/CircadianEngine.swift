import Foundation

// CircadianEngine.swift — on-device body-clock phase estimate + a jet-lag / shift-work LIGHT & SLEEP-TIMING
// plan. Pure, deterministic, DB-free.
//
// INDEPENDENT implementation of published methods:
//   • Single-component COSINOR (Halberg's cosine fit) over the rest-activity rhythm — the standard
//     actigraphy method for estimating circadian phase (the acrophase = peak-activity clock time) and
//     amplitude. We fit M + A·cos(2π(t − φ)/24) by ordinary least squares on cos/sin regressors and
//     recover amplitude + phase. The accelerometer rest-activity rhythm is the primary phase signal; the
//     nightly skin-temperature minimum corroborates it (wrist skin temperature runs broadly ANTI-phase to
//     core temperature, and the core-body-temperature minimum, CBTmin, is the canonical phase marker
//     sitting ~2–3 h before habitual wake).
//   • Phase-response-curve (PRC) DIRECTION rule for the advisory: to ADVANCE the clock (eastward travel /
//     an earlier shift) → bright light in the morning, dim evenings, earlier sleep, stepped ~1 h/day; to
//     DELAY (westward / a later shift) → bright light in the evening, the reverse.
//
// WELLNESS / BEHAVIOURAL AWARENESS ONLY — APPROXIMATE. Light + sleep TIMING only. The engine NEVER
// prescribes melatonin or any supplement/drug, and never guarantees an outcome ("consider"/"aim for",
// never "you must"). Irregular schedules get an honest "your rhythm is hard to read right now."
public enum CircadianEngine {

    // MARK: - Tuning constants (pinned by test; mirror the Kotlin twin exactly)

    /// Minimum days with a usable activity profile before a stable cosinor fit is reported.
    public static let minDaysForFit: Int = 7
    /// Days at/above which the fit reads as full-confidence.
    public static let goodDaysForFit: Int = 14
    /// A cosinor fit with amplitude below this fraction of the mesor is "arrhythmic" — too flat to phase.
    ///
    /// #982 — RELATIVE, applied to a signal (mean HR, see `ActivityBin`) whose mesor is ~45-75 bpm rather
    /// than the near-zero mesor a motion volume would have. So the effective bar is an absolute amplitude
    /// of `0.10 x mesor`: about 6.5 bpm at a 65 bpm mesor, about 4.5 bpm at 45. It scales WITH the mesor,
    /// so a low-resting wearer faces a LOWER absolute bar, not a higher one — the opposite of the concern
    /// raised in #982, which assumed the gate penalises the fittest.
    ///
    /// The VALUE is still not re-tuned — every candidate remains unvalidated. What changed is the SHAPE:
    /// `minAbsoluteAmplitudeBpm` now passes a swing large enough in bpm regardless of mesor. This note
    /// asked for "a wearer whose amplitude is disproportionately small for their mesor — an n=1
    /// observation" before that could happen, and one arrived: 5.5 bpm on a 74.7 bpm mesor with a coherent
    /// acrophase. "Nobody is currently silenced by it" was true when written and is no longer.
    /// `CircadianEngineTests` pins what the gate costs at each mesor so the trade stays visible.
    public static let minRelativeAmplitude: Double = 0.10
    /// Absolute amplitude (bpm) that reads as rhythmic whatever the mesor — the relative bar's escape hatch.
    ///
    /// The relative test scales the requirement WITH resting HR, so the identical swing is accepted on one
    /// body and refused on another: 5.5 bpm passes at a 55 bpm mesor and fails at 74.7. That is not a
    /// judgement about the rhythm, it is a judgement about the baseline, and a measured wearer sat exactly
    /// there — 5.5 bpm on a 74.7 bpm mesor, acrophase 16.1 h implying a CBTmin near 04:06, which is a
    /// textbook phase rather than noise. `minRelativeAmplitude`'s own note called for precisely that
    /// observation ("a wearer whose amplitude is disproportionately small for their mesor") before the
    /// shape could be revisited.
    ///
    /// 4.5 bpm is NOT a new tuning constant: it is the absolute amplitude the relative gate ALREADY
    /// accepts at the bottom of the ~45-75 bpm mesor range it was described against. The rule this
    /// encodes is internal consistency — an amplitude good enough for some wearer is good enough for all
    /// — so the change is strictly more permissive and no one who reads rhythmic today stops.
    public static let minAbsoluteAmplitudeBpm: Double = 4.5
    /// Max clock-shift the planner steps per day (hours) — the well-established ~1 h/day re-entrainment rate.
    public static let maxShiftPerDayHours: Double = 1.0
    /// CBTmin sits roughly this many hours before habitual wake; used to translate the activity acrophase
    /// into an estimated temperature-minimum clock time when the thermal series is thin.
    public static let cbtMinBeforeWakeHours: Double = 2.5
    /// Activity acrophase (peak activity) sits roughly this many hours after CBTmin in a typical day — the
    /// offset used to convert the cosinor acrophase into an estimated temperature-minimum time.
    public static let acrophaseAfterCbtMinHours: Double = 12.0
    /// Population-typical wake hour, used ONLY to place the chronotype reference point.
    ///
    /// `offsetVsScheduleMinutes` compares the clock to the USER'S OWN schedule, so it cannot name a
    /// chronotype: someone reliably asleep 03:00-11:00 has an offset near zero and would read
    /// "intermediate" while being strongly evening-type. A named lean needs an ABSOLUTE phase, so it is
    /// bucketed from `tempMinHour` against a population reference instead.
    public static let chronotypeReferenceWakeHour: Double = 7.0
    /// Half-width of the "intermediate" band around the reference CBTmin, in hours.
    ///
    /// Deliberately wide. `tempMinHour` is derived from an activity cosinor (`acrophase - 12 h`) unless a
    /// measured `observedTempMinHour` is supplied, and NO production caller supplies one today — so this
    /// is a lean inferred from movement, not a thermal measurement. A one-hour band either side keeps the
    /// three buckets coarse enough to be honest about that.
    public static let chronotypeBandHours: Double = 1.0

    // MARK: - Inputs

    /// One per-hour rest-activity sample: the local clock hour (0..<24, may be fractional) and the
    /// rhythm signal in that bin. Higher = more active.
    ///
    /// #982 — this said "motion volume (e.g. StepsEstimateEngine.dayMotionIntensity per hour)". It has
    /// never been fed that. The only production caller pools per-hour MEAN HEART RATE in bpm
    /// (`AppModel.swift`, `sums[hour] += b.bpm`), and that is the right choice on this hardware: WHOOP 4.0
    /// motion is too sparse to stage sleep at all (#345), while HR carries a strong circadian rhythm.
    ///
    /// The domain matters because `minRelativeAmplitude` gates on `amplitude / |mesor|`, and HR arrives
    /// with a large DC offset that motion does not have — see that constant for what the gate actually
    /// costs in bpm.
    public struct ActivityBin: Equatable, Sendable {
        public let hour: Double
        public let activity: Double
        public init(hour: Double, activity: Double) {
            self.hour = hour; self.activity = activity
        }
    }

    // MARK: - Cosinor

    /// A single-component cosinor fit: y ≈ mesor + amplitude·cos(2π(hour − acrophaseHours)/24).
    public struct CosinorFit: Equatable, Sendable {
        public let mesor: Double         // rhythm-adjusted mean
        public let amplitude: Double     // half the peak-to-trough swing (≥ 0)
        public let acrophaseHours: Double // clock hour of the activity PEAK, in [0, 24)
        public init(mesor: Double, amplitude: Double, acrophaseHours: Double) {
            self.mesor = mesor; self.amplitude = amplitude; self.acrophaseHours = acrophaseHours
        }
    }

    /// Fit a single 24 h cosine to the (hour, activity) bins by ordinary least squares.
    ///
    /// Model: y = M + β·cos(ωt) + γ·sin(ωt), ω = 2π/24.
    ///   amplitude  = √(β² + γ²)
    ///   acrophase  = atan2(γ, β) converted to a clock hour in [0, 24); this is the time of the PEAK.
    /// Returns nil with fewer than 3 distinct points or a degenerate design (zero variance).
    public static func cosinor(_ bins: [ActivityBin]) -> CosinorFit? {
        guard bins.count >= 3 else { return nil }
        let w = 2.0 * Double.pi / 24.0
        let n = Double(bins.count)

        var sumY = 0.0, sumC = 0.0, sumS = 0.0
        var sumCC = 0.0, sumSS = 0.0, sumCS = 0.0
        var sumYC = 0.0, sumYS = 0.0
        for b in bins {
            let c = cos(w * b.hour)
            let s = sin(w * b.hour)
            let y = b.activity
            sumY += y; sumC += c; sumS += s
            sumCC += c * c; sumSS += s * s; sumCS += c * s
            sumYC += y * c; sumYS += y * s
        }

        // Solve the 3×3 normal equations for (M, β, γ) via Cramer's rule.
        // [ n     sumC   sumS ] [M] = [sumY ]
        // [ sumC  sumCC  sumCS] [β] = [sumYC]
        // [ sumS  sumCS  sumSS] [γ] = [sumYS]
        let a11 = n,    a12 = sumC,  a13 = sumS
        let a21 = sumC, a22 = sumCC, a23 = sumCS
        let a31 = sumS, a32 = sumCS, a33 = sumSS
        let det = a11 * (a22 * a33 - a23 * a32)
                - a12 * (a21 * a33 - a23 * a31)
                + a13 * (a21 * a32 - a22 * a31)
        guard abs(det) > 1e-12 else { return nil }

        let detM = sumY * (a22 * a33 - a23 * a32)
                 - a12  * (sumYC * a33 - a23 * sumYS)
                 + a13  * (sumYC * a32 - a22 * sumYS)
        let detB = a11 * (sumYC * a33 - a23 * sumYS)
                 - sumY * (a21 * a33 - a23 * a31)
                 + a13  * (a21 * sumYS - sumYC * a31)
        let detG = a11 * (a22 * sumYS - sumYC * a32)
                 - a12 * (a21 * sumYS - sumYC * a31)
                 + sumY * (a21 * a32 - a22 * a31)

        let m = detM / det
        let beta = detB / det
        let gamma = detG / det

        let amplitude = (beta * beta + gamma * gamma).squareRoot()
        // Peak time: cos(ω(t − φ)) is maximal when ω(t − φ) = 0, i.e. φ where β·cos+γ·sin peaks.
        var phase = atan2(gamma, beta) / w           // hours
        phase = phase.truncatingRemainder(dividingBy: 24.0)
        if phase < 0 { phase += 24.0 }
        return CosinorFit(mesor: m, amplitude: amplitude, acrophaseHours: phase)
    }

    // MARK: - Phase estimate

    public enum PhaseConfidence: String, Equatable, Sendable, Codable {
        case unreadable     // too few days / arrhythmic — "hard to read right now"
        case wide           // a fit, but thin data → wide band
        case solid          // a stable fit over enough days
    }

    public struct PhaseEstimate: Equatable, Sendable {
        /// Estimated clock hour of the body-clock temperature minimum, in [0, 24).
        public let tempMinHour: Double
        /// Estimated activity acrophase (peak activity clock hour).
        public let acrophaseHours: Double
        /// Signed minutes the body clock leads (−) or lags (+) the user's own sleep schedule. Positive =
        /// the clock is LATER than the schedule implies (a "night-owl lean").
        public let offsetVsScheduleMinutes: Double
        public let confidence: PhaseConfidence
        public let note: String
        public init(tempMinHour: Double, acrophaseHours: Double, offsetVsScheduleMinutes: Double,
                    confidence: PhaseConfidence, note: String) {
            self.tempMinHour = tempMinHour; self.acrophaseHours = acrophaseHours
            self.offsetVsScheduleMinutes = offsetVsScheduleMinutes
            self.confidence = confidence; self.note = note
        }
    }

    /// Estimate the body-clock phase from a pooled activity profile and the user's habitual wake time.
    ///
    /// - Parameters:
    ///   - bins: pooled per-hour activity over the trailing window.
    ///   - daysObserved: distinct days backing the profile (drives confidence).
    ///   - habitualWakeHour: the user's typical wake clock hour (for the schedule-offset comparison).
    ///   - observedTempMinHour: optional measured nightly temp-minimum clock hour; when present it
    ///     corroborates / overrides the activity-derived estimate (the pillar's own signal).
    public static func estimatePhase(bins: [ActivityBin],
                                     daysObserved: Int,
                                     habitualWakeHour: Double,
                                     observedTempMinHour: Double? = nil) -> PhaseEstimate? {
        guard let fit = cosinor(bins) else { return nil }

        let relativeAmplitude = fit.mesor != 0 ? fit.amplitude / abs(fit.mesor) : 0
        // Rhythmic on EITHER measure: a proportional swing, or an absolute one large enough to read on
        // any baseline. See `minAbsoluteAmplitudeBpm` for why the relative test alone was self-inconsistent.
        let rhythmic = relativeAmplitude >= minRelativeAmplitude || fit.amplitude >= minAbsoluteAmplitudeBpm
        if daysObserved < minDaysForFit || !rhythmic {
            // A reading is returned, but flagged unreadable so the surface says "hard to read right now."
            let tmin = observedTempMinHour ?? wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
            return PhaseEstimate(tempMinHour: tmin, acrophaseHours: fit.acrophaseHours,
                                 offsetVsScheduleMinutes: 0, confidence: .unreadable,
                                 note: "Your rhythm is hard to read right now - keep wearing it for a clearer picture.")
        }

        // Activity-derived temp-minimum ≈ acrophase − ~12 h (activity peaks roughly half a day after CBTmin).
        let derivedTempMin = wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
        let tempMinHour = observedTempMinHour ?? derivedTempMin

        // A perfectly entrained clock has CBTmin ~cbtMinBeforeWakeHours before wake. The offset is how far
        // the ESTIMATED temp-minimum sits from that ideal, in minutes (signed; + = clock later than schedule).
        let idealTempMin = wrap24(habitualWakeHour - cbtMinBeforeWakeHours)
        let offsetHours = signedHourDelta(from: idealTempMin, to: tempMinHour)
        let offsetMinutes = offsetHours * 60.0

        // SOLID means strong on BOTH axes, not just enough days. A rhythm admitted by
        // `minAbsoluteAmplitudeBpm` alone is real but modest, and a smaller swing pins its acrophase less
        // tightly — so it stays `.wide`. That matters because `.wide` is what withholds `chronotype`,
        // which names a category off exactly that acrophase: widening the readable gate should give more
        // people a body clock, not give a thinner fit a firmer label.
        let confidence: PhaseConfidence =
            (daysObserved >= goodDaysForFit && relativeAmplitude >= minRelativeAmplitude) ? .solid : .wide
        let lean: String
        if offsetMinutes > 20 { lean = "later (a night-owl lean)" }
        else if offsetMinutes < -20 { lean = "earlier (a morning-lark lean)" }
        else { lean = "well-aligned with your schedule" }
        let note = "Your body clock looks \(lean)."

        return PhaseEstimate(tempMinHour: tempMinHour, acrophaseHours: fit.acrophaseHours,
                             offsetVsScheduleMinutes: offsetMinutes, confidence: confidence, note: note)
    }

    // MARK: - Jet-lag / shift planner

    public enum ShiftDirection: String, Equatable, Sendable, Codable {
        case advance   // move the clock EARLIER (eastward travel / earlier shift)
        case delay     // move the clock LATER (westward travel / later shift)
        case none      // no meaningful shift required
    }

    /// One day of the re-entrainment plan: when to seek bright light, when to keep it dim, and the target
    /// sleep window — light + timing only, never a supplement.
    public struct DayPlan: Equatable, Sendable {
        public let dayIndex: Int               // 1-based
        public let brightLightStartHour: Double
        public let brightLightEndHour: Double
        public let dimFromHour: Double
        public let targetSleepHour: Double
        public let targetWakeHour: Double
        public let guidance: String
        public init(dayIndex: Int, brightLightStartHour: Double, brightLightEndHour: Double,
                    dimFromHour: Double, targetSleepHour: Double, targetWakeHour: Double, guidance: String) {
            self.dayIndex = dayIndex
            self.brightLightStartHour = brightLightStartHour; self.brightLightEndHour = brightLightEndHour
            self.dimFromHour = dimFromHour
            self.targetSleepHour = targetSleepHour; self.targetWakeHour = targetWakeHour
            self.guidance = guidance
        }
    }

    public struct JetLagPlan: Equatable, Sendable {
        public let direction: ShiftDirection
        public let totalShiftHours: Double     // absolute size of the shift to absorb
        public let estimatedDays: Int          // days to close it at the stepped rate
        public let days: [DayPlan]
        public let note: String
        public init(direction: ShiftDirection, totalShiftHours: Double, estimatedDays: Int,
                    days: [DayPlan], note: String) {
            self.direction = direction; self.totalShiftHours = totalShiftHours
            self.estimatedDays = estimatedDays; self.days = days; self.note = note
        }
    }

    /// Build a stepped light + sleep-timing plan to absorb a required clock shift.
    ///
    /// - Parameters:
    ///   - shiftHours: the phase shift required (hours). POSITIVE = need to ADVANCE (go earlier; eastward).
    ///     NEGATIVE = need to DELAY (go later; westward). For a destination time-zone, this is the
    ///     eastward(+)/westward(−) offset; for a shift-work change, the difference in target wake time.
    ///   - currentSleepHour / currentWakeHour: the user's current sleep window (clock hours).
    public static func planShift(shiftHours: Double,
                                 currentSleepHour: Double,
                                 currentWakeHour: Double) -> JetLagPlan {
        let magnitude = abs(shiftHours)
        guard magnitude >= 0.5 else {
            return JetLagPlan(direction: .none, totalShiftHours: 0, estimatedDays: 0, days: [],
                              note: "No meaningful body-clock shift needed - you're about aligned.")
        }

        let advancing = shiftHours > 0
        let direction: ShiftDirection = advancing ? .advance : .delay
        let days = Int(ceil(magnitude / maxShiftPerDayHours))

        var plan: [DayPlan] = []
        var cumulative = 0.0
        for i in 1...days {
            let stepRemaining = magnitude - cumulative
            let step = min(maxShiftPerDayHours, stepRemaining)
            cumulative += step
            // Advancing → shift the window EARLIER each day (subtract); delaying → LATER (add).
            let signed = advancing ? -cumulative : cumulative
            let sleep = wrap24(currentSleepHour + signed)
            let wake = wrap24(currentWakeHour + signed)

            let brightStart: Double
            let brightEnd: Double
            let dimFrom: Double
            let guidance: String
            if advancing {
                // ADVANCE: bright light in the MORNING just after the new wake; dim the evening.
                brightStart = wake
                brightEnd = wrap24(wake + 2.0)
                dimFrom = wrap24(sleep - 2.0)
                guidance = "Get bright light early after waking and keep the evening dim - this nudges your "
                    + "clock earlier. Aim for lights-out around \(clock(sleep))."
            } else {
                // DELAY: bright light in the EVENING; avoid bright morning light; go to bed later.
                brightStart = wrap24(sleep - 3.0)
                brightEnd = wrap24(sleep - 1.0)
                dimFrom = wrap24(wake)
                guidance = "Get bright light in the evening and go easy on bright morning light - this nudges "
                    + "your clock later. Aim for lights-out around \(clock(sleep))."
            }
            plan.append(DayPlan(dayIndex: i, brightLightStartHour: brightStart, brightLightEndHour: brightEnd,
                                dimFromHour: dimFrom, targetSleepHour: sleep, targetWakeHour: wake,
                                guidance: guidance))
        }

        let dirWord = advancing ? "earlier" : "later"
        let note = "Shifting your clock \(String(format: "%.1f", magnitude)) h \(dirWord), about "
            + "\(maxShiftPerDayHours == 1.0 ? "an hour" : "\(maxShiftPerDayHours) h") a day. Light and sleep "
            + "timing only."
        return JetLagPlan(direction: direction, totalShiftHours: magnitude, estimatedDays: days,
                          days: plan, note: note)
    }

    // MARK: - Helpers

    /// Wrap an hour value into [0, 24).
    static func wrap24(_ h: Double) -> Double {
        var x = h.truncatingRemainder(dividingBy: 24.0)
        if x < 0 { x += 24.0 }
        return x
    }

    /// A coarse, ABSOLUTE body-clock category: where the temperature minimum sits on the clock.
    ///
    /// NOT the "chronotype lean" wording used elsewhere. `estimatePhase` builds a `lean` string from
    /// `offsetVsScheduleMinutes` ("a night-owl lean"), and the v5 skin-temp design spec defines chronotype
    /// lean as "earlier/later than your sleep schedule implies" — both RELATIVE to the wearer's own
    /// schedule. This is relative to the CLOCK, and the two genuinely disagree: a consistent 03:00-11:00
    /// sleeper is well-aligned by the relative read and `.evening` by this one. Keep the vocabularies
    /// disjoint in anything user-facing, or the two readings look like a contradiction (#1409).
    ///
    /// Three buckets, not a score: the underlying phase estimate is an activity fit, and a finer grain
    /// would imply precision it does not have.
    public enum Chronotype: String, Equatable, Sendable, Codable {
        case morning        // CBTmin earlier than the population reference
        case intermediate
        case evening        // CBTmin later than the population reference
    }

    /// The reference CBTmin clock hour a lean is measured against: the population wake hour minus the
    /// same `cbtMinBeforeWakeHours` the phase estimator already uses, so the anchor moves with the
    /// engine's own model rather than being a second, independently-drifting constant.
    public static var chronotypeAnchorHour: Double {
        wrap24(chronotypeReferenceWakeHour - cbtMinBeforeWakeHours)
    }

    /// The chronotype-ideal sleep window for a night of `durationHours`, as clock hours.
    ///
    /// Anchored on the temperature minimum: a well-entrained sleeper wakes about `cbtMinBeforeWakeHours`
    /// after CBTmin, so the ideal wake is `tempMinHour + cbtMinBeforeWakeHours` and the ideal bedtime is
    /// that minus the night's own length.
    ///
    /// USING THE ACTUAL DURATION IS THE POINT. Giving the ideal arc the same length as the real one makes
    /// the comparison purely about PHASE — did you sleep at the right TIME — so a short night reads as
    /// aligned-but-short rather than as misaligned. Feeding a "needed" duration instead would fold two
    /// different failures into one arc and make a debt look like a body-clock problem.
    ///
    /// nil for a non-positive or impossible duration; a window longer than a day cannot be placed on a
    /// 24 h ring, and silently wrapping it would draw a full circle that means nothing.
    public static func idealSleepWindow(tempMinHour: Double,
                                        durationHours: Double) -> (bedHour: Double, wakeHour: Double)? {
        guard durationHours > 0, durationHours < 24 else { return nil }
        let wake = wrap24(tempMinHour + cbtMinBeforeWakeHours)
        return (bedHour: wrap24(wake - durationHours), wakeHour: wake)
    }

    /// Signed hours the ACTUAL sleep window sits later (+) or earlier (−) than the chronotype-ideal one.
    ///
    /// Deliberately NOT `offsetVsScheduleMinutes`. That field compares the body clock to the wearer's own
    /// SCHEDULE; this compares the night actually slept to where the CLOCK wanted it. A dial that draws an
    /// actual arc against an ideal arc must caption itself with the distance between those two arcs, or
    /// the number contradicts the picture — the two disagree exactly when someone keeps a consistent
    /// schedule that does not suit their clock, which is the case the dial exists to show.
    ///
    /// Anchored on wake rather than bedtime because `idealSleepWindow` builds the ideal window from the
    /// wake end; comparing bedtimes would fold the night's DURATION into a phase reading.
    public static func sleepWindowOffsetHours(tempMinHour: Double, actualWakeHour: Double) -> Double {
        signedHourDelta(from: wrap24(tempMinHour + cbtMinBeforeWakeHours), to: wrap24(actualWakeHour))
    }

    /// Bucket an ABSOLUTE temperature-minimum clock hour into a lean.
    ///
    /// Compared CIRCULARLY. A `tempMinHour` of 23:30 is five hours BEFORE the 04:30 anchor — a strong
    /// morning lean — and a naive `23.5 > 5.5` would call it evening instead. Pure, so the boundaries are
    /// assertable without building a fit.
    public static func chronotype(tempMinHour: Double) -> Chronotype {
        let delta = signedHourDelta(from: chronotypeAnchorHour, to: wrap24(tempMinHour))
        if delta < -chronotypeBandHours { return .morning }
        if delta > chronotypeBandHours { return .evening }
        return .intermediate
    }

    /// The lean for a phase estimate, or nil when the fit is not strong enough to name one.
    ///
    /// Gated to `.solid` on purpose. `.wide` is a real fit on thin data and is fine for the continuous
    /// offset the card already shows, but a NAMED category reads as a fact about the person rather than a
    /// reading of the week, so it waits for the stronger tier. `.unreadable` never names one.
    public static func chronotype(_ estimate: PhaseEstimate) -> Chronotype? {
        guard estimate.confidence == .solid else { return nil }
        return chronotype(tempMinHour: estimate.tempMinHour)
    }

    /// Signed shortest delta in hours from `a` to `b` on the 24 h clock, in (−12, 12].
    static func signedHourDelta(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 24.0)
        if d > 12.0 { d -= 24.0 }
        if d <= -12.0 { d += 24.0 }
        return d
    }

    /// Format a clock hour as "HH:MM" (24 h). Pure, locale-free for cross-platform string parity.
    static func clock(_ hour: Double) -> String {
        let h = wrap24(hour)
        var hh = Int(h)
        var mm = Int(((h - Double(hh)) * 60.0).rounded())
        if mm == 60 { mm = 0; hh = (hh + 1) % 24 }
        return String(format: "%02d:%02d", hh, mm)
    }
}
