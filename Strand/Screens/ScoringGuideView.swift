import SwiftUI
import StrandDesign

// MARK: - Scoring guide
//
// "How your scores work" — the one honest explainer for NOOP's three daily scores
// (Charge, Effort, Rest) and the confidence labels. Presented as a sheet, mirroring
// WhatsNewView's presentation + dismiss + layout idiom: a fixed header with a close
// button, a scrollable column of cards, and a "Got it" footer. Reachable from
// Settings → About, the ⓘ on each Today score, and the one-time first-run card.
//
// All copy here is the single approved source of truth, shared verbatim across
// macOS / iOS / Android. Each score section is tinted with the SAME Reset accent the
// rest of the app uses for that score's hero ring (Charge = green, Effort = blue
// accent, Rest = restColor slate), so a glance maps a section to its Today ring.

/// The three score sections the guide can deep-link to. The raw value is used as the
/// ScrollViewReader anchor id. The Android port mirrors these case names exactly.
enum ScoreSection: String, CaseIterable, Identifiable {
    case charge
    case effort
    case rest

    var id: String { rawValue }

    /// The accent each section uses — the SAME Reset score token its Today hero ring draws with, so a
    /// section reads as that score's colour. No gold / strain / sleep-purple: Charge = chargeColor green,
    /// Effort = effortColor blue accent, Rest = restColor slate (Design Reset, 2026-06-23).
    var accent: Color {
        switch self {
        case .charge: return StrandPalette.chargeColor     // Charge hero ring — green
        case .effort: return StrandPalette.effortColor     // Effort hero ring — blue accent
        case .rest:   return StrandPalette.restColor       // Rest hero ring — slate
        }
    }

    /// A representative sample fraction (0–1) for the section's illustrative gauge — a
    /// "what a strong day looks like" reading, purely decorative in the guide.
    var sampleFraction: Double {
        switch self {
        case .charge: return 0.82
        case .effort: return 0.64
        case .rest:   return 0.88
        }
    }

    /// The number shown inside the sample gauge (the 0–100 score the fraction maps to).
    var sampleNumber: String {
        "\(Int((sampleFraction * 100).rounded()))"
    }

    /// The SF Symbol for the section header (heart/spark · flame · moon).
    var icon: String {
        switch self {
        case .charge: return "heart.circle.fill"
        case .effort: return "flame.fill"
        case .rest:   return "moon.stars.fill"
        }
    }

    /// Localized display name for the section (the raw value stays the stable anchor id).
    var displayName: String {
        switch self {
        case .charge: return String(localized: "Charge")
        case .effort: return String(localized: "Effort")
        case .rest:   return String(localized: "Rest")
        }
    }
}

struct ScoringGuideView: View {
    /// When set, the guide scrolls to (and briefly highlights) this section on appear —
    /// used by the ⓘ affordances on the Today screen so each opens at its own score.
    var initialSection: ScoreSection? = nil
    let onClose: () -> Void

