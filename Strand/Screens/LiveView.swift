import SwiftUI
import AppKit
import StrandDesign
import WhoopProtocol

/// Live — the connected strap in real time. Built on the shared design system
/// (ScreenScaffold chrome, StrandPalette, StrandFont) so it lines up pixel-for-pixel
/// with every other screen instead of the old standalone Milestone-1 layout.
struct LiveView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState

    /// Which strap the user is pairing — persists across launches. Drives which
    /// BLE service we scan for so a WHOOP 4.0 scan never hangs on a WHOOP 5 wrist.
    @AppStorage("selectedWhoopModel") private var selectedModelRaw = WhoopModel.whoop4.rawValue
    private var selectedModel: WhoopModel { WhoopModel(rawValue: selectedModelRaw) ?? .whoop4 }

    /// Smoothed, spike-filtered live HR from AppModel (median over a short window).
    private var displayHR: Int? { model.bpm }
    private var activeConnection: Bool { live.connected && live.bonded }

    var body: some View {
        ScreenScaffold(title: "Live",
                       subtitle: "Your strap in real time — heart rate and frames as they arrive.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                connectionRow
                // Bond-refused guidance, shown right here on Live where people actually connect (it
                // also appears in Settings). A 5/MG strap still bonded to the WHOOP app refuses pairing
                // with "Encryption is insufficient" — this tells the user to free it and re-pair.
                if let hint = live.pairingHint { pairingHintBanner(hint) }
                heartRateCard
                statusGrid
                // Show the strap picker whenever we're not actively streaming, so a user with both a
                // WHOOP 4 and a 5/MG can switch between them. (It used to hide once `bonded`, which is
                // sticky across disconnects — so after the first pairing the picker vanished for good.)
                if !activeConnection { modelPicker }
                controls
                logCard
            }
        }
        .onAppear { refreshLiveSession() }
        .onDisappear { model.stopRealtimeHR() }
        .onChange(of: live.bonded) { _ in refreshLiveSession() }
        .onChange(of: live.connected) { _ in refreshLiveSession() }
    }

    // MARK: - Connection

    private var connectionRow: some View {
        HStack {
            connectionPill
            Spacer()
        }
    }

    private var connectionPill: some View {
        let (label, color): (String, Color) =
            activeConnection ? ("Streaming", StrandPalette.accent)
            : live.connected ? ("Connected", StrandPalette.statusWarning)
            : live.bonded ? ("Paired · idle", StrandPalette.statusWarning)
            : ("Disconnected", StrandPalette.metricRose)
        return HStack(spacing: 8) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(StrandPalette.surfaceRaised, in: Capsule())
    }

    // MARK: - Heart rate

    private var heartRateCard: some View {
        NoopCard {
            VStack(spacing: 6) {
                Text("HEART RATE").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(displayHR.map(String.init) ?? "—")
                    .font(.system(size: 96, weight: .semibold).monospacedDigit())
                    .foregroundStyle(displayHR == nil ? StrandPalette.textTertiary : StrandPalette.accent)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: displayHR)
                Text("bpm").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                if !live.rr.isEmpty {
                    Text("R-R: " + live.rr.suffix(4).map(String.init).joined(separator: " · ") + " ms")
                        .font(StrandFont.mono).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
        }
    }

    // MARK: - Status tiles

    private var statusGrid: some View {
        HStack(spacing: NoopMetrics.gap) {
            stat("Battery", live.batteryPct.map { "\(Int($0))%" } ?? "—")
            stat("Last frame", live.lastFrameType ?? "—")
            stat("Last event", live.lastEvent ?? "—")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(title.uppercased()).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(value).font(StrandFont.headline).monospacedDigit()
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pairingHintBanner(_ hint: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Live HR works — free the strap to unlock buzz, alarms & sync")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text(hint)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(StrandPalette.statusWarning.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pairing help: \(hint)")
    }

    // MARK: - Strap picker

    /// Pick the strap family to scan for. Switching the selection drops the current strap's bond so the
    /// newly-picked one connects fresh — letting a user move between a WHOOP 4 and a 5/MG.
    private var modelPicker: some View {
        HStack(spacing: 10) {
            Text("Strap").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            SegmentedPillControl(
                WhoopModel.allCases,
                selection: Binding(
                    get: { selectedModel },
                    set: { newModel in
                        guard newModel.rawValue != selectedModelRaw else { return }
                        selectedModelRaw = newModel.rawValue
                        // Clear the previous strap's sticky bond/connection so the next scan targets the
                        // new family's service and bonds it fresh.
                        model.prepareStrapSwitch()
                    }
                ),
                label: { $0.displayName }
            )
            Spacer()
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button { model.scan(model: selectedModel) } label: {
                Label(live.connected ? "Re-scan" : "Scan & Connect",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).tint(StrandPalette.accent)

            Button { model.buzz() } label: {
                Label("Buzz strap", systemImage: "waveform.path")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.bordered).tint(StrandPalette.accent)
            .disabled(!activeConnection)
            .help("Fire a test haptic buzz on the strap (requires an active strap connection)")

            Button(role: .destructive) { model.disconnect() } label: {
                Label("Disconnect", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .disabled(!live.connected)
        }
    }

    private func refreshLiveSession() {
        guard activeConnection else { return }
        model.startRealtimeHR()
        model.getBattery()
    }

    // MARK: - Strap log

    private var logCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text("STRAP LOG").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    // Export the log so people can attach it to a bug report (issue #17 — macOS users
                    // had no way to share it). Copy → clipboard; Save… → a .txt file.
                    Button("Copy") { copyStrapLog() }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                    Button("Save…") { saveStrapLog() }
                        .buttonStyle(.plain).font(StrandFont.mono).foregroundStyle(StrandPalette.accent)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(live.log.enumerated()), id: \.offset) { idx, line in
                                Text(line).font(StrandFont.mono)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                    }
                    .frame(height: 200)
                    .onChange(of: live.log.count) { _ in
                        if let last = live.log.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    // MARK: - Strap-log export (issue #17 — let macOS users share the log for bug reports)

    private func strapLogText() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let header = "NOOP strap log — macOS\nApp: \(v)\nmacOS: "
            + ProcessInfo.processInfo.operatingSystemVersionString + "\n"
            + String(repeating: "-", count: 40) + "\n"
        return header + live.log.joined(separator: "\n")
    }

    private func copyStrapLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(strapLogText(), forType: .string)
    }

    private func saveStrapLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "noop-strap-log.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? strapLogText().write(to: url, atomically: true, encoding: .utf8)
    }
}
