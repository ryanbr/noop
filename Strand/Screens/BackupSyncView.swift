import SwiftUI
import StrandDesign

/// Backup & Sync (folder destination). The Apple mirror of the Android `BackupSyncScreen`: pick a
/// folder, turn on daily auto-backup (an on-launch catch-up), back up now, or restore from a snapshot
/// already in that folder. Snapshots are the existing `.noopbak` whole-DB format. Point the folder at
/// Google Drive / iCloud / Dropbox for off-device sync with no in-app cloud account.
struct BackupSyncView: View {
    @EnvironmentObject var model: AppModel

    @State private var auto = FolderBackup.autoEnabled
    @State private var folderLabel = FolderBackup.folderLabel()
    @State private var lastMs = FolderBackup.lastBackupMs
    @State private var keep = FolderBackup.keepCount
    @State private var busy = false

    // Result alert (backup outcome / restore outcome).
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    // Restore-from-folder flow (must-fix #1 + #2): a sheet lists the folder's snapshots; choosing one
    // arms a destructive confirmation; only confirming runs the overwrite.
    @State private var showRestoreSheet = false
    @State private var snapshots: [FolderBackup.Snapshot] = []
    @State private var pendingRestore: FolderBackup.Snapshot?
    @State private var confirmRestore = false

    var body: some View {
        ScreenScaffold(
            title: "Backup & Sync",
            subtitle: "Save a full backup to a folder you choose - point it at Google Drive, iCloud or Dropbox for off-device sync."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                folderCard
                autoCard
                restoreCard
            }
        }
        // Result of a backup or a restore.
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: { Text(alertMessage) }
        // Pick which snapshot to restore - the folder's own snapshots, newest first (must-fix #1).
        .sheet(isPresented: $showRestoreSheet) {
            RestorePickerSheet(snapshots: snapshots) { chosen in
                showRestoreSheet = false
                pendingRestore = chosen
                if chosen != nil { confirmRestore = true }
            }
        }
        // Explicit in-app destructive confirmation BEFORE any overwrite (must-fix #2).
        .alert("Restore this backup?", isPresented: $confirmRestore, presenting: pendingRestore) { snap in
            Button("Replace all data", role: .destructive) { runRestore(snap) }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: { snap in
            // A hand-named file with no resolved date (timeMs 0) confirms by NAME, not "1 Jan 1970".
            Text(snap.timeMs > 0
                ? "Replace all current data with the backup from \(absoluteTime(snap.timeMs))? This cannot be undone."
                : "Replace all current data with the backup \(snap.name)? This cannot be undone.")
        }
    }

    // MARK: - Cards

