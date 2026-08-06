import SwiftUI
import StrandDesign

// MARK: - Apple Watch setup
//
// The honest onboarding flow for using NOOP with only an Apple Watch (M2 of the Watch-as-a-
// device project). Two short steps:
//   1. What the watch is great at, and where it's lighter than a chest strap. Set expectations
//      BEFORE asking for anything, so the permission ask is informed and the tone stays honest.
//   2. The Health permission step, which triggers the existing HealthKitBridge.requestAuthorization.
//      We never reimplement the request: the bridge owns the type list, the entitlement checks, and
//      arming live ingestion once granted.
//
// Presented as a sheet, mirroring ScoringGuideView's idiom: a fixed header with a close button, a
// scrollable body, and a footer action bar. macOS has no HealthKit, so the permission step there
// reads as "this needs an iPhone" rather than offering a button that can't work, the same honest
// reroute AppleHealthView already uses.
//
// Plain voice, no fabricated numbers, upfront about the limitations.

struct AppleWatchSetupView: View {
    let onClose: () -> Void

    /// iOS-only: the live HealthKit bridge that owns the real permission request. macOS has no
    /// HealthKit, so this and every `health.*` use stays `#if os(iOS)`-gated.
    #if os(iOS)
    @EnvironmentObject private var health: HealthKitBridge
    #endif

    private enum Step {
        case intro       // what it's good at / where it's lighter
        case permission  // trigger the Health request
    }

