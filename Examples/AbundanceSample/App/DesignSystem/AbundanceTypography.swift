import SwiftUI

public enum AbundanceFontFamily {
    /// Geist is the canonical typeface. Until the Geist .ttf files are bundled
    /// (added to the app target + Info.plist `UIAppFonts`), `Font.custom` falls
    /// back to the system font automatically.
    public static let primary = "Geist"
    public static let mono = "Geist Mono"
}

/// The canonical type scale (Geist), mapped from the design system's size +
/// weight tokens. Sizes are in points.
public enum AbundanceFont {
    static func geist(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .custom(AbundanceFontFamily.primary, size: size).weight(weight)
    }
    static func geistMono(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .custom(AbundanceFontFamily.mono, size: size).weight(weight)
    }

    public static let displayLarge = geist(32, .semibold)
    public static let titleLarge   = geist(24, .semibold)
    public static let titleMedium  = geist(20, .semibold)
    public static let titleSmall   = geist(18, .medium)
    public static let body         = geist(16, .regular)
    public static let bodyMedium   = geist(14, .regular)
    public static let caption      = geist(13, .regular)
    public static let label        = geist(12, .medium)
    public static let mono         = geistMono(13, .regular)
}
