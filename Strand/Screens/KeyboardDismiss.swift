import SwiftUI
#if os(iOS)
import UIKit
#endif

// Tap outside a field to put the keyboard away.
//
// The Lift Log's entry fields are numeric, so the keyboard has no return key to dismiss with, and
// the only way out was the "Done" toolbar button — which meant the keyboard sat over half the
// workout sheet until you found it. In a gym that is the difference between glancing at your next
// set and fighting the phone.
//
// A tap on ANOTHER FIELD is not a tap outside. The first version cleared focus from a SwiftUI
// `simultaneousGesture` on the whole screen, which also fired for a tap that landed in a field: the
// tapped field took focus and the gesture took it straight back, so moving from the weight to the
// reps took two taps — one to lose the keyboard, one to get it back (gym session, 16 Sep 2026).
// SwiftUI's tap gesture cannot say what it landed on, so the watcher is a UIKit recognizer that
// reads the touched view and stands aside for any text input.
//
// It never swallows a tap: the recognizer runs alongside everything else, so a tap on a button both
// dismisses the keyboard and does whatever it was aimed at — this screen's buttons advance the session.

extension View {
    /// Clear `focus` when the user taps anywhere in this view that isn't a field.
    func dismissesKeyboardOnTap<Value: Hashable>(_ focus: FocusState<Value?>.Binding) -> some View {
        #if os(iOS)
        self
            .background(TapOutsideFields { focus.wrappedValue = nil })
            // Dragging the sheet also puts it away, which is the gesture most people reach for
            // first when a keyboard is covering what they want to read.
            .scrollDismissesKeyboard(.interactively)
        #else
        // macOS has a hardware keyboard and no on-screen one to dismiss.
        self
        #endif
    }
}

#if os(iOS)
/// Reports taps that land in this screen but not in a text input.
///
/// The recognizer is attached to the WINDOW, because SwiftUI gives a background view no reliable
/// place in the hierarchy the touches pass through. Two filters keep it to this screen: a touch in a
/// text input is ignored (the tap is moving focus, not ending it), and so is a touch outside the view
/// controller this view belongs to — a sheet presented on top has its own fields and its own watcher.
private struct TapOutsideFields: UIViewRepresentable {
    let onTap: () -> Void

    func makeUIView(context: Context) -> Probe {
        let probe = Probe()
        probe.onTap = onTap
        return probe
    }

    func updateUIView(_ probe: Probe, context: Context) {
        probe.onTap = onTap
    }

    static func dismantleUIView(_ probe: Probe, coordinator: ()) {
        probe.detach()
    }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        var onTap: () -> Void = {}
        private var recognizer: UITapGestureRecognizer?

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Present only to find the window; it must not take part in hit-testing itself.
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            guard let window else { return }
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            window.addGestureRecognizer(tap)
            recognizer = tap
        }

        func detach() {
            if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }

        @objc private func tapped() { onTap() }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard let touched = touch.view else { return false }
            let ancestors = sequence(first: touched, next: { $0.superview })
            if ancestors.contains(where: { $0 is UITextInput }) { return false }
            guard let screen = owningController?.view else { return false }
            return touched.isDescendant(of: screen)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// The nearest view controller up the responder chain — the sheet or screen hosting this view.
        private var owningController: UIViewController? {
            sequence(first: self as UIResponder, next: { $0.next })
                .first { $0 is UIViewController } as? UIViewController
        }
    }
}
#endif
