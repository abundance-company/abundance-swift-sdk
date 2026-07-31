import SwiftUI
import AbundanceDeviceKit

/// Settings: the SDK context this sample runs on, the paired camera, unpair.
struct SettingsView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.abundanceTheme) private var theme
    @State private var confirmUnpair = false

    var body: some View {
        AbundanceBackground {
            ScrollView {
                VStack(spacing: AbundanceSpacing.md) {
                    sdkCard
                    if store.isPaired {
                        cameraCard
                    }
                    Text(versionLine)
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.top, AbundanceSpacing.sm)
                }
                .padding(AbundanceSpacing.lg)
            }
        }
        .navigationTitle("Settings")
    }

    private var sdkCard: some View {
        AbundanceCard {
            VStack(alignment: .leading, spacing: AbundanceSpacing.xs) {
                SectionHeader("SDK")
                Text("AbundanceDeviceKit")
                    .font(AbundanceFont.titleSmall)
                    .foregroundStyle(theme.textPrimary)
                HStack(spacing: AbundanceSpacing.sm) {
                    if let device = store.device {
                        Text("Firmware v\(device.firmwareVersion)")
                        Text(capabilityLine(device.grantedCapabilities))
                    } else {
                        Text("No camera connected")
                    }
                }
                .font(AbundanceFont.caption)
                .foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func capabilityLine(_ capabilities: Set<Capability>) -> String {
        capabilities.map(\.rawValue).sorted().joined(separator: " · ")
    }

    private var cameraCard: some View {
        AbundanceCard {
            VStack(alignment: .leading, spacing: AbundanceSpacing.xs) {
                SectionHeader("Camera")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Abundance \(String(store.device?.deviceID.prefix(8) ?? ""))")
                            .font(AbundanceFont.titleSmall)
                            .foregroundStyle(theme.textPrimary)
                        Text(cameraDetail)
                            .font(AbundanceFont.caption)
                            .foregroundStyle(theme.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "video.fill")
                        .foregroundStyle(theme.textAccentOcean)
                }
                NavigationLink {
                    DeviceDetailsView()
                } label: {
                    HStack(spacing: AbundanceSpacing.xxs) {
                        Text("Device details")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .font(AbundanceFont.label)
                .foregroundStyle(theme.textAccentOcean)
                .padding(.top, AbundanceSpacing.xxs)
                Button("Unpair camera") { confirmUnpair = true }
                    .font(AbundanceFont.label)
                    .foregroundStyle(theme.textDanger)
                    .padding(.top, AbundanceSpacing.xxs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Unpair this camera?",
            isPresented: $confirmUnpair,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) { store.unpair() }
        } message: {
            Text("Recordings already saved on this iPhone stay. Pairing again just takes joining the camera's Wi-Fi.")
        }
    }

    /// Storage headline when the camera is reachable (~16 Mbps video +
    /// 128 kbps audio ≈ 2 MB/s), else the pairing note.
    private var cameraDetail: String {
        guard store.isConnected,
              let volume = store.snapshot?.storage?.volumes?.first(where: { $0.mounted == true }),
              let free = volume.freeBytes else {
            return "Paired over its Wi-Fi network"
        }
        let gb = Double(free) / 1_000_000_000
        let hours = Double(free) / 2_016_000 / 3600
        if hours >= 1 {
            return String(format: "%.0f GB free · ≈%.0f h of recording", gb, hours)
        }
        return String(format: "%.1f GB free", gb)
    }

    private var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "Abundance Sample · v\(short) (\(build))"
    }
}
