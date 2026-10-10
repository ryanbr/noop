#if os(iOS)
import SwiftUI
import WhoopStore
import StrandDesign
import UserNotifications

struct TrainingFavoritesView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var training: TrainingCoordinator
    @State private var favorites = TrainingFavorite.load()
    @State private var programs: [LiftProgramRow] = []
    @State private var error: String?
    var body: some View {
        SettingsSection(icon: "figure.run", title: "Training favorites",
                        blurb: "Choose three workouts or Lift Log programs for your widgets.") {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                ForEach(favorites.indices, id: \.self) { index in
                    TextField("Favorite name", text: $favorites[index].name)
                        .font(StrandFont.body)
                    Picker("Favorite \(index + 1)", selection: selection(index)) {
                        Text("Unassigned").tag("")
                        ForEach(WorkoutCatalog.all) { sport in
                            Text(TrainingCoordinator.sportTitle(sport.name)).tag("sport:\(sport.name)")
                        }
                        ForEach(programs, id: \.id) { program in
                            Text(program.name).tag("program:\(program.id)")
                        }
                        if let id = favorites[index].programID, !programs.contains(where: { $0.id == id }) {
                            Text("Program unavailable").tag("program:\(id)")
                        }
                    }
                    if index < 2 { Divider() }
                }
                Button("Enable training reminders") {
                    Task {
                        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
                        catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.noopSecondary)
                Text("After the first live pulse, ten minutes without new measurements pauses training while the sensor is connected. Training continues when the sensor disconnects.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                if let error { Text(error).font(StrandFont.footnote).foregroundStyle(StrandPalette.metricAmber) }
            }
        }
        .onChange(of: favorites) { _, values in
            TrainingFavorite.save(values)
            training.publish()
        }
        .task {
            do {
                guard let store = await repo.storeHandle() else { return }
                programs = try await store.liftPrograms(deviceId: repo.deviceId)
            } catch { self.error = error.localizedDescription }
        }
    }
    private func selection(_ index: Int) -> Binding<String> {
        Binding(get: {
            if let id = favorites[index].programID { return "program:\(id)" }
            return favorites[index].sport.map { "sport:\($0)" } ?? ""
        }, set: { value in
            favorites[index].sport = value.hasPrefix("sport:") ? String(value.dropFirst(6)) : nil
            favorites[index].programID = value.hasPrefix("program:") ? String(value.dropFirst(8)) : nil
            if let id = favorites[index].programID, favorites[index].name.isEmpty {
                favorites[index].name = programs.first { $0.id == id }?.name ?? ""
            }
        })
    }
}
struct TrainingNotificationConfirmation: ViewModifier {
    @ObservedObject var training: TrainingCoordinator
    func body(content: Content) -> some View {
        content.alert("Still training?", isPresented: Binding(
            get: { training.foregroundPulseLoss != nil },
            set: { if !$0 { training.foregroundPulseLoss = nil } })) {
            if let session = training.foregroundPulseLoss {
                Button("Resume") { Task { try? await training.perform("resume", id: session.id) } }
                Button("End training") {
                    Task {
                        try? await training.perform("requestEnd", id: session.id)
                        training.foregroundConfirmation = TrainingSnapshot.load().sessions.first { $0.id == session.id }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("No live heart rate for ten minutes. Check your training or resume it.") }
        .alert("Really end training?", isPresented: Binding(
            get: { training.foregroundConfirmation != nil },
            set: { if !$0 { training.foregroundConfirmation = nil } })) {
            if let session = training.foregroundConfirmation {
                Button("Yes, end training", role: .destructive) {
                    Task {
                        do { try await training.perform("confirmEnd", id: session.id, token: session.confirmationToken ?? "") }
                        catch { training.foregroundError = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) { Task { try? await training.perform("cancelEnd", id: session.id) } }
            }
        } message: {
            if training.foregroundConfirmation?.kind == "lift" { Text("Only completed sets will be saved.") }
        }
        .alert("Training could not be saved", isPresented: Binding(
            get: { training.foregroundError != nil }, set: { if !$0 { training.foregroundError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text("Your paused training is still available. Please try again.") }
    }
}
#endif
