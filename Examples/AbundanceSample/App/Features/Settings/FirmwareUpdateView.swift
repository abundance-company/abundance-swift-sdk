import SwiftUI
import AbundanceDeviceKit

/// Manual OTA flow. The iPhone downloads on internet first (Wi-Fi or
/// cellular), holds the verified bundle in memory only, then sends it over
/// the camera SoftAP. Every state names both versions - what the camera runs
/// now and what it is being updated to.
struct FirmwareUpdateView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.abundanceTheme) private var theme
    @State private var latestRelease: FirmwareRelease?
    @State private var downloadedBundle: VerifiedFirmwareBundle?
    @State private var isChecking = false
    @State private var isDownloading = false
    @State private var isInstalling = false
    @State private var uploadProgress: Double?
    @State private var downloadProgress: Double?
    @State private var isVerifying = false
    @State private var awaitsInstalledVersionCheck = false
    @State private var verifiedVersion: String?
    @State private var message: String?

    var body: some View {
        AbundanceBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: AbundanceSpacing.md) {
                    AbundanceCard {
                        VStack(alignment: .leading, spacing: AbundanceSpacing.xs) {
                            HStack {
                                SectionHeader("Firmware")
                                Spacer()
                                headerAction
                            }
                            if let instructions {
                                Text(instructions)
                                    .font(AbundanceFont.caption)
                                    .foregroundStyle(theme.textTertiary)
                                    .padding(.bottom, AbundanceSpacing.sm)
                            }
                            row("Status", statusValue)
                            row("Current", cameraVersion.map { "v\($0)" } ?? "—")
                            row("Available", latestRelease.map { "v\($0.version)" } ?? "—",
                                danger: latestRelease?.critical == true && cameraVersion != latestRelease?.version)
                            row("Notes", latestRelease?.notes ?? "—")
                            if let progress = downloadProgress ?? uploadProgress {
                                ProgressView(value: progress)
                                    .tint(theme.textAccentOcean)
                                Text("\(Int(progress * 100))% \(downloadProgress != nil ? "downloaded" : "sent")")
                                    .font(AbundanceFont.caption)
                                    .foregroundStyle(theme.textTertiary)
                                    .monospacedDigit()
                            }
                            if let message {
                                Text(message)
                                    .font(AbundanceFont.caption)
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(AbundanceSpacing.lg)
            }
        }
        .navigationTitle("Updates")
        .task {
            removeLegacyDownloadCache()
        }
    }

    private var updateConfirmed: Bool {
        verifiedVersion != nil && verifiedVersion == latestRelease?.version
    }

    private var cameraVersion: String? {
        store.device?.firmwareVersion
    }

    // MARK: - Copy

    private var statusValue: String {
        if updateConfirmed { return "Updated to v\(verifiedVersion ?? "")" }
        if isVerifying || awaitsInstalledVersionCheck { return "Installing…" }
        if isDownloading { return "Downloading…" }
        if isChecking { return "Checking…" }
        if let latestRelease {
            if let cameraVersion, cameraVersion == latestRelease.version {
                return "Up to date"
            }
            if downloadedBundle != nil { return "Ready to update" }
            return latestRelease.critical ? "Critical update available" : "Update available"
        }
        return "Not checked"
    }

    private func row(_ label: String, _ value: String, danger: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(AbundanceFont.caption)
                .foregroundStyle(theme.textTertiary)
            Spacer()
            Text(value)
                .font(AbundanceFont.label)
                .foregroundStyle(danger ? theme.textDanger : theme.textPrimary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }

    private var instructions: String? {
        if updateConfirmed { return nil }
        if isVerifying || awaitsInstalledVersionCheck {
            return "Restart takes about a minute. Rejoin A4-Abundance Wi-Fi when available."
        }
        if let latestRelease {
            if let cameraVersion, cameraVersion == latestRelease.version { return nil }
            if downloadedBundle != nil {
                return "Send upgrade bundle to camera. Requires camera restart to install. Do not remove power."
            }
            return "Download newest firmware to iPhone."
        }
        return "Find newest firmware version."
    }

    // MARK: - Actions

    /// Top-right staged action, in the Rescan-button register: check for
    /// update -> download update -> update device.
    @ViewBuilder private var headerAction: some View {
        switch firmwareUpdateAction {
        case .checkRelease:
            headerButton("Check for update") { await fetchLatestRelease() }
                .disabled(isChecking)
        case .downloadRelease:
            headerButton("Download update") { await downloadLatestRelease() }
        case .installRelease:
            headerButton("Update device") { await installDownloadedBundle() }
                .disabled(store.recordPhase != .idle)
        case .checkInstalledVersion:
            headerButton("Check again") { await verifyInstalledVersion() }
        case .none:
            ProgressView()
                .tint(theme.textAccentOcean)
        }
    }

    private func headerButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button(title) { Task { await action() } }
            .font(AbundanceFont.label)
            .foregroundStyle(theme.textAccentOcean)
    }

    private var firmwareUpdateAction: FirmwareUpdateAction {
        selectFirmwareUpdateAction(
            hasRelease: latestRelease != nil,
            hasDownloadedBundle: downloadedBundle != nil,
            runsInstalledVersionCheck: awaitsInstalledVersionCheck,
            isBusy: isChecking || isDownloading || isInstalling || isVerifying,
            releaseIsInstalled: latestRelease?.version == store.device?.firmwareVersion
        )
    }

    private func fetchLatestRelease() async {
        isChecking = true
        defer { isChecking = false }
        do {
            latestRelease = try await firmwareReleaseFeed.fetchLatestFirmwareRelease()
            message = nil
        } catch {
            message = DeviceStore.describe(error)
        }
    }

    private func downloadLatestRelease() async {
        guard let latestRelease else { return }
        isDownloading = true
        downloadProgress = 0
        defer {
            isDownloading = false
            downloadProgress = nil
        }
        do {
            downloadedBundle = try await firmwareReleaseFeed.downloadFirmwareBundle(
                latestRelease,
                reportProgress: { receivedBytes, totalBytes in
                    guard totalBytes > 0 else { return }
                    let fraction = min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
                    Task { @MainActor in
                        downloadProgress = fraction
                    }
                }
            )
            message = nil
        } catch {
            message = DeviceStore.describe(error)
        }
    }

    private func installDownloadedBundle() async {
        guard let downloadedBundle else { return }
        isInstalling = true
        message = nil
        defer {
            isInstalling = false
            uploadProgress = nil
        }
        guard let health = await AbundanceDeviceFinder.probe(attempts: 1) else {
            message = "Send failed: camera Wi-Fi is not reachable. Join the A4-Abundance network in iOS Settings, then try again."
            return
        }
        if let pairedDeviceID = store.device?.deviceID, pairedDeviceID != health.deviceID {
            message = "Send failed: a different camera answered. Join this camera's own Wi-Fi network."
            return
        }
        if !store.isConnected {
            guard await store.reconnect(to: health) else {
                message = "Send failed: camera found, but this app could not reconnect."
                return
            }
        }
        guard let device = store.device else {
            message = "Send failed: pair with the camera first."
            return
        }
        do {
            _ = try await device.maintenance.readLastUpdateResult()
        } catch AbundanceError.unexpectedStatus(404) {
            message = "Send failed: camera firmware v\(device.firmwareVersion) predates app updates. Install this release once from an SD card; later updates work from the app."
            return
        } catch AbundanceError.device {
            // Endpoint answered with a device envelope (e.g. no attempt yet) - OTA supported.
        } catch {
            message = "Send failed: \(DeviceStore.describe(error))"
            return
        }
        uploadProgress = 0
        message = nil
        do {
            try await device.maintenance.sendFirmwareBundle(
                downloadedBundle,
                reportProgress: { sentBytes, totalBytes in
                    guard totalBytes > 0 else { return }
                    let fraction = min(max(Double(sentBytes) / Double(totalBytes), 0), 1)
                    Task { @MainActor in
                        uploadProgress = fraction
                    }
                }
            )
            try await device.maintenance.reboot()
            awaitsInstalledVersionCheck = true
            message = nil
        } catch AbundanceError.device(let error) where error.code == .updateAlreadyAttempted {
            do {
                let priorResult = try await device.maintenance.readLastUpdateResult()
                message = "Camera did not restart. This exact bundle was already attempted. Prior result: \(priorResult.status.rawValue). \(priorResult.error)"
            } catch {
                message = "Camera did not restart. This exact bundle was already attempted."
            }
        } catch {
            message = "Send failed: \(DeviceStore.describe(error))"
        }
    }

    /// Checks once after the user rejoins the camera Wi-Fi.
    /// Reboot timing and Wi-Fi selection belong to the user, not a hidden poll.
    private func verifyInstalledVersion() async {
        guard let latestRelease, awaitsInstalledVersionCheck, !isVerifying else { return }
        let pairedDeviceID = store.device?.deviceID
        let sentBundleSHA256 = downloadedBundle?.release.bundleSHA256.lowercased()
        isVerifying = true
        message = nil
        defer { isVerifying = false }

        guard let health = await AbundanceDeviceFinder.probe(attempts: 1) else {
            message = "Camera is not reachable. Rejoin A4-Abundance Wi-Fi, then check again."
            return
        }
        if let pairedDeviceID, health.deviceID != pairedDeviceID {
            message = "A different camera answered. Rejoin this camera's A4-Abundance Wi-Fi."
            return
        }
        guard await store.reconnect(to: health) else {
            message = "Camera returned, but this app could not reconnect. Check again."
            return
        }
        if health.firmwareVersion == latestRelease.version {
            verifiedVersion = health.firmwareVersion
            awaitsInstalledVersionCheck = false
            return
        }

        if let sentBundleSHA256,
           let device = store.device,
           let verdict = try? await device.maintenance.readLastUpdateResult(),
           verdict.bundleSHA256.lowercased() == sentBundleSHA256,
           verdict.status != .success {
            message = "Update did not install - camera still runs v\(health.firmwareVersion). Reason: \(verdict.status.rawValue). \(verdict.error)"
            awaitsInstalledVersionCheck = false
            return
        }
        message = "Camera still runs v\(health.firmwareVersion). Wait for restart, then check again."
    }

    /// Earlier builds cached bundles under Library/Caches/FirmwareUpdates.
    /// Bundles now live in memory only; delete anything left on disk.
    private func removeLegacyDownloadCache() {
        let legacyDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FirmwareUpdates", isDirectory: true)
        try? FileManager.default.removeItem(at: legacyDirectory)
    }

    private var firmwareReleaseFeed: FirmwareReleaseFeed {
        FirmwareReleaseFeed(feedURL: firmwareReleaseFeedURL)
    }

    private var firmwareReleaseFeedURL: URL {
        guard let rawURL = Bundle.main.object(forInfoDictionaryKey: "FirmwareReleaseFeedURL") as? String,
              let url = URL(string: rawURL)
        else {
            preconditionFailure("FirmwareReleaseFeedURL must be an absolute URL")
        }
        return url
    }
}
