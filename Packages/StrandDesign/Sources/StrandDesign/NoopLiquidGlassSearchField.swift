import SwiftUI

// MARK: - Native Liquid Glass search field
//
// Shared search chrome for every in-app filter/search bar. iOS 26 uses the platform
// `glassEffect` capsule; older supported releases keep a solid elevated pill (not a
// hand-rolled blur stack). Clear control, magnifying-glass glyph, and accessibility
// wiring stay identical across call sites.

/// Full-width rounded search field with native Liquid Glass on iOS 26+.
public struct NoopLiquidGlassSearchField: View {
    @Binding private var text: String
    private let prompt: String
    private let accessibilityPrompt: String
    private var externalFocus: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool

    public init(text: Binding<String>,
                prompt: String,
                accessibilityLabel: String? = nil,
                isFocused: FocusState<Bool>.Binding? = nil) {
        self._text = text
        self.prompt = prompt
        self.accessibilityPrompt = accessibilityLabel ?? prompt
        self.externalFocus = isFocused
    }

    public var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .focused(focusBinding)
                .submitLabel(.search)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
        .nativeLiquidGlassSearchChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityPrompt))
    }

    private var focusBinding: FocusState<Bool>.Binding {
        externalFocus ?? $internalFocus
    }
}

public extension View {
    /// Capsule Liquid Glass search chrome. iOS 26 / watchOS 26 / macOS 26 use interactive
    /// `glassEffect`; older OS versions use the shared elevated pill surface (not ultra-thin material stacks).
    @ViewBuilder
    func nativeLiquidGlassSearchChrome() -> some View {
        if #available(iOS 26.0, macOS 26.0, watchOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.background(
                NoopPanelSurface(cornerRadius: NoopVisualStyle.pillRadius, elevated: false)
            )
        }
    }
}
