import SwiftUI

// Tap outside a field to put the keyboard away.
//
// The Lift Log's entry fields are numeric, so the keyboard has no return key to dismiss with, and
// the only way out was the "Done" toolbar button — which meant the keyboard sat over half the
// workout sheet until you found it. In a gym that is the difference between glancing at your next
// set and fighting the phone.
//
// A `simultaneousGesture` rather than `onTapGesture`, deliberately: a plain tap gesture on a
// container SWALLOWS taps meant for the buttons and rows inside it, which on this screen would eat
// the very controls that advance the session. A simultaneous gesture runs ALONGSIDE the child's own
// handling, so a tap both dismisses the keyboard and does whatever it was aimed at.

extension View {
    /// Clear `focus` when the user taps anywhere in this view that isn't a field.
    func dismissesKeyboardOnTap<Value: Hashable>(_ focus: FocusState<Value?>.Binding) -> some View {
        #if os(iOS)
        self
            .simultaneousGesture(TapGesture().onEnded { focus.wrappedValue = nil })
            // Dragging the sheet also puts it away, which is the gesture most people reach for
            // first when a keyboard is covering what they want to read.
            .scrollDismissesKeyboard(.interactively)
        #else
        // macOS has a hardware keyboard and no on-screen one to dismiss.
        self
        #endif
    }
}
