import SwiftUI
import StrandDesign

/// The "Use Apple on-device AI" switch, shown on the Coach setup card and in
/// Coach settings. While it is on, the coach needs no key and the bring-your-own-model fields are hidden.
struct AppleOnDeviceToggleRow: View {
    @EnvironmentObject var coach: AICoachEngine

    var body: some View {
        let status = AppleOnDeviceAI.status
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
            }
            if status != .available {
                Text(AppleOnDeviceAI.message(for: status))
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
    }
}
