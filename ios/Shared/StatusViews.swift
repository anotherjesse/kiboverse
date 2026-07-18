import SwiftUI

/// Presentation colors for `StatusLabel` — a value type, not a hardcoded
/// palette, because the composer sits on adaptive `.ultraThinMaterial` and
/// needs `.secondary`/light-dark colors where the watch/talk-mode surfaces
/// want fixed on-dark whites.
struct StatusStyle: Equatable {
    var rest: Color
    var accent: Color
    var error: Color

    /// Today's watch/talk-mode pixels: fixed white text over OLED black or
    /// the ink vignette.
    static let onDark = StatusStyle(rest: .white.opacity(0.55), accent: .kiboCoralBright, error: .kiboAmber)
    /// The composer, over light-or-dark material.
    static let adaptive = StatusStyle(rest: .secondary, accent: .kiboCoral, error: .kiboAmber)
}

/// Captions join the design system: small, letter-spaced, with the
/// state-carrying token in coral (the count when thoughts are pending).
/// Amber, not red, for attention — red is reserved for destruction.
///
/// Accessibility identifiers, `controlSize`, and font/kerning are pinned
/// per-platform test contracts — callers supply font/kerning; identifiers
/// are applied at the call site.
struct StatusLabel: View {
    let state: CenterState
    var style: StatusStyle
    var font: Font
    var kerning: CGFloat

    var body: some View {
        let content = state.status
        let restColor = state.isError ? style.error : style.rest
        let text: Text
        if let accent = content.accent {
            text = Text(accent).foregroundStyle(style.accent)
                + Text(content.text).foregroundStyle(restColor)
        } else {
            text = Text(content.text).foregroundStyle(restColor)
        }
        return text
            .font(font)
            .kerning(kerning)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: 14)
    }
}

/// The compact coral action button for recovery affordances (Retry a failed
/// turn, jump to Review saved recordings) — near-identical on every device
/// that ships one, so it lives once. `controlSize`, `disabled`, and
/// accessibility identifiers are pinned per-platform test contracts and
/// applied at the call site.
struct CoralActionPill: View {
    let title: String
    let systemImage: String
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .lineLimit(1)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(.kiboCoral)
        .fixedSize()
    }
}
