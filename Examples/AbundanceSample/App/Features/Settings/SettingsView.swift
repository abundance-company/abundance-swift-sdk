import SwiftUI
import AbundanceDeviceKit

/// Settings: the paired camera, the SDK context this sample runs on, and the
/// camera's uplink (Station) status.
struct SettingsView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.abundanceTheme) private var theme
    @State private var confirmUnpair = false
    @State private var showUplink = false
    @State private var showUpdates = false

    var body: some View {
        AbundanceBackground {
            ScrollView {
                VStack(spacing: AbundanceSpacing.md) {
                    sdkCard
                    if store.isPaired {
                        cameraCard
                        uplinkCard
                    }
                    Text(versionLine)
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textTertiary)
                        .padding(.top, AbundanceSpacing.sm)
                }
                .padding(AbundanceSpacing.lg)
            }
        }
        .navigationDestination(isPresented: $showUplink) { UplinkView() }
        .navigationDestination(isPresented: $showUpdates) { FirmwareUpdateView() }
        #if DEBUG
        // `-uiOpenUplink` / `-uiOpenUpdates` push a detail screen once paired,
        // so simulator smoke tests can screenshot them without tapping.
        .task(id: store.isPaired) {
            guard store.isPaired else { return }
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-uiOpenUplink") { showUplink = true }
            if args.contains("-uiOpenUpdates") { showUpdates = true }
        }
        #endif
        .navigationTitle("Settings")
    }

    private var sdkCard: some View {
        AbundanceCard {
            VStack(alignment: .leading, spacing: AbundanceSpacing.xs) {
                SectionHeader("SDK")
                Text("AbundanceDeviceKit")
                    .font(AbundanceFont.titleSmall)
                    .foregroundStyle(theme.textPrimary)
                Text(store.device.map { "Firmware v\($0.firmwareVersion)" } ?? "No camera connected")
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textTertiary)
                // The whole flow talks to the camera (version, bundle send),
                // so the door only opens while one is connected.
                if store.isConnected {
                    NavigationLink {
                        FirmwareUpdateView()
                    } label: {
                        HStack(spacing: AbundanceSpacing.xxs) {
                            Text("Check for updates")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .font(AbundanceFont.label)
                    .foregroundStyle(theme.textAccentOcean)
                    .padding(.top, AbundanceSpacing.xxs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Status only; joining, forgetting, and scanning live in UplinkView.
    private var uplinkCard: some View {
        AbundanceCard {
            VStack(alignment: .leading, spacing: AbundanceSpacing.xs) {
                SectionHeader("Uplink")
                Text(uplinkHeadline)
                    .font(AbundanceFont.titleSmall)
                    .foregroundStyle(theme.textPrimary)
                if store.supportsStation {
                    NavigationLink {
                        UplinkView()
                    } label: {
                        HStack(spacing: AbundanceSpacing.xxs) {
                            Text("Network settings")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .font(AbundanceFont.label)
                    .foregroundStyle(theme.textAccentOcean)
                    .padding(.top, AbundanceSpacing.xxs)
                } else {
                    Text("Station upload needs camera firmware 1.1.0 or later.")
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var uplinkHeadline: String {
        guard store.supportsStation else { return "Not available" }
        return StationStateLabel.text(for: store.snapshot?.network?.station)
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
                HStack {
                    NavigationLink {
                        DeviceDetailsView()
                    } label: {
                        HStack(spacing: AbundanceSpacing.xxs) {
                            Text("Device details")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .foregroundStyle(theme.textAccentOcean)
                    Spacer()
                    Button("Unpair camera") { confirmUnpair = true }
                        .foregroundStyle(theme.textDanger)
                }
                .font(AbundanceFont.label)
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
