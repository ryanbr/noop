import SwiftUI
import StrandDesign

/// Backup & Sync (Phase 1 — folder). Apple mirror of the Android `BackupSyncScreen`: pick a folder,
/// turn on daily auto-backup (on-launch catch-up), back up now, or restore. Snapshots are the existing
/// `.noopbak` whole-DB format. Point the folder at Google Drive / iCloud / Dropbox for off-device sync.
struct BackupSyncView: View {
    @EnvironmentObject var model: AppModel

    @State private var auto = FolderBackup.autoEnabled
    @State private var folderLabel = FolderBackup.folderLabel()
    @State private var lastMs = FolderBackup.lastBackupMs
    @State private var busy = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    var body: some View {
        ScreenScaffold(title: "Backup & Sync",
                       subtitle: "Save a full backup to a folder you choose — point it at Google Drive / iCloud / Dropbox for off-device sync.") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                folderCard
                autoCard
                restoreCard
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: { Text(alertMessage) }
    }

    private var folderCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Backup folder").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(folderLabel.map { "Saving to: \($0)" }
                     ?? "No folder chosen yet. Pick one your cloud app already syncs, or any local folder.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tip: choose a folder in iCloud Drive — your backups then sync to all your Apple devices automatically, no account setup needed.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                Button { chooseFolder() } label: {
                    Label(folderLabel == nil ? "Choose folder" : "Change folder", systemImage: "folder")
                }
                .buttonStyle(.bordered).tint(StrandPalette.accent).disabled(busy)
            }
        }
    }

    private var autoCard: some View {
        StrandCard(padding: 20, tint: auto && folderLabel != nil ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily auto-backup").font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Text("Backs up to your folder about once a day (keeps the latest \(FolderBackup.keepCount)). On this platform it runs when you next open NOOP.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("", isOn: $auto)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .disabled(folderLabel == nil)
                        .onChangeCompat(of: auto) { on in FolderBackup.autoEnabled = on }
                }
                Text(lastMs > 0 ? "Last backup: \(relativeTime(lastMs))" : "No backup yet.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                Button { backupNow() } label: {
                    Label(busy ? "Working…" : "Back up now", systemImage: "icloud.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .disabled(folderLabel == nil || busy)
            }
        }
    }

    private var restoreCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Restore").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("Replace this device's data with a chosen backup. This overwrites current data, so back up first if unsure.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { restore() } label: {
                    Label("Restore from a backup…", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered).tint(StrandPalette.accent).disabled(busy)
            }
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        #if os(macOS)
        if FolderBackup.pickFolder() != nil { folderLabel = FolderBackup.folderLabel() }
        #else
        Task { if await FolderBackup.pickFolder() != nil { folderLabel = FolderBackup.folderLabel() } }
        #endif
    }

    private func backupNow() {
        busy = true
        Task {
            let ok = await FolderBackup.backupNow(checkpoint: { await model.repo.checkpointForBackup() })
            lastMs = FolderBackup.lastBackupMs
            busy = false
            alertTitle = ok ? "Backed up" : "Backup problem"
            alertMessage = ok ? "Saved a backup to your folder." : "Backup failed — re-pick the folder and try again."
            showAlert = true
        }
    }

    private func restore() {
        busy = true
        Task {
            let result = await DataBackup.runImport()
            busy = false
            switch result {
            case .cancelled, .exported:
                return
            case .imported:
                alertTitle = "Restored"; alertMessage = "Fully quit and reopen NOOP to load it."; showAlert = true
            case .failure(let m):
                alertTitle = "Restore problem"; alertMessage = m; showAlert = true
            }
        }
    }

    private func relativeTime(_ ms: Int) -> String {
        let f = RelativeDateTimeFormatter()
        return f.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000.0), relativeTo: Date())
    }
}
