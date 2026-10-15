#if os(iOS)
import SwiftUI
import StrandDesign

struct HomeAssistantSettingsView: View {
    @EnvironmentObject private var repo: Repository
    @AppStorage(HomeAssistantExport.endpointKey) private var endpoint = ""
    @AppStorage(HomeAssistantExport.enabledKey) private var automaticExport = false
    @State private var token = ""
    @State private var hasSavedToken = HomeAssistantExport.hasToken()
    @State private var isWorking = false
    @State private var status: String?
    @State private var statusIsError = false

    var body: some View {
        ScreenScaffold(title: "Home Assistant", subtitle: "Send WHOOP data from NOOP to your own Home Assistant instance.") {
            VStack(spacing: 14) {
                connectionCard
                exportCard
            }
        }
    }

    private var connectionCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Connection", systemImage: "house.fill")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                TextField("https://homeassistant.example.com", text: $endpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                SecureField(hasSavedToken ? "Access token saved in Keychain" : "Long-lived access token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save connection", action: saveConnection)
                        .buttonStyle(.borderedProminent)
                        .tint(StrandPalette.accent)
                    Button("Test connection", action: testConnection)
                        .buttonStyle(.bordered)
                        .disabled(isWorking || !hasSavedToken)
                }
                if hasSavedToken {
                    Button("Remove saved token", role: .destructive) {
                        HomeAssistantExport.clearToken()
                        hasSavedToken = false
                        token = ""
                        status = "Saved token removed from this iPhone."
                        statusIsError = false
                    }
                    .font(StrandFont.caption)
                }
                Text("Create a Home Assistant long-lived access token in your HA profile. The token stays in iOS Keychain. NOOP only writes sensor states; it never reads data or commands from Home Assistant.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status {
                    Text(status).font(StrandFont.caption)
                        .foregroundStyle(statusIsError ? .red : StrandPalette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var exportCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Label("NOOP sensors", systemImage: "waveform.path.ecg")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Toggle(isOn: $automaticExport) {
                    Text("Automatically export after data refresh")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch).tint(StrandPalette.accent)
                .disabled(!hasSavedToken || endpoint.isEmpty)
                Text("Publishes a recent heart-rate sample plus the latest available daily recovery, strain, sleep, HRV, resting heart rate, steps, SpO₂, respiration, skin temperature, and strap battery as sensor entities. Automatic export is off until you turn it on.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: exportNow) {
                    HStack {
                        if isWorking { ProgressView().tint(.white) }
                        Text("Send latest data now")
                    }
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .disabled(isWorking || !hasSavedToken || endpoint.isEmpty)
                Text("Home Assistant's REST state API creates entities such as sensor.noop_recovery. States appear after export and are refreshed on the next enabled export.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func saveConnection() {
        do {
            guard HomeAssistantExport.isValidBaseURL(endpoint) else {
                throw HomeAssistantExport.ExportError.invalidURL
            }
            if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try HomeAssistantExport.saveToken(token)
                token = ""
            } else if !HomeAssistantExport.hasToken() {
                throw HomeAssistantExport.ExportError.missingConfiguration
            }
            hasSavedToken = HomeAssistantExport.hasToken()
            status = "Connection settings saved."
            statusIsError = false
        } catch { show(error) }
    }

    private func testConnection() {
        isWorking = true
        Task {
            do {
                try await HomeAssistantExport.testConnection(baseURL: endpoint)
                status = "Connected to Home Assistant. No health data was sent."
                statusIsError = false
            } catch { show(error) }
            isWorking = false
        }
    }

    private func exportNow() {
        isWorking = true
        Task {
            do {
                let result = try await HomeAssistantExport.exportLatest(repository: repo, baseURL: endpoint)
                status = "Updated \(result.entitiesUpdated) sensor states for \(result.day ?? "the latest day")."
                statusIsError = false
            } catch { show(error) }
            isWorking = false
        }
    }

    private func show(_ error: Error) {
        status = error.localizedDescription
        statusIsError = true
    }
}
#endif
