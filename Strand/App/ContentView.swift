import SwiftUI
import StrandDesign

/// Root — the sidebar shell, with the first-run onboarding/pairing wizard overlaid until complete,
/// and a "What's New" changelog sheet shown automatically after an update.
struct ContentView: View {
    @AppStorage("noop.onboarded") private var onboarded = false
    @AppStorage("noop.lastSeenChangelogVersion") private var lastSeenChangelog = ""
    @AppStorage("noop.acceptedTermsVersion") private var acceptedTerms = ""
    /// Local timestamp of the last terms acceptance — the on-device consent record (version + when).
    @AppStorage("noop.acceptedTermsAt") private var acceptedTermsAt = ""
    @State private var showWhatsNew = false

    var body: some View {
        ZStack {
            RootView()
            if !onboarded {
                OnboardingWizard(onFinished: {
                    onboarded = true
                    // A brand-new user just saw the expectations in onboarding — don't also pop the
                    // changelog at them; mark them current.
                    lastSeenChangelog = AppChangelog.currentVersion
                })
                .transition(.opacity)
                .zIndex(1)
            }
            // Terms acknowledgment gate — over EVERYTHING (before onboarding/pairing/Bluetooth) until
            // the current terms version is accepted; re-appears if the terms materially change.
            if acceptedTerms != Terms.currentVersion {
                TermsGateView(onAccept: {
                    acceptedTermsAt = ISO8601DateFormatter().string(from: Date())
                    acceptedTerms = Terms.currentVersion
                })
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        // Calm easing cubic-bezier(0.22,1,0.36,1) at the README sheet-present duration (~0.42s) for
        // the full-screen onboarding / terms overlays — decelerating, nothing overshoots.
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.42), value: onboarded)
        .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.42), value: acceptedTerms)
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: {
                lastSeenChangelog = AppChangelog.currentVersion
                showWhatsNew = false
            })
        }
        // The Terms gate must stay "over everything" — don't pop What's New on top of it after a
        // combined terms+version update. Gate on terms being current, and re-check when they're
        // accepted (onAppear already fired before acceptance), so What's New shows right after.
        .onAppear {
            showWhatsNewIfDue()
            // Seed the current What's New into the Updates inbox (idempotent per version) so the bell
            // collects it even if the user dismisses the auto sheet.
            UpdateStore.shared.seedWhatsNewIfNeeded()
            // #1659: NOOP is sideloaded on every platform, so nothing else will tell you a release
            // happened. On by default and switchable off - see UpdateAvailability.defaultEnabled.
            //
            // Gated on the SAME condition as showWhatsNewIfDue below, matching the iOS and Android hooks:
            // a default-on check must not reach the network during first run, before the Terms gate has
            // been accepted. (No sideload sentence here - macOS has no seven-day re-sign and no AltStore.)
            if onboarded && acceptedTerms == Terms.currentVersion {
                UpdateWatch.runIfDue(currentVersion: UpdateWatch.installedVersion, sideloadHint: false)
            }
        }
        .onChangeCompat(of: acceptedTerms) { _ in showWhatsNewIfDue() }
    }

    private func showWhatsNewIfDue() {
        // Existing users who updated: their last-seen version is behind the current one.
        if onboarded && acceptedTerms == Terms.currentVersion
            && lastSeenChangelog != AppChangelog.currentVersion {
            showWhatsNew = true
        }
    }
}
