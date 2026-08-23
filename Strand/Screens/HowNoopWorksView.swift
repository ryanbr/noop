import SwiftUI
import StrandDesign

// MARK: - How NOOP works (primer)
//
// COMPONENT 5 of the Sleep & Recovery Guidance / Explainability layer
// (docs/superpowers/specs/2026-06-20-sleep-guidance-explainability.md).
//
// A short, skimmable, plain-English primer that answers the four "how does this
// work?" questions people ask: how sleep is sorted, how scores + calibration work,
// what "recording" means, and where the provenance badges come from. It is the one
// place that ties the four guidance components together so nobody has to guess.
//
// Presented as a sheet, mirroring ScoringGuideView / WhatsNewView exactly: a fixed
// header with a close button over a scenic hero, a scrollable column of frosted
// cards, and a "Got it" footer. Reachable from Settings → About and a "?" affordance.
//
// All copy here is the single APPROVED source of truth (the spec's COMPONENT 5 text,
// verbatim), shared word-for-word across macOS / iOS / Android. No fabricated values,
// no jargon, no em-dashes. Kotlin's primer composable mirrors these four sections.

struct HowNoopWorksView: View {
    let onClose: () -> Void

    /// The four primer sections, in the order the spec lists them. The icon + tint give
    /// each card its own glance-able identity, echoing the colour worlds used elsewhere.
    private enum Section: CaseIterable, Identifiable {
        case sleepSorting
        case scores
        case recording
        case provenance

        var id: Self { self }

        var title: String {
            switch self {
            case .sleepSorting: return String(localized: "How your sleep is sorted")
            case .scores:       return String(localized: "How your scores work")
            case .recording:    return String(localized: "What \"recording\" means")
            case .provenance:   return String(localized: "Where your numbers come from")
            }
        }

        var body: String {
            switch self {
            case .sleepSorting:
                return String(localized: "NOOP picks your main sleep as your longest real block, and (once it has learned your usual hours) the one nearest your normal sleep time. Everything else that day is a nap. You can always edit bed and wake times.")
            case .scores:
                return String(localized: "Charge, Effort and Rest are scored on your own device from your strap data. Charge needs about four nights of sleep to learn your baseline (that's \"Calibrating\", counted as nights of 4 on the ring), and keeps sharpening over your first couple of weeks. On a WHOOP 5 or MG the strap banks little history, so that count can sit at 0 of 4 until you have worn it across a few nights. That's the strap's sync limit, not a fault. Before there's a number, NOOP shows what it can without faking one.")
            case .recording:
                return String(localized: "When your strap is connected NOOP is saving data live. \"Last synced\" tells you how fresh it is. If it says \"Not recording\", reconnect.")
            case .provenance:
                return String(localized: "A badge shows whether a number was scored on-device by NOOP, or imported from Whoop or Apple Health.")
            }
        }

        /// SF Symbol for the section header — sleep / scores / recording / provenance.
        var icon: String {
            switch self {
            case .sleepSorting: return "moon.zzz.fill"
            case .scores:       return "gauge.with.dots.needle.67percent"
            case .recording:    return "dot.radiowaves.left.and.right"
            case .provenance:   return "checkmark.seal.fill"
            }
        }

        /// The colour world that tints the card, matched to the domain each section is about
        /// (sleep = Rest, scores = Charge, recording = Effort, provenance = neutral accent).
        var tint: Color {
            switch self {
            case .sleepSorting: return DomainTheme.rest.color
            case .scores:       return DomainTheme.charge.color
            case .recording:    return DomainTheme.effort.color
            case .provenance:   return StrandPalette.accent
            }
        }

        /// Short overline tag above the section title.
        var overline: String {
            switch self {
            case .sleepSorting: return String(localized: "SLEEP")
            case .scores:       return String(localized: "SCORES")
            case .recording:    return String(localized: "RECORDING")
            case .provenance:   return String(localized: "PROVENANCE")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .background {
                    ScenicHeroBackground(domain: .rest, starCount: 28, fadesToBase: true)
                }
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    introCard
                    ForEach(Section.allCases) { section in
                        primerCard(section)
                    }
                    scoringMethodsCard
                    footerNote
                }
                .padding(20)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
        // Same sizing split as ScoringGuideView / WhatsNewView: a fixed window on macOS,
        // fill the presented sheet on iOS so nothing runs off a narrow phone screen (#185).
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
    }

