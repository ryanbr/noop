import Foundation
import WhoopProtocol

/// Heart-rate recovery after a sufficiently intense workout (#516).
///
/// The engine deliberately works from the recorded HR stream rather than the workout's editable summary
/// fields. It looks for sustained Zone-3-or-higher effort near the end of the session, takes the highest
/// recorded HR in the final 30 seconds as the cessation value, then compares it with robust median readings
/// around 1, 2 and 5 minutes after the workout ended.
///
/// Missing post-workout coverage stays nil. The engine never interpolates across a gap or turns a missing
/// reading into zero, which is important when a strap disconnects as the workout ends.
public enum HeartRateRecovery {
    public struct Result: Equatable, Sendable {
        public let endHR: Int
        public let after1Minute: Int?
        public let after2Minutes: Int?
        public let after5Minutes: Int?

        public init(endHR: Int, after1Minute: Int?, after2Minutes: Int?, after5Minutes: Int?) {
            self.endHR = endHR
            self.after1Minute = after1Minute
            self.after2Minutes = after2Minutes
            self.after5Minutes = after5Minutes
        }

        public var hasMeasurement: Bool {
            after1Minute != nil || after2Minutes != nil || after5Minutes != nil
        }
    }

    /// Zone 3 starts at 70% HRmax in NOOP's display-zone model.
    public static let eligibilityFractionOfMaxHR = 0.70
    /// The high-intensity effort must be sustained, not a single optical spike.
    public static let minimumHighIntensitySeconds = 120
    /// Eligibility is intentionally tied to the end of the workout: HRR is meaningful only when exercise
    /// cessation, rather than a long cool-down, anchors the recovery clock.
    public static let eligibilityLookbackSeconds = 300
    public static let cessationWindowSeconds = 30
    public static let measurementToleranceSeconds = 15
    public static let minimumSamplesPerReading = 3
    public static let maximumContinuousGapSeconds = 10

    public static func calculate(samples: [HRSample], workoutStart: Int, workoutEnd: Int,
                                 maxHR: Double) -> Result? {
        guard workoutStart > 0, workoutEnd > workoutStart, maxHR > 0 else { return nil }
        let lowerBound = max(workoutStart, workoutEnd - eligibilityLookbackSeconds)
        let upperBound = workoutEnd + 5 * 60 + measurementToleranceSeconds
        let sorted = samples
            .filter { $0.ts >= lowerBound && $0.ts <= upperBound && (30...250).contains($0.bpm) }
            .sorted { lhs, rhs in lhs.ts == rhs.ts ? lhs.bpm < rhs.bpm : lhs.ts < rhs.ts }
        guard sorted.count >= minimumSamplesPerReading else { return nil }

        let beforeEnd = sorted.filter { $0.ts <= workoutEnd }
        let threshold = maxHR * eligibilityFractionOfMaxHR
        guard sustainedSeconds(atOrAbove: threshold, in: beforeEnd) >= minimumHighIntensitySeconds else {
            return nil
        }

        let cessation = beforeEnd
            .filter { $0.ts >= workoutEnd - cessationWindowSeconds }
            .map(\.bpm)
        guard cessation.count >= minimumSamplesPerReading, let endHR = cessation.max() else { return nil }

        func recovery(at minutes: Int) -> Int? {
            let target = workoutEnd + minutes * 60
            let values = sorted
                .filter { abs($0.ts - target) <= measurementToleranceSeconds }
                .map(\.bpm)
            guard values.count >= minimumSamplesPerReading, let reading = median(values) else { return nil }
            return endHR - reading
        }

        let result = Result(
            endHR: endHR,
            after1Minute: recovery(at: 1),
            after2Minutes: recovery(at: 2),
            after5Minutes: recovery(at: 5)
        )
        return result.hasMeasurement ? result : nil
    }

    private static func sustainedSeconds(atOrAbove threshold: Double, in samples: [HRSample]) -> Int {
        guard samples.count >= 2 else { return 0 }
        var currentSeconds = 0
        var longestSeconds = 0
        for i in 0..<(samples.count - 1) {
            let gap = samples[i + 1].ts - samples[i].ts
            guard gap > 0 else { continue }
            guard gap <= maximumContinuousGapSeconds else {
                currentSeconds = 0
                continue
            }
            guard Double(samples[i].bpm) >= threshold else {
                currentSeconds = 0
                continue
            }
            currentSeconds += gap
            longestSeconds = max(longestSeconds, currentSeconds)
        }
        return longestSeconds
    }

    private static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return Int((Double(sorted[middle - 1] + sorted[middle]) / 2.0).rounded())
        }
        return sorted[middle]
    }
}