    private var folderCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Backup folder")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(folderLabel.map { String(localized: "Saving to: \($0)") }
                     ?? String(localized: "No folder chosen yet. Pick one your cloud app already syncs, or any local folder."))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tip: choose a folder in iCloud Drive and your backups sync to all your Apple devices automatically, no account setup needed.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                    .fixedSize(horizontal: false, vertical: true)
                // #644: these .noopbak snapshots are a plain, unencrypted ZIP — pointing this folder at
                // a cloud sync app (per the tip above) also uploads that readable file there. Say so
                // plainly next to the folder picker, before anyone turns auto-backup on.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(StrandPalette.statusWarning)
                        .font(.system(size: 12))
                        .accessibilityHidden(true)
                    Text("These backups are unencrypted too. If this folder syncs to Drive, Dropbox or iCloud, the readable file goes there as well — only point it at a service you trust.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NoopButton(folderLabel == nil ? "Choose folder" : "Change folder",
                           systemImage: "folder", kind: .secondary) { chooseFolder() }
                    .disabled(busy)
                #if os(iOS)
                // #52: some iOS 26 users can't select a folder in the system picker (its "Open" button
                // never fires). This backs up inside NOOP's own Files-visible folder instead — no picker.
                if !FolderBackup.useInternalFolder {
                    NoopButton("Use NOOP's own folder (browse in Files)",
                               systemImage: "iphone", kind: .tertiary) { useNoopFolder() }
                        .disabled(busy)
                }
                #endif
            }
        }
    }

    private var autoCard: some View {
        StrandCard(padding: 20, tint: auto && folderLabel != nil ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Daily auto-backup")
                            .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Text("Backs up to your folder about once a day and keeps the latest \(keep). On this platform it runs when you next open NOOP.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Toggle("Daily auto-backup", isOn: $auto)
                        .labelsHidden().toggleStyle(.switch).tint(StrandPalette.accent)
                        .disabled(folderLabel == nil)
                        .onChangeCompat(of: auto) { on in FolderBackup.autoEnabled = on }
                }
                // Retention: how many dated snapshots to keep. Wired to FolderBackup.keepCount; the next
                // backup prunes the oldest beyond this count (BackupSync.snapshotsToPrune, unchanged).
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep last snapshots")
                            .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        Text("Older backups beyond this many are pruned, oldest first (≈ that many days). If data ever corrupts, restore the newest.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Picker("Keep last snapshots", selection: $keep) {
                        ForEach(FolderBackup.keepOptions, id: \.self) { n in Text("\(n)").tag(n) }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(StrandPalette.accent)
                    .onChangeCompat(of: keep) { n in FolderBackup.keepCount = n }
                }
                Text(lastMs > 0 ? "Last backup: \(relativeTime(lastMs))" : "No backup yet.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                NoopButton(busy ? "Working…" : "Back up now",
                           systemImage: "icloud.and.arrow.up", kind: .primary, fullWidth: true) { backupNow() }
                    .disabled(folderLabel == nil || busy)
            }
        }
    }

    private var restoreCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Restore")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("Replace this device's data with one of the backups in your folder. This overwrites current data, so back up first if you're unsure.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton("Restore from a backup…", systemImage: "arrow.uturn.backward", kind: .secondary) {
                    openRestorePicker()
                }
                .disabled(folderLabel == nil || busy)
            }
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        #if os(macOS)
        if FolderBackup.pickFolder() != nil { folderLabel = FolderBackup.folderLabel() }
        #else
        // #1000a: on iOS the folder picker has reportedly refused to enable its Select button, leaving
        // the user with only Cancel and NOOP silently doing nothing. We can't tell a deliberate Cancel
        // apart from that dead-button dead-end (both come back nil), so when no folder arrives we show
        // the screen's normal result alert with a concrete workaround instead of staying silent. Mildly
        // chatty on a genuine Cancel; honest and actionable when the picker is actually broken.
        // `busy` guards against a double-tap stacking a second picker presentation on top of the first.
        busy = true
        Task {
            let picked = await FolderBackup.pickFolder()
            busy = false
            if picked != nil {
                folderLabel = FolderBackup.folderLabel()
            } else if !FolderBackup.useInternalFolder {
                // Only nag when there's no working destination. If the internal fallback is already
                // active, a cancelled picker changed nothing — and the button the message points at is
                // hidden, so alerting here would send the user chasing a control that isn't shown.
                alertTitle = String(localized: "No folder selected")
                alertMessage = String(localized: "NOOP didn't get a folder back from the picker. If the Open button won't do anything, tap \"Use NOOP's own folder\" below to back up inside NOOP instead — you can read those backups from the Files app.")
                showAlert = true
            }
        }
        #endif
    }

    #if os(iOS)
    // #52: picker-free fallback. Back up inside NOOP's own Files-visible folder (On My iPhone → NOOP →
    // Backups). No folder picker, no security-scoped bookmark — works even where the picker won't select.
    private func useNoopFolder() {
        FolderBackup.useNoopFolder()
        folderLabel = FolderBackup.folderLabel()
        alertTitle = String(localized: "Using NOOP's folder")
        alertMessage = String(localized: "Backups will be saved inside NOOP. Open the Files app → On My iPhone → NOOP → Backups to see them, or drag that folder into iCloud Drive to read it on your Mac. To use a different folder later, tap Change folder.")
        showAlert = true
    }
    #endif

    private func backupNow() {
        busy = true
        Task {
            let ok = await FolderBackup.backupNow(checkpoint: { await model.repo.checkpointForBackup() })
            await MainActor.run {
                lastMs = FolderBackup.lastBackupMs
                busy = false
                alertTitle = ok ? String(localized: "Backed up") : String(localized: "Backup problem")
                alertMessage = ok
                    ? String(localized: "Saved a backup to your folder.")
                    : String(localized: "Backup failed - re-pick the folder and try again.")
                showAlert = true
            }
        }
    }

    private func openRestorePicker() {
        snapshots = FolderBackup.listSnapshots()
        if snapshots.isEmpty {
            alertTitle = String(localized: "No backups found")
            alertMessage = String(localized: "There are no NOOP backups in your folder yet. Use Back up now first.")
            showAlert = true
        } else {
            showRestoreSheet = true
        }
    }

    private func runRestore(_ snap: FolderBackup.Snapshot) {
        pendingRestore = nil
        busy = true
        Task {
            // The restore is synchronous file I/O; run it off the main actor so the UI stays responsive
            // for a large store, then report on the main actor.
            let result = await Task.detached(priority: .userInitiated) {
                FolderBackup.restore(snapshotNamed: snap.name)
            }.value
            await MainActor.run {
                busy = false
                switch result {
                case .imported:
                    alertTitle = String(localized: "Restored")
                    alertMessage = String(localized: "Fully quit and reopen NOOP to load it.")
                case .failure(let m):
                    alertTitle = String(localized: "Restore problem"); alertMessage = m
                case .cancelled, .exported:
                    alertTitle = String(localized: "Restore problem"); alertMessage = String(localized: "Couldn't restore that backup.")
                }
                showAlert = true
            }
        }
    }

    // MARK: - Formatting

    private func relativeTime(_ ms: Int) -> String {
        let f = RelativeDateTimeFormatter()
        return f.localizedString(for: Date(timeIntervalSince1970: Double(ms) / 1000.0), relativeTo: Date())
    }

    private func absoluteTime(_ ms: Int) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }
}

