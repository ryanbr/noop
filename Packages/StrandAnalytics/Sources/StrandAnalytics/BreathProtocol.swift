import Foundation

// BreathProtocol.swift — content-driven breath sessions (stages + catalog + player).
// Created: 2026-08-16
// Last updated: 2026-08-16
//
// PURE + unit-tested. Mirrors the Ultrahuman-style “app is a renderer, protocols are content”
// pattern without copying UH assets or copy. Presence Process tempos measured from public guides.
// See docs/FEATURES.md (Breathe) and the NOOP breathwork catalog plan.

/// How a protocol is driven in the UI.
public enum BreathProtocolMode: String, Equatable, Sendable {
    /// Fixed stages + haptic/visual pacer.
    case playable
    /// Education + session timer only (no aggressive auto-pacer) — safety for variable techniques.
    case guided
}

/// Catalog grouping for the Breathe pace picker.
public enum BreathProtocolCategory: String, Equatable, Sendable {
    /// ANS / common breath protocols (public technique list).
    case ans
    /// Presence Process consciously-connected tempos.
    case presence
    /// Built-in NOOP biofeedback modes (Resonance / Calm) — not listed in this catalog table.
    case biofeedback
}

/// One timed stage inside a playable protocol.
public struct BreathStage: Equatable, Sendable {
    public let type: BreathPhase
    /// Stage length in milliseconds (explicit; no BPM clamp).
    public let durationMs: Int
    /// Optional English UI label (e.g. left/right nostril); localize at the view layer.
    public let label: String?

    public init(type: BreathPhase, durationMs: Int, label: String? = nil) {
        self.type = type
        self.durationMs = max(0, durationMs)
        self.label = label
    }
}

/// One breath protocol: identity, education keys (English source strings), and optional stages.
public struct BreathProtocol: Equatable, Sendable, Identifiable {
    public let id: String
    /// English source for `String(localized:)` — short pill / list title.
    public let title: String
    /// English source — one-line tagline under the orb when idle.
    public let subtitle: String
    /// English source — background / how-to for the ⓘ sheet.
    public let edu: String
    /// English source — safety / who should skip; nil if none.
    public let caution: String?
    /// English source — session length hint shown in the edu sheet.
    public let sessionHint: String?
    public let mode: BreathProtocolMode
    public let category: BreathProtocolCategory
    /// Default session length when the user picks this pace (Open / 5 / 10 / 15 override in UI).
    public let recommendedDurationMs: Int
    /// Empty when `mode == .guided`.
    public let stages: [BreathStage]

    public init(id: String,
                title: String,
                subtitle: String,
                edu: String,
                caution: String? = nil,
                sessionHint: String? = nil,
                mode: BreathProtocolMode,
                category: BreathProtocolCategory,
                recommendedDurationMs: Int,
                stages: [BreathStage] = []) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.edu = edu
        self.caution = caution
        self.sessionHint = sessionHint
        self.mode = mode
        self.category = category
        self.recommendedDurationMs = max(0, recommendedDurationMs)
        self.stages = stages
    }

    /// Sum of one full stage cycle in ms (0 for guided).
    public var cycleDurationMs: Int {
        stages.reduce(0) { $0 + $1.durationMs }
    }
}

/// Haptic / phase cue list from a playable protocol for a fixed session window.
public enum BreathProtocolPlayer {

    public static let holdLoops: Int = 0
    public static let textOnlyLoops: Int = 0

    /// Map a stage type to the felt buzz count (parity with `BreathPacer` for inhale/exhale).
    public static func loops(for phase: BreathPhase) -> Int {
        switch phase {
        case .inhale: return BreathPacer.inhaleLoops
        case .exhale: return BreathPacer.exhaleLoops
        case .hold, .textOnly: return 0
        }
    }

    /// Build cues covering `[0, sessionMs)` by repeating the protocol’s stage cycle.
    /// Guided protocols or empty stages → `[]`. `sessionMs < 1` → `[]`.
    /// Stops scheduling new stage onsets once `offsetMs >= sessionMs`.
    public static func schedule(_ proto: BreathProtocol, sessionMs: Int) -> [BreathCue] {
        guard proto.mode == .playable else { return [] }
        guard sessionMs >= 1 else { return [] }
        let stages = proto.stages.filter { $0.durationMs > 0 }
        guard !stages.isEmpty else { return [] }

        let cycleMs = stages.reduce(0) { $0 + $1.durationMs }
        guard cycleMs > 0 else { return [] }

        var out: [BreathCue] = []
        var base = 0
        var guardCycles = 0
        let maxCycles = max(1, (sessionMs / cycleMs) + 2)
        while base < sessionMs && guardCycles < maxCycles {
            var offset = base
            for stage in stages {
                if offset >= sessionMs { break }
                out.append(BreathCue(
                    offsetMs: offset,
                    phase: stage.type,
                    loops: loops(for: stage.type),
                    label: stage.label
                ))
                offset += stage.durationMs
            }
            base += cycleMs
            guardCycles += 1
        }
        return out
    }
}
