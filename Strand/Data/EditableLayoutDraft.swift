import SwiftUI

/// Reusable value state for reversible layout editing. Items live in exactly one section: shown or hidden.
/// Hidden items are never deleted and return at the end of Shown when restored.
struct EditableLayoutDraft<Item: Identifiable & Equatable>: Equatable {
    var visible: [Item]
    var hidden: [Item]

    init(visible: [Item], allItems: [Item]) {
        self.visible = visible
        hidden = allItems.filter { !visible.contains($0) }
    }

    init(visible: [Item], hidden: [Item]) {
        self.visible = visible
        self.hidden = hidden
    }

    mutating func moveVisible(from offsets: IndexSet, to destination: Int) {
        visible.move(fromOffsets: offsets, toOffset: destination)
    }

    mutating func hide(_ item: Item) {
        guard visible.count > 1, let index = visible.firstIndex(of: item) else { return }
        hidden.append(visible.remove(at: index))
    }

    mutating func show(_ item: Item) {
        guard let index = hidden.firstIndex(of: item) else { return }
        visible.append(hidden.remove(at: index))
    }
}