/// The snapshot chooser shown before a restore (must-fix #1: pick from the folder, newest first).
/// Reports the chosen snapshot (or nil if dismissed) back to the host, which then arms the destructive
/// confirmation.
private struct RestorePickerSheet: View {
    let snapshots: [FolderBackup.Snapshot]
    let onChoose: (FolderBackup.Snapshot?) -> Void

    var body: some View {
        NavigationStack {
            List(snapshots) { snap in
                Button { onChoose(snap) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            // A hand-named file whose date lookup failed has timeMs 0; show its name as the
                            // primary line rather than "1 Jan 1970". The filename subtitle then only repeats
                            // when we DO have a real date to head the row.
                            Text(primaryLabel(snap))
                                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            if snap.timeMs > 0 {
                                Text(snap.name)
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .accessibilityLabel(accessibilityLabel(snap))
            }
            .navigationTitle("Choose a backup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onChoose(nil) }
                }
            }
        }
    }

    /// The row's headline: a friendly date when we resolved one, else the filename (never the epoch date).
    private func primaryLabel(_ snap: FolderBackup.Snapshot) -> String {
        snap.timeMs > 0 ? absoluteTime(snap.timeMs) : snap.name
    }

    /// VoiceOver label: reads the resolved date when we have one, else the filename (no epoch date).
    private func accessibilityLabel(_ snap: FolderBackup.Snapshot) -> String {
        snap.timeMs > 0 ? String(localized: "Restore backup from \(absoluteTime(snap.timeMs))")
                        : String(localized: "Restore backup \(snap.name)")
    }

    private func absoluteTime(_ ms: Int) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000.0))
    }
}
