import SwiftUI
import Combine
import StrandDesign

// StressCheckInCard.swift — the L3 closed-loop JITAI surface (the "passive" layer). When the shipped,
// unit-tested `StressOnsetDetector` fires (a fresh, non-metabolic HRV dip while the user is still), the
// central hook (Wave 3, in BLEManager's existing offload/evaluateStress call-site) posts a pending nudge
// on `StressNudgeCenter`; this dismissible card surfaces it. NEVER an alarm, NEVER a push (unless the
// user separately opted into notifications), NEVER a diagnosis — "HRV dipped while you were still", with
// Breathe now / Not now / Turn off, matching DaytimeStress's "passive suggestion" stance.
//
// See docs/superpowers/specs/2026-06-19-v5-haptic-biofeedback-design.md (L3 / UX → "Auto-nudge (passive)").

/// The single observable the L3 hook posts to and the card observes. Self-contained — the central wiring
/// (Wave 3) holds one instance and calls `present()` when `StressOnsetDetector.evaluate` returns
/// `shouldNudge`; the card binds to `pending`. Keeping it here (not in AppModel) means the UI lane owns
/// the whole surface; Wave 3 only needs to inject the instance + call `present`.
@MainActor
final class StressNudgeCenter: ObservableObject {
    /// A live nudge awaiting the user, or nil. Carries the engine's honest numbers for the card copy.
    @Published var pending: Nudge? = nil

    struct Nudge: Equatable {
        /// The fast short-window RMSSD at the moment of the dip (ms), for the honest sub-line.
        let fastRMSSD: Double?
        /// The slow baseline RMSSD (ms) it dipped below.
        let baselineRMSSD: Double?
        /// When it fired.
        let firedAt: Date
    }

    /// Post a nudge (the central L3 hook calls this on a fire). Idempotent-ish: a newer fire replaces an
    /// un-acted one.
    func present(fastRMSSD: Double?, baselineRMSSD: Double?) {
        pending = Nudge(fastRMSSD: fastRMSSD, baselineRMSSD: baselineRMSSD, firedAt: Date())
    }

    func dismiss() { pending = nil }
}

/// The dismissible Stress check-in card. Self-contained — pass the `StressNudgeCenter` and a
/// `onBreatheNow` closure (the host starts a 60-s session at the user's locked pace); `onTurnOff` flips
/// the master toggle off via `BiofeedbackPrefs`. Renders only when a nudge is pending.
struct StressCheckInCard: View {
    @ObservedObject var center: StressNudgeCenter
    /// Start a one-minute breathing cue (the host wires this to the controller at the resonance/5.5 pace).
    var onBreatheNow: () -> Void

    var body: some View {
        if let nudge = center.pending {
            StrandCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "wind")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StrandPalette.restBright)
                            .accessibilityHidden(true)
                        Text("Stress check-in").strandOverline()
                        Spacer()
                        StatePill("Passive", tone: .neutral, showsDot: true)
                    }

                    Text("Your HRV dipped while you were still — want a minute to breathe?")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let line = honestLine(nudge) {
                        Text(line)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button {
                            center.dismiss()
                            onBreatheNow()
                        } label: {
                            Text("Breathe now")
                                .font(StrandFont.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(StrandPalette.accent)

                        Button("Not now") { center.dismiss() }
                            .font(StrandFont.body)
                            .buttonStyle(.bordered)

                        Button("Turn off") {
                            BiofeedbackPrefs.checkInEnabled = false
                            center.dismiss()
                        }
                        .font(StrandFont.body)
                        .buttonStyle(.borderless)
                        .foregroundStyle(StrandPalette.textSecondary)
                    }

                    Text("Relaxation guidance from your own numbers — not a health alert, and not a diagnosis. Trends matter more than any single number.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .transition(.opacity)
        }
    }

    /// An honest one-liner with the two estimates the engine surfaced, framed as "your own number".
    private func honestLine(_ nudge: StressNudgeCenter.Nudge) -> String? {
        guard let fast = nudge.fastRMSSD, let base = nudge.baselineRMSSD, base > 0 else { return nil }
        return String(format: "RMSSD %.0f ms now vs your ~%.0f ms baseline (estimate from PPG-derived R-R).",
                      fast, base)
    }
}
