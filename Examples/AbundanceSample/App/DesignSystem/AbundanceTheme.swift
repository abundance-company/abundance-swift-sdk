import SwiftUI

/// Semantic color tokens resolved for a theme, ported verbatim from the canonical
/// Abundance design system. Use these in app code, not the raw `AbundancePalette`.
/// The product UI is dark-first; both themes are provided.
public struct AbundanceTheme: Sendable {
    // Surfaces
    public let surfacePage: Color
    public let surfaceDefault: Color
    public let surfaceCard: Color
    public let surfaceOverlay: Color
    // Backgrounds (interactive / fills)
    public let bgPrimary: Color
    public let bgPrimaryHover: Color
    public let bgSecondary: Color
    public let bgTertiary: Color
    public let bgAccentOcean: Color
    public let bgAccentSubtle: Color
    public let bgInput: Color
    public let bgDisabled: Color
    public let bgDanger: Color
    public let bgRecord: Color
    public let bgWarning: Color
    // Text
    public let textPrimary: Color
    public let textSecondary: Color
    public let textTertiary: Color
    public let textInverse: Color
    public let textDisabled: Color
    public let textAccentOcean: Color
    public let textDanger: Color
    public let textWarning: Color
    // Border
    public let borderSubtle: Color
    public let borderBold: Color
    public let borderInput: Color
    public let borderAccentOcean: Color
    public let borderDanger: Color
    // Icon
    public let iconPrimary: Color
    public let iconSecondary: Color
    public let iconTertiary: Color
    public let iconDanger: Color
    public let iconWarning: Color

    public static let dark = AbundanceTheme(
        surfacePage: AbundancePalette.neutral950,
        surfaceDefault: AbundancePalette.neutral900,
        surfaceCard: AbundancePalette.neutral800,
        surfaceOverlay: AbundancePalette.neutral700,
        bgPrimary: AbundancePalette.neutral50,
        bgPrimaryHover: AbundancePalette.neutral100,
        bgSecondary: AbundancePalette.neutral400,
        bgTertiary: AbundancePalette.neutral0,
        bgAccentOcean: AbundancePalette.ocean500,
        bgAccentSubtle: AbundancePalette.neutral700,
        bgInput: AbundancePalette.neutral50,
        bgDisabled: AbundancePalette.neutral800,
        bgDanger: AbundancePalette.red900,
        bgRecord: AbundancePalette.red400,
        bgWarning: AbundancePalette.yellow900,
        textPrimary: AbundancePalette.neutral50,
        textSecondary: AbundancePalette.neutral200,
        textTertiary: AbundancePalette.neutral400,
        textInverse: AbundancePalette.neutral900,
        textDisabled: AbundancePalette.neutral500,
        textAccentOcean: AbundancePalette.ocean300,
        textDanger: AbundancePalette.red400,
        textWarning: AbundancePalette.yellow300,
        borderSubtle: AbundancePalette.neutral600,
        borderBold: AbundancePalette.neutral400,
        borderInput: AbundancePalette.neutral450,
        borderAccentOcean: AbundancePalette.ocean400,
        borderDanger: AbundancePalette.red400,
        iconPrimary: AbundancePalette.neutral50,
        iconSecondary: AbundancePalette.neutral200,
        iconTertiary: AbundancePalette.neutral400,
        iconDanger: AbundancePalette.red400,
        iconWarning: AbundancePalette.yellow400
    )

    public static let light = AbundanceTheme(
        surfacePage: AbundancePalette.neutral150,
        surfaceDefault: AbundancePalette.neutral100,
        surfaceCard: AbundancePalette.neutral50,
        surfaceOverlay: .white,
        bgPrimary: AbundancePalette.neutral900,
        bgPrimaryHover: AbundancePalette.neutral800,
        bgSecondary: AbundancePalette.neutral400,
        bgTertiary: AbundancePalette.neutral0,
        bgAccentOcean: AbundancePalette.ocean500,
        bgAccentSubtle: AbundancePalette.neutral200,
        bgInput: AbundancePalette.neutral200,
        bgDisabled: AbundancePalette.neutral200,
        bgDanger: AbundancePalette.red100,
        bgRecord: AbundancePalette.red500,
        bgWarning: AbundancePalette.yellow100,
        textPrimary: AbundancePalette.neutral950,
        textSecondary: AbundancePalette.neutral800,
        textTertiary: AbundancePalette.neutral500,
        textInverse: AbundancePalette.neutral50,
        textDisabled: AbundancePalette.neutral500,
        textAccentOcean: AbundancePalette.ocean500,
        textDanger: AbundancePalette.red600,
        textWarning: AbundancePalette.yellow800,
        borderSubtle: AbundancePalette.neutral300,
        borderBold: AbundancePalette.neutral700,
        borderInput: AbundancePalette.neutral450,
        borderAccentOcean: AbundancePalette.ocean500,
        borderDanger: AbundancePalette.red700,
        iconPrimary: AbundancePalette.neutral950,
        iconSecondary: AbundancePalette.neutral800,
        iconTertiary: AbundancePalette.neutral500,
        iconDanger: AbundancePalette.red600,
        iconWarning: AbundancePalette.yellow700
    )

    public static func resolve(_ scheme: ColorScheme) -> AbundanceTheme {
        scheme == .dark ? .dark : .light
    }
}

private struct AbundanceThemeKey: EnvironmentKey {
    static let defaultValue: AbundanceTheme = .dark
}

public extension EnvironmentValues {
    var abundanceTheme: AbundanceTheme {
        get { self[AbundanceThemeKey.self] }
        set { self[AbundanceThemeKey.self] = newValue }
    }
}

public extension View {
    /// Injects the Abundance theme resolved for a color scheme.
    func abundanceTheme(_ scheme: ColorScheme) -> some View {
        environment(\.abundanceTheme, .resolve(scheme))
    }
}