    /// Drives the brief highlight pulse on the deep-linked section.
    @State private var highlighted: ScoreSection? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
                // Design Reset: a FLAT opaque WHOOP-grey title surface — no scenic hero, no bloom, no
                // domain tint. The header reads as a clean raised card edge, matching the Today look.
                .background(NoopChromeSurface())
            Divider().overlay(StrandPalette.hairline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        introCard
                        scoreCard(.charge,
                                  headline: String(localized: "Charge: how recovered are you?"),
                                  body: String(localized: "Led by your heart-rate variability (HRV) measured against your own personal baseline, plus resting heart rate, last night's Rest, breathing rate, and a skin-temperature signal (an early illness or overreach flag). Higher HRV versus your baseline means more Charge. NOOP needs a few nights to learn your baseline first. Until then you'll see “Calibrating”."),
                                  vsWhoop: String(localized: "Same core idea as WHOOP's Recovery % (HRV-led recovery), but our weighting and baseline maths are our own, and openly documented."))
                        scoreCard(.effort,
                                  headline: String(localized: "Effort: how hard did your heart work?"),
                                  body: String(localized: "Your cardiovascular load. NOOP turns every second of heart rate into a training-impulse using heart-rate-reserve zones (Karvonen), weights time in harder zones more heavily (Edwards / Banister), and places it on a logarithmic 0-100 scale, so easy days sit low and an all-out day approaches 100, which stays genuinely rare. A long walk with little cardio still counts, through a steps / active-energy floor."),
                                  vsWhoop: String(localized: "Same cardiovascular-load idea as WHOOP's Day Strain (0-21). We rescaled the top of the ladder from 21 to 100 so all three scores share one scale. The rungs didn't move, so a 100 is as rare as a 21.0 was."))
                        scoreCard(.rest,
                                  headline: String(localized: "Rest: how restorative was your sleep?"),
                                  body: String(localized: "A blend of how long you slept versus your personal need (the biggest factor), how efficiently (asleep versus in bed), how much was restorative (deep + REM sleep), and how consistent your sleep and wake timing is."),
                                  vsWhoop: String(localized: "Similar in spirit to WHOOP's Sleep Performance %; our composite is our own."))
                        confidenceCard
                        footerNote
                    }
                    .padding(20)
                }
                #if os(iOS)
                // #697/#horizontal-swipe parity, see ScreenScaffold.
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                #endif
                .onAppear { jump(to: initialSection, using: proxy) }
            }
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        // Same sizing split as WhatsNewView: a fixed window on macOS, fill the presented
        // sheet on iOS so nothing runs off a narrow phone screen (#185).
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A long explainer scroll → open full-height, with a grabber for swipe-to-dismiss.
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR DAILY SCORES").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("How your scores work").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Charge · Effort · Rest").font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            Button(action: onClose) {
                Text("Got it").frame(minWidth: 120).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(StrandPalette.accent)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    // MARK: - Cards

    private var introCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("THE THREE SCORES").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("NOOP gives you three daily scores (Charge, Effort and Rest), each on a 0-100 scale. They're built from your strap's raw signals using published, peer-reviewed sport science, and computed entirely on your device. They are NOT WHOOP's scores: we don't have WHOOP's private algorithms and don't pretend to. They aim at the same three questions using open science, so they'll usually track WHOOP's in direction, but won't match number-for-number. And that's the point.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The three accents as a quick legend, echoing the section colours below.
                HStack(spacing: 16) {
                    legendDot(.charge, String(localized: "Charge"))
                    legendDot(.effort, String(localized: "Effort"))
                    legendDot(.rest, String(localized: "Rest"))
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendDot(_ section: ScoreSection, _ label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(section.accent).frame(width: 8, height: 8)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// One colour-accented score section: a FLAT WHOOP-grey card (faintly washed with the section's Reset
    /// accent) carrying a clean sample ring of that score beside an accent-tinted headline, the body, and
    /// an italic "vs WHOOP" line set off by a hairline rule. The ring is illustrative — a "what a strong
    /// day reads like" preview in the section's own colour — so a glance maps a card to its Today ring.
    /// Design Reset: a flat GlowRing (no bloom) replaces the old BevelGauge; the accent is a Reset score
    /// token, never gold / strain / sleep-purple.
    private func scoreCard(_ section: ScoreSection, headline: String, body: String, vsWhoop: String) -> some View {
        NoopCard(tint: section.accent) {
            VStack(alignment: .leading, spacing: 14) {
                // Header row — the flat sample ring sits beside the accent icon + headline.
                HStack(alignment: .center, spacing: 14) {
                    sampleRing(section)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: section.icon)
                                .font(.system(size: 16))
                                .foregroundStyle(section.accent)
                                .accessibilityHidden(true)
                            Text(section.displayName)
                                .font(StrandFont.overline)
                                .tracking(StrandFont.overlineTracking)
                                .textCase(.uppercase)
                                .foregroundStyle(section.accent)
                        }
                        Text(headline).font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Text(body)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(StrandPalette.hairline)
                HStack(alignment: .top, spacing: 8) {
                    Text("vs WHOOP").font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .textCase(.uppercase)
                        .foregroundStyle(section.accent)
                        .padding(.top, 1)
                    Text(vsWhoop)
                        .font(StrandFont.footnote)
                        .italic()
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Deep-link highlight: a brief accent-tinted ring when arrived at via an ⓘ.
        .overlay(
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .strokeBorder(section.accent, lineWidth: 2)
                .opacity(highlighted == section ? 1 : 0)
        )
        .animation(.easeOut(duration: 0.35), value: highlighted)
        .id(section.id)
    }

    /// The flat illustrative ring for a score section — a clean GlowRing (Design Reset: solid crisp arc,
    /// NO bloom) in the section's Reset accent, with the score name as a small caption below, matching the
    /// Today hero rings. Decorative ("what a strong day looks like"), so it's hidden from VoiceOver by the
    /// caller. Replaces the old per-section BevelGauge(bloomActive: true).
    private func sampleRing(_ section: ScoreSection) -> some View {
        VStack(spacing: 5) {
            GlowRing(
                fraction: section.sampleFraction,
                value: section.sampleFraction * 100,
                format: { "\(Int($0.rounded()))" },
                color: section.accent,
                diameter: 76,
                lineWidth: 8
            )
            Text(section.displayName)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var confidenceCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("How sure is NOOP?  ·  Solid · Building · Calibrating")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                // The three labels as the same pills used elsewhere, in their honest order.
                HStack(spacing: 8) {
                    StatePill("Solid", tone: .positive, showsDot: true)
                    StatePill("Building", tone: .warning, showsDot: true)
                    StatePill("Calibrating", tone: .neutral, showsDot: true)
                }
                Text("Every score carries a small honesty label. Calibrating means NOOP is still learning your baseline, or doesn't have enough data yet. Building means there's enough to show, but it's thin. Solid means full inputs are present. When NOOP can't compute a score honestly, it shows nothing rather than a fake number.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerNote: some View {
        Text("These are independent approximations from a consumer strap, built on open science: not medical advice, and not WHOOP's official scores.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - Deep-link

    /// Scroll to the requested section and pulse its highlight, then fade it.
    private func jump(to section: ScoreSection?, using proxy: ScrollViewProxy) {
        guard let section else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(section.id, anchor: .top)
            }
            highlighted = section
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if highlighted == section { highlighted = nil }
            }
        }
    }
}

#if DEBUG
#Preview("Scoring guide") {
    ScoringGuideView(initialSection: .effort, onClose: {})
        .preferredColorScheme(.dark)
}
#endif
