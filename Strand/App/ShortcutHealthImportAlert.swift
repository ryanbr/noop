import SwiftUI

struct ShortcutHealthImportAlert: ViewModifier {
    let model: AppModel
    @State private var pending: ShortcutHealthImport.PendingImport?

    private var isPresented: Binding<Bool> {
        Binding(get: { pending != nil }, set: { showing in
            if !showing { model.cancelPendingHealthImport() }
        })
    }

    func body(content: Content) -> some View {
        content
            .onReceive(model.$pendingShortcutHealthImport.removeDuplicates()) { pending = $0 }
            .alert("Import Apple Health data?", isPresented: isPresented) {
                Button("Import") { model.confirmPendingHealthImport() }
                Button("Cancel", role: .cancel) { model.cancelPendingHealthImport() }
            } message: {
                if let pending {
                    Text("A Shortcut wants to add \(pending.daysCount) days and \(pending.workoutsCount) workouts to the Apple Health import source.")
                } else {
                    Text("A Shortcut wants to add data to the Apple Health import source.")
                }
            }
    }
}