    @State private var step: Step = .intro

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(NoopChromeSurface())
            Divider().overlay(StrandPalette.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    switch step {
                    case .intro:      introBody
                    case .permission: permissionBody
                    }
                }
                .padding(20)
            }
            Divider().overlay(StrandPalette.hairline)
            footerBar
        }
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
                Text("APPLE WATCH").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Use NOOP with your watch").font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(step == .intro ? "What to expect" : "Connect Apple Health")
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

    @ViewBuilder private var footerBar: some View {
        switch step {
        case .intro:
            HStack {
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { step = .permission }
                } label: {
                    Text("Continue").frame(minWidth: 120).padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(StrandPalette.accent)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Goes to the Apple Health permission step")
            }
            .padding(16)
        case .permission:
            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.2)) { step = .intro }
                }
                .buttonStyle(.bordered)
                .tint(StrandPalette.accent)
                Spacer()
                #if os(iOS)
                if health.auth == .authorized {
                    Button {
                        onClose()
                    } label: {
                        Text("Done").frame(minWidth: 120).padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Not now") { onClose() }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                #else
                Button("Close") { onClose() }
                    .buttonStyle(.bordered)
                    .tint(StrandPalette.accent)
                #endif
            }
            .padding(16)
        }
    }

    // MARK: - Step 1: what to expect

    private var introBody: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "applewatch")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(StrandPalette.accent)
                            .frame(width: 34, height: 34)
                            .background(StrandPalette.accent.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityHidden(true)
                        Text("Your watch, NOOP's brain")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                    }
                    Text("No chest strap? No problem. NOOP can run off only your Apple Watch. It reads your watch's data through Apple Health and works out your Charge, Rest, Effort and Fitness Age right here on your phone. Everything stays on the device.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            goodAtCard
            lighterCard

            Text("Want the full breakdown of every metric and how sure NOOP is about each one? The \u{201C}About Apple Watch data\u{201D} page in Settings has the honest table.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var goodAtCard: some View {
        NoopCard(tint: StrandPalette.statusPositive) {
            VStack(alignment: .leading, spacing: 12) {
                Text("WHAT IT'S GREAT AT").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.statusPositive)
                bullet("bed.double.fill", String(localized: "Sleep & Rest"),
                       String(localized: "Apple's sleep stages are strong, and they drive your Rest score directly."))
                bullet("figure.walk", String(localized: "Steps & workouts"),
                       String(localized: "Steps, active energy and logged workouts feed your Effort. Dense and reliable."))
                bullet("bolt.heart.fill", String(localized: "Fitness Age"),
                       String(localized: "Built from the watch's cardio-fitness VO₂ max, the same number the Fitness app shows."))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var lighterCard: some View {
        NoopCard(tint: StrandPalette.statusWarning) {
            VStack(alignment: .leading, spacing: 12) {
                Text("WHERE IT'S LIGHTER THAN A STRAP").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.statusWarning)
                bullet("heart.fill", String(localized: "Recovery takes about a week"),
                       String(localized: "A watch samples your heart-rate variability rather than streaming it all night, so your Charge score needs roughly seven nights to calibrate. Until then NOOP shows \u{201C}needs more data\u{201D}, never a guessed number."))
                bullet("drop.degreesign", String(localized: "A couple of metrics depend on your model"),
                       String(localized: "Wrist temperature needs Series 8 or later, and the newest US units dropped the blood-oxygen sensor. Where a sensor isn't there, NOOP reads \u{201C}not available\u{201D} instead of zero."))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bullet(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(detail)")
    }

    // MARK: - Step 2: Health permission

    @ViewBuilder private var permissionBody: some View {
        #if os(iOS)
        NoopCard(tint: StrandPalette.metricCyan) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.metricCyan)
                        .frame(width: 30, height: 30)
                        .background(StrandPalette.metricCyan.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Connect Apple Health")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    if health.auth == .authorized {
                        StatePill(health.syncing ? "Syncing" : "Connected",
                                  tone: .positive, pulsing: health.syncing)
                    }
                }

                switch health.auth {
                case .unavailable:
                    Text("Apple Health isn't available on this device, so there's nothing to connect here.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .entitlementMissing:
                    // The sideload was re-signed without the HealthKit entitlement (free Apple IDs always
                    // lack it, and some paid reseller certs do too, #930), so the request can never present
                    // and the app can never appear under Settings › Health. Give the honest path instead
                    // of an impossible Settings instruction (mirrors #348).
                    Text("This install can't connect to Apple Health directly. It was signed with a profile that doesn't include Apple's Health permission, so there's nothing to grant here.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You can still bring your data in by importing a Health export from Data Sources. A build from the App Store, or one signed with a paid Apple Developer account, connects directly.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                case .unknown, .denied:
                    Text("NOOP reads your heart rate, HRV, resting heart rate, sleep, steps, energy and VO₂ max from Apple Health to compute your scores. It all stays on this iPhone, and you pick exactly what to share on the next screen.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        // The bridge owns the real request: the type list, the entitlement checks, and
                        // arming continuous live ingestion once granted. We just trigger it.
                        Task { await health.requestAuthorization() }
                    } label: {
                        Label("Allow Apple Health access", systemImage: "heart.fill")
                    }
                    .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                    .accessibilityHint("Shows the Apple Health permission sheet")
                    if health.auth == .denied {
                        Text("If you don't see the prompt, turn NOOP on under Settings › Health › Data Access & Devices.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                case .authorized:
                    Text("You're connected. NOOP is reading your Apple Watch data now. Your Charge score will spend its first week or so calibrating, then settle in.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("You can change what you share any time in Settings › Health › Data Access & Devices.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let err = health.lastError {
                    Text(err)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusCritical)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        // macOS has no HealthKit at all. Be honest: the watch path is an iPhone feature.
        NoopCard(tint: StrandPalette.metricCyan) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "iphone")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.metricCyan)
                        .accessibilityHidden(true)
                    Text("Set this up on your iPhone")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text("Apple Health lives on the iPhone, not the Mac, so connecting your Apple Watch happens there. Open NOOP on your iPhone, head to Settings, and run this same Apple Watch setup. Your scores then show up across your devices.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }
}

#if DEBUG
#Preview("Apple Watch setup") {
    AppleWatchSetupView(onClose: {})
        .preferredColorScheme(.dark)
}
#endif
