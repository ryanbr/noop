import Foundation
import WhoopProtocol

/// Sleep-context twin of Kotlin `SleepAwareStepCounter`. Counter decisions stay orientation-independent.
public enum SleepAwareStepCounter {
    public static let maxSecondsBetweenGaitDeltas = 3
    public static let minGaitBoutDurationSeconds = 4
    public static let minGaitBoutActiveSamples = 5
    public static let minGaitBoutTicks = 6

    public struct Count: Equatable, Sendable {
        public let totalTicks: Int
        public let acceptedOutsideSleepTicks: Int
        public let acceptedAwakeGapTicks: Int
        public let acceptedSleepBoutTicks: Int
        public let rejectedIsolatedSleepTicks: Int
        public let rejectedActivityClassTicks: Int
        public let rejectedImplausibleTicks: Int
        public let gravitySamplesAvailable: Int
        public let auxSamplesAvailable: Int

        public static let empty = Count(totalTicks: 0, acceptedOutsideSleepTicks: 0,
            acceptedAwakeGapTicks: 0, acceptedSleepBoutTicks: 0, rejectedIsolatedSleepTicks: 0,
            rejectedActivityClassTicks: 0, rejectedImplausibleTicks: 0,
            gravitySamplesAvailable: 0, auxSamplesAvailable: 0)

        /// Kotlin twin: `SleepAwareStepCounter.Count.plus`.
        public func adding(_ other: Count) -> Count {
            Count(totalTicks: totalTicks + other.totalTicks,
                acceptedOutsideSleepTicks: acceptedOutsideSleepTicks + other.acceptedOutsideSleepTicks,
                acceptedAwakeGapTicks: acceptedAwakeGapTicks + other.acceptedAwakeGapTicks,
                acceptedSleepBoutTicks: acceptedSleepBoutTicks + other.acceptedSleepBoutTicks,
                rejectedIsolatedSleepTicks: rejectedIsolatedSleepTicks + other.rejectedIsolatedSleepTicks,
                rejectedActivityClassTicks: rejectedActivityClassTicks + other.rejectedActivityClassTicks,
                rejectedImplausibleTicks: rejectedImplausibleTicks + other.rejectedImplausibleTicks,
                gravitySamplesAvailable: gravitySamplesAvailable + other.gravitySamplesAvailable,
                auxSamplesAvailable: auxSamplesAvailable + other.auxSamplesAvailable)
        }
    }

    /// Stateful, overlap-safe counter for database windows read in ascending pages.
    public final class Accumulator {
        private let sessions: [SleepSession]
        private let hasClasses: Bool
        private var previous: StepSample?
        private var outside = 0, awake = 0, sleep = 0, rejectedSleep = 0
        private var rejectedClass = 0, rejectedImplausible = 0
        private var gravityAvailable = 0, auxAvailable = 0
        private var pending: [(ts: Int, ticks: Int)] = []
        private var finished = false

        public init(sleepSessions: [SleepSession], hasActivityClasses: Bool) {
            sessions = sleepSessions.sorted { $0.start < $1.start }
            hasClasses = hasActivityClasses
        }

        /// Kotlin twin: `SleepAwareStepCounter.Accumulator.acceptPage`.
        @discardableResult public func acceptPage(_ samples: [StepSample]) -> Accumulator {
            precondition(!finished)
            for current in samples.sorted(by: { $0.ts < $1.ts }) {
                guard let prior = previous else { previous = current; continue }
                guard current.ts > prior.ts else { continue }
                previous = current
                let delta = (current.counter - prior.counter) & 0xffff
                guard StepsCounter.shouldCountDelta(activityClass: current.activityClass,
                                                     hasActivityClasses: hasClasses) else {
                    rejectedClass += delta; continue
                }
                guard StepsCounter.isPlausibleDelta(previousTs: prior.ts, currentTs: current.ts,
                                                    delta: delta) else {
                    rejectedImplausible += delta; continue
                }
                switch SleepAwareStepCounter.context(current.ts, sessions: sessions) {
                case 0: flush(); outside += delta
                case 1: flush(); awake += delta
                default:
                    if let last = pending.last, current.ts - last.ts > maxSecondsBetweenGaitDeltas { flush() }
                    pending.append((current.ts, delta))
                }
            }
            return self
        }

        /// Kotlin twin: `SleepAwareStepCounter.Accumulator.observeMotionPage`.
        @discardableResult public func observeMotion(gravityCount: Int, auxCount: Int) -> Accumulator {
            precondition(!finished)
            gravityAvailable += gravityCount
            auxAvailable += auxCount
            return self
        }

        /// Kotlin twin: `SleepAwareStepCounter.Accumulator.finish`.
        public func finish() -> Count {
            if !finished { flush(); finished = true }
            return Count(totalTicks: outside + awake + sleep, acceptedOutsideSleepTicks: outside,
                         acceptedAwakeGapTicks: awake, acceptedSleepBoutTicks: sleep,
                         rejectedIsolatedSleepTicks: rejectedSleep,
                         rejectedActivityClassTicks: rejectedClass,
                         rejectedImplausibleTicks: rejectedImplausible,
                         gravitySamplesAvailable: gravityAvailable,
                         auxSamplesAvailable: auxAvailable)
        }

        /// Kotlin twin: `SleepAwareStepCounter.Accumulator.flushSleepBout`.
        private func flush() {
            guard !pending.isEmpty else { return }
            let ticks = pending.reduce(0) { $0 + $1.ticks }
            let duration = pending.last!.ts - pending.first!.ts
            let coherent = pending.count >= minGaitBoutActiveSamples
                && duration >= minGaitBoutDurationSeconds && ticks >= minGaitBoutTicks
            if coherent { sleep += ticks } else { rejectedSleep += ticks }
            pending.removeAll(keepingCapacity: true)
        }
    }

    /// Kotlin twin: `SleepAwareStepCounter.stepsInWindow`.
    public static func stepsInWindow(_ samples: [StepSample], sleepSessions: [SleepSession]) -> Int? {
        let count = count(samples, sleepSessions: sleepSessions)
        return count.totalTicks > 0 ? count.totalTicks : nil
    }

    /// Kotlin twin: `SleepAwareStepCounter.count`.
    public static func count(_ samples: [StepSample], sleepSessions: [SleepSession]) -> Count {
        let sorted = samples.sorted { $0.ts < $1.ts }
        return Accumulator(sleepSessions: sleepSessions,
                           hasActivityClasses: StepsCounter.hasActivityClasses(sorted))
            .acceptPage(sorted).finish()
    }

    /// Kotlin twin: `SleepAwareStepCounter.contextAt`.
    private static func context(_ ts: Int, sessions: [SleepSession]) -> Int {
        guard let session = sessions.first(where: { ts >= $0.start && ts < $0.end }) else { return 0 }
        if let stage = session.stages.first(where: { ts >= $0.start && ts < $0.end }),
           SleepStageVocabulary.isWake(stage.stage) { return 1 }
        return 2
    }
}