    // MARK: - Header / footer

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("THE BASICS").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("How NOOP works").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Sleep · scores · recording · where your numbers come from")
                    .font(StrandFont.caption)
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
                Text("THE ONE RULE").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("NOOP never shows you a number it had to make up. If a score isn't ready, it tells you why and what to do next. Everything here runs on your device, from your strap.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One primer section: a frosted, tinted card carrying the tinted icon + overline +
    /// title, then the plain-English body. The icon is decorative (hidden from
    /// VoiceOver); the card reads its title and body together.
    private func primerCard(_ section: Section) -> some View {
        NoopCard(tint: section.tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: section.icon)
                        .font(.system(size: 18))
                        .foregroundStyle(section.tint)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.overline)
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(section.tint)
                        Text(section.title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Text(section.body)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(section.title). \(section.body)")
    }

    // MARK: - A7: "How your scores are computed" (named method families)

    /// The four scores, each named with the PUBLISHED method family it follows. Honest about the
    /// approach without faking precision: it cites the method, not a proprietary-identical claim. Order
    /// mirrors the app's score order (Charge, Effort, Rest, Fitness Age); the tint matches each domain.
    private enum ScoreMethod: CaseIterable, Identifiable {
        case charge, effort, rest, fitnessAge
        var id: Self { self }

        var name: String {
            switch self {
            case .charge:     return String(localized: "Charge")
            case .effort:     return String(localized: "Effort")
            case .rest:       return String(localized: "Rest")
            case .fitnessAge: return String(localized: "Fitness Age")
            }
        }

        /// The plain-English description of the published method behind the score.
        var method: String {
            switch self {
            case .charge:
                return String(localized: "A baseline-normalized recovery score: your resting heart rate, sleep quality and night-to-night consistency, weighted against your own baseline, with heart-rate variability (rMSSD) leading wherever the strap gives us a clean reading.")
            case .effort:
                return String(localized: "A cardiovascular load from time in heart-rate zones (Edwards TRIMP): each zone is weighted so harder ones count for more, summed into one daily figure. Settings offers an exponential alternative (Banister) that credits short, hard efforts more.")
            case .rest:
                return String(localized: "Sleep scored from how long you slept versus how much you needed, how efficient the night was, and the restorative (deep and REM) share of it.")
            case .fitnessAge:
                return String(localized: "An estimated VO2max from the Nes / HUNT Fitness Study model (resting heart rate, age and activity), read against population norms to express it as a fitness age.")
            }
        }

        /// The short method-family tag shown as an overline next to the score name.
        var family: String {
            switch self {
            case .charge:     return String(localized: "RESTING HR + SLEEP + HRV")
            case .effort:     return String(localized: "BANISTER TRIMP / HR ZONES")
            case .rest:       return String(localized: "DURATION + EFFICIENCY + STAGES")
            case .fitnessAge: return String(localized: "NES / HUNT VO2MAX")
            }
        }

        var tint: Color {
            switch self {
            case .charge:     return DomainTheme.charge.color
            case .effort:     return DomainTheme.effort.color
            case .rest:       return DomainTheme.rest.color
            case .fitnessAge: return StrandPalette.accent
            }
        }
    }

    /// A7 , the "How your scores are computed" card: one row per score naming its published method
    /// family, honest about the approach without claiming a proprietary-identical result.
    private var scoringMethodsCard: some View {
        NoopCard(tint: DomainTheme.charge.color) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "function")
                        .font(.system(size: 18))
                        .foregroundStyle(DomainTheme.charge.color)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("METHOD")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(DomainTheme.charge.color)
                        Text("How your scores are computed")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                Text("Each score follows a published method, computed on your device. We name the method family so you can read up on it, and we never claim to reproduce another company's number exactly.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ScoreMethod.allCases) { method in
                        methodRow(method)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One score-method row: the score name + its method-family overline, then the plain-English method.
    private func methodRow(_ m: ScoreMethod) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(m.name)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(m.family)
                    .font(StrandFont.overline)
                    .tracking(0.4)
                    .foregroundStyle(m.tint)
                Spacer(minLength: 0)
            }
            Text(m.method)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(m.name). \(m.method)")
    }

    private var footerNote: some View {
        Text("NOOP never makes up a number. When it can't compute one honestly it tells you what's missing and what to do, rather than showing a fake value.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

#if DEBUG
#Preview("How NOOP works") {
    HowNoopWorksView(onClose: {})
        .preferredColorScheme(.dark)
}
#endif
