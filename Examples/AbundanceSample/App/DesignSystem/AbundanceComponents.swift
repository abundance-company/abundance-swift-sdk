import SwiftUI

/// Full-bleed themed background (surface-page).
public struct AbundanceBackground<Content: View>: View {
    @Environment(\.abundanceTheme) private var theme
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        ZStack {
            theme.surfacePage.ignoresSafeArea()
            content
        }
    }
}

/// Frosted "liquid glass" surface: the real Liquid Glass effect on iOS 26+,
/// a layered ultra-thin material with a hairline rim below.
public struct AbundanceGlass: ViewModifier {
    let cornerRadius: CGFloat

    public func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

public extension View {
    func abundanceGlass(cornerRadius: CGFloat = AbundanceRadius.lg) -> some View {
        modifier(AbundanceGlass(cornerRadius: cornerRadius))
    }

    func abundanceGlassCapsule() -> some View {
        abundanceGlass(cornerRadius: AbundanceRadius.full)
    }
}

/// Card surface — a frosted glass tile.
public struct AbundanceCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .padding(AbundanceSpacing.md)
            .abundanceGlass(cornerRadius: AbundanceRadius.lg)
    }
}

/// Primary (high-contrast) pill button — the hero CTA (`bg-primary` /
/// `text-inverse`, capsule shape per the mobile design pass).
public struct AbundancePrimaryButtonStyle: ButtonStyle {
    @Environment(\.abundanceTheme) private var theme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AbundanceFont.label)
            .foregroundStyle(theme.textInverse)
            .padding(.horizontal, AbundanceSpacing.lg)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(configuration.isPressed ? theme.bgPrimaryHover : theme.bgPrimary)
            .clipShape(Capsule())
            .opacity(isEnabled ? 1 : 0.5)
    }

    @Environment(\.isEnabled) private var isEnabled
}

/// Quiet glass capsule for secondary asks ("Don't see your camera?").
public struct AbundanceQuietButtonStyle: ButtonStyle {
    @Environment(\.abundanceTheme) private var theme

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AbundanceFont.label)
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, AbundanceSpacing.lg)
            .padding(.vertical, AbundanceSpacing.sm)
            .abundanceGlassCapsule()
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Uppercase tracked section label above grouped content.
public struct SectionHeader: View {
    @Environment(\.abundanceTheme) private var theme
    private let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title.uppercased())
            .font(AbundanceFont.label)
            .tracking(1.2)
            .foregroundStyle(theme.textTertiary)
    }
}
