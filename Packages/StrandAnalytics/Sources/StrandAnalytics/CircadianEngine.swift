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
    public static let minRelativeAmplitude: Double = 0.10
    /// Max clock-shift the planner steps per day (hours) — the well-established ~1 h/day re-entrainment rate.
    public static let maxShiftPerDayHours: Double = 1.0
    /// CBTmin sits roughly this many hours before habitual wake; used to translate the activity acrophase
    /// into an estimated temperature-minimum clock time when the thermal series is thin.
    public static let cbtMinBeforeWakeHours: Double = 2.5
    /// Activity acrophase (peak activity) sits roughly this many hours after CBTmin in a typical day — the
    /// offset used to convert the cosinor acrophase into an estimated temperature-minimum time.
    public static let acrophaseAfterCbtMinHours: Double = 12.0

    // MARK: - Inputs

    /// One per-hour rest-activity sample: the local clock hour (0..<24, may be fractional) and the motion
    /// volume in that bin (e.g. StepsEstimateEngine.dayMotionIntensity per hour). Higher = more active.
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
        if daysObserved < minDaysForFit || relativeAmplitude < minRelativeAmplitude {
            // A reading is returned, but flagged unreadable so the surface says "hard to read right now."
            let tmin = observedTempMinHour ?? wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
            return PhaseEstimate(tempMinHour: tmin, acrophaseHours: fit.acrophaseHours,
                                 offsetVsScheduleMinutes: 0, confidence: .unreadable,
                                 note: "Your rhythm is hard to read right now — keep wearing it for a clearer picture.")
        }

        // Activity-derived temp-minimum ≈ acrophase − ~12 h (activity peaks roughly half a day after CBTmin).
        let derivedTempMin = wrap24(fit.acrophaseHours - acrophaseAfterCbtMinHours)
        let tempMinHour = observedTempMinHour ?? derivedTempMin

        // A perfectly entrained clock has CBTmin ~cbtMinBeforeWakeHours before wake. The offset is how far
        // the ESTIMATED temp-minimum sits from that ideal, in minutes (signed; + = clock later than schedule).
        let idealTempMin = wrap24(habitualWakeHour - cbtMinBeforeWakeHours)
        let offsetHours = signedHourDelta(from: idealTempMin, to: tempMinHour)
        let offsetMinutes = offsetHours * 60.0

        let confidence: PhaseConfidence = daysObserved >= goodDaysForFit ? .solid : .wide
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
                              note: "No meaningful body-clock shift needed — you're about aligned.")
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
                guidance = "Get bright light early after waking and keep the evening dim — this nudges your "
                    + "clock earlier. Aim for lights-out around \(clock(sleep))."
            } else {
                // DELAY: bright light in the EVENING; avoid bright morning light; go to bed later.
                brightStart = wrap24(sleep - 3.0)
                brightEnd = wrap24(sleep - 1.0)
                dimFrom = wrap24(wake)
                guidance = "Get bright light in the evening and go easy on bright morning light — this nudges "
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
