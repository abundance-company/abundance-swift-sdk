import SwiftUI

/// The pairing hero: concentric "radar" rings around a camera glyph. While
/// searching, ripples expand outward; once a device is found the ripples stop
/// and a checkmark badge lands on the center.
struct RadarSearchView: View {
    @Environment(\.abundanceTheme) private var theme
    let found: Bool

    @State private var rippling = false

    private let size: CGFloat = 280

    var body: some View {
        ZStack {
            // Static rings, faintest outward — the dashed outer ring gives the
            // "scanning field" read even in a still screenshot.
            Circle()
                .strokeBorder(theme.borderSubtle.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
                .frame(width: size, height: size)
            Circle()
                .strokeBorder(theme.borderSubtle.opacity(0.55), lineWidth: 1)
                .frame(width: size * 0.72, height: size * 0.72)
            Circle()
                .fill(theme.bgAccentSubtle.opacity(0.45))
                .frame(width: size * 0.46, height: size * 0.46)

            if !found {
                ripple(delay: 0)
                ripple(delay: 1)
            }

            center
        }
        .frame(width: size, height: size)
        .onAppear { rippling = true }
    }

    private func ripple(delay: Double) -> some View {
        Circle()
            .stroke(theme.borderAccentOcean.opacity(0.6), lineWidth: 1.5)
            .frame(width: size * 0.46, height: size * 0.46)
            .scaleEffect(rippling ? 2.2 : 1)
            .opacity(rippling ? 0 : 0.8)
            .animation(
                .easeOut(duration: 2).repeatForever(autoreverses: false).delay(delay),
                value: rippling
            )
    }

    private var center: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(theme.bgAccentOcean)
                .frame(width: 96, height: 96)
                .shadow(color: theme.bgAccentOcean.opacity(0.45), radius: 24)
            Image(systemName: "video.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
            if found {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(theme.textInverse, theme.textPrimary)
                    .background(Circle().fill(theme.surfacePage).padding(2))
                    .offset(x: 4, y: 4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: found)
    }
}
