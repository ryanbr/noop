import SwiftUI
import StrandDesign

/// The "Use Apple on-device AI" switch, shown on the Coach setup card and in
/// Coach settings. While it is on, the coach needs no key and the bring-your-own-model fields are hidden.
struct AppleOnDeviceToggleRow: View {
    @EnvironmentObject var coach: AICoachEngine
    @Environment(\.scenePhase) private var scenePhase

    /// Re-read on return to the app: Apple Intelligence may have been turned on in Settings meanwhile.
    @State private var status = AppleOnDeviceAI.status

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "apple.intelligence")
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use Apple on-device AI")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text("No key and no network: your question and data stay on this device.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $coach.appleOnDevice)
                    .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                    .accessibilityLabel("Use Apple on-device AI")
                    // It can always be switched off, but on only once the model is there: otherwise
                    // the coach would count as set up and every request would fail.
                    .disabled(!coach.appleOnDevice && status != .available)
            }
            if status != .available {
                Text(LocalizedStringKey(AppleOnDeviceAI.message(for: status)))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if coach.appleOnDevice && !coach.dataConsent {
                Text("Turn on \"Let the coach use my data\" in Coach settings so it can read your numbers. With Apple's model they stay on this device.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { status = AppleOnDeviceAI.status }
        .onChange(of: scenePhase) { phase in
            if phase == .active { status = AppleOnDeviceAI.status }
        }
    }
}
