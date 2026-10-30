#if os(iOS)
import SwiftUI
import StrandDesign

/// A widget can be installed before hydration tracking is enabled. Keep its default-off opt-in intact.
struct WidgetHydrationLogView: View {
    @AppStorage(HydrationStore.enabledKey) private var enabled = false

    var body: some View {
        if enabled {
            HydrationView()
        } else {
            ScreenScaffold(title: "Hydration") {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    Toggle("Hydration tracking", isOn: $enabled)
                        .font(StrandFont.subhead)
                        .tint(StrandPalette.accent)
                    Text("Adds a fluid log and an effort-adjusted daily goal. Log a sip, cup or bottle to fill your progress ring. Data stays on this device.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }
}
#endif
