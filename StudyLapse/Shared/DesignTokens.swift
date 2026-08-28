import SwiftUI

/// Design tokens from docs/UI.md's "Design tokens" section — the single
/// source of truth every screen restyled in Phase 8 pulls from, so a later
/// palette tweak only touches this file. Dark-only, "cold ink" direction:
/// navy-black surfaces, one desaturated icy-blue accent reserved for
/// actionable elements so it never competes with the (unchanged) red
/// recording indicator.
enum DesignTokens {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    static let cornerRadius: CGFloat = 14
}

extension Color {
    /// `#RRGGBB` or `#RRGGBBAA`. Malformed input renders as opaque black
    /// rather than crashing — every call site here uses a literal hex
    /// constant, so this only ever fires on a `Tag.colorHex` value that
    /// somehow didn't come from `TagCatalog.palette`.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: UInt64
        switch s.count {
        case 8: (r, g, b, a) = ((value >> 24) & 0xFF, (value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
        default: (r, g, b, a) = ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF, 0xFF)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }

    static let slBackground = Color(hex: "#0A0D13")
    static let slSurface = Color(hex: "#12161F")
    static let slSurface2 = Color(hex: "#1A2029")
    static let slTextPrimary = Color(hex: "#EDEFF4")
    static let slTextSecondary = Color(hex: "#7D8494")
    static let slAccent = Color(hex: "#6FA3D9")
    static let slRecording = Color(hex: "#FF3B30")
    /// Errors (failed save, permission denied, …) — distinct from the
    /// recording indicator, which docs/UI.md reserves for recording state only.
    static let slError = Color(hex: "#E5726B")
    static let slWarning = Color(hex: "#E5B15C")
}

/// Applies the app's background + tint consistently. Each top-level screen
/// wraps its content in this rather than repeating the same three modifiers.
struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .tint(Color.slAccent)
            .background(Color.slBackground.ignoresSafeArea())
    }
}

/// `List`/`Form` default to the system grouped background; this swaps in the
/// token surfaces so grouped screens (Export, Voiceover's take list,
/// Library's detail sheet, Stats) match the rest of the app.
struct TokenizedListStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Color.slBackground.ignoresSafeArea())
            .tint(Color.slAccent)
    }
}

extension View {
    func screenBackground() -> some View { modifier(ScreenBackground()) }
    func tokenizedListStyle() -> some View { modifier(TokenizedListStyle()) }
}

/// A colored capsule for a tag name, used anywhere a range/session shows its
/// tags (Tagging segment list, Tagging slider, Library grid). `color`
/// defaults to the plain accent; callers that have a `ModelContext` pass the
/// tag's stored `colorHex` (`TagCatalog.palette`, via the `tagColor(_:in:)`
/// helper) through `TagChipRow.colorFor` so the same tag reads the same
/// color everywhere.
struct TagChip: View {
    let name: String
    var color: Color = .slAccent

    var body: some View {
        Text(name)
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.slTextPrimary)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.38)))
            .overlay(Capsule().stroke(color.opacity(0.7), lineWidth: 1))
    }
}

/// Designed empty state for a fresh install with no data yet (docs/UI.md
/// "Empty states"), shared by Library (no sessions) and Stats (no data).
/// Deliberately not `ContentUnavailableView` — that renders in system colors,
/// and this phase's whole point is no leftover system-default styling.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Color.slAccent)
                .frame(width: 84, height: 84)
                .background(Circle().fill(Color.slSurface2))
            VStack(spacing: DesignTokens.Spacing.xs) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.slTextPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.slTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(DesignTokens.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.slBackground)
        .accessibilityElement(children: .combine)
    }
}

/// Row of `TagChip`s, horizontally scrollable so a many-tag range doesn't
/// wrap awkwardly inside a list row.
struct TagChipRow: View {
    let names: [String]
    let colorFor: (String) -> Color

    init(names: [String], colorFor: @escaping (String) -> Color = { _ in .slAccent }) {
        self.names = names
        self.colorFor = colorFor
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignTokens.Spacing.xs + 2) {
                ForEach(names, id: \.self) { name in
                    TagChip(name: name, color: colorFor(name))
                }
            }
        }
    }
}
