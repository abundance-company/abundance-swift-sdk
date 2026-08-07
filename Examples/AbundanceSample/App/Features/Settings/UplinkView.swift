import SwiftUI
import AbundanceDeviceKit

enum StationStateLabel {
    static func text(for station: StationStatus?) -> String {
        switch station?.state {
        case "connected": return station?.ssid ?? "Connected"
        case "connecting": return "Connecting…"
        default: return "Not joined"
        }
    }
}

/// The camera's uplink: live status, saved Wi-Fi profiles, and joining a
/// network from the camera's own scan. The customer backend configures the
/// upload destination (Broker); this sample only observes its status.
struct UplinkView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.abundanceTheme) private var theme

    @State private var saved: [String]?
    @State private var networks: [WifiNetwork]?
    @State private var scanning = false
    @State private var busySSID: String?
    @State private var note: String?
    @State private var joinTarget: JoinTarget?
    @State private var confirmForget: String?
    @State private var togglingUpload = false

    private struct JoinTarget: Identifiable {
        let ssid: String
        /// Empty ssid = the "Other network…" row; the sheet asks for both.
        var id: String { ssid }
    }

    var body: some View {
        AbundanceBackground {
            ScrollView {
                VStack(spacing: AbundanceSpacing.md) {
                    savedCard
                    if store.stationUploadConfigured { uploadCard }
                    networksCard
                }
                .padding(AbundanceSpacing.lg)
            }
        }
        .navigationTitle("Uplink")
        .task { await refresh(scan: true) }
        .refreshable { await refresh(scan: true) }
        .sheet(item: $joinTarget) { target in
            JoinSheet(ssid: target.ssid) { ssid, passphrase in
                await join(ssid: ssid, passphrase: passphrase)
            }
        }
    }

    // MARK: saved networks (uplink status + profiles)

    private var savedCard: some View {
        let station = store.snapshot?.network?.station
        return AbundanceCard {
            VStack(alignment: .leading, spacing: AbundanceSpacing.xs) {
                HStack {
                    SectionHeader("Saved networks")
                    Spacer()
                    if let ssid = station?.ssid, station?.state == "connected" {
                        Button("Forget") { confirmForget = ssid }
                            .font(AbundanceFont.label)
                            .foregroundStyle(theme.textDanger)
                            .disabled(busySSID != nil)
                    }
                }
                row("Uplink", StationStateLabel.text(for: station))
                if station?.state == "connected" {
                    if let rssi = station?.rssiDbm { row("Signal", "\(rssi) dBm") }
                    if let internet = station?.hasInternet {
                        row("Internet", internet ? "Yes" : "No", danger: !internet)
                    }
                }
                // The current uplink already has its own row above; list only
                // the other saved profiles.
                if let saved {
                    let others = saved.filter { $0 != station?.ssid || station?.state != "connected" }
                    if saved.isEmpty {
                        Text("No saved networks — join one below.")
                            .font(AbundanceFont.caption)
                            .foregroundStyle(theme.textTertiary)
                            .padding(.top, AbundanceSpacing.xxs)
                    }
                    ForEach(others, id: \.self) { ssid in
                        HStack {
                            Text(ssid)
                                .font(AbundanceFont.label)
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            Button("Forget") { confirmForget = ssid }
                                .font(AbundanceFont.caption)
                                .foregroundStyle(theme.textDanger)
                                .disabled(busySSID != nil)
                        }
                        .padding(.top, AbundanceSpacing.xxs)
                    }
                }
                if let note {
                    Text(note)
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textDanger)
                        .padding(.top, AbundanceSpacing.xxs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Forget \"\(confirmForget ?? "")\"?",
            isPresented: Binding(get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let ssid = confirmForget { Task { await forget(ssid: ssid) } }
            }
        } message: {
            Text("If this is the current uplink the camera disconnects from it. Your connection to the camera is unaffected.")
        }
    }

    // MARK: Station upload

    private var uploadBinding: Binding<Bool> {
        Binding(
            get: { store.stationUploadEnabled },
            set: { enabled in
                togglingUpload = true
                Task {
                    await store.setStationUploadEnabled(enabled)
                    togglingUpload = false
                }
            }
        )
    }

    private var uploadCard: some View {
        AbundanceCard {
            VStack(alignment: .leading, spacing: AbundanceSpacing.xs) {
                SectionHeader("Station upload")
                Toggle(isOn: uploadBinding) {
                    Text("Upload to broker")
                        .font(AbundanceFont.label)
                        .foregroundStyle(theme.textPrimary)
                }
                .disabled(togglingUpload)
                Text("Pausing resumes offloading to phone.")
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: networks in range

    private var networksCard: some View {
        AbundanceCard {
            VStack(alignment: .leading, spacing: AbundanceSpacing.xs) {
                HStack {
                    SectionHeader("Networks in range")
                    Spacer()
                    Button(scanning ? "Scanning…" : "Rescan") {
                        Task { await refresh(scan: true) }
                    }
                    .font(AbundanceFont.label)
                    .foregroundStyle(theme.textAccentOcean)
                    .disabled(scanning)
                }
                Text("Scanning hops the camera's radio across channels, so your connection may stall for a moment.")
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.bottom, AbundanceSpacing.sm)
                if let networks {
                    if networks.isEmpty {
                        Text("Nothing in range.")
                            .font(AbundanceFont.caption)
                            .foregroundStyle(theme.textTertiary)
                    }
                    ForEach(networks, id: \.ssid) { network in
                        Button {
                            joinTarget = JoinTarget(ssid: network.ssid)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(network.ssid)
                                        .font(AbundanceFont.label)
                                        .foregroundStyle(theme.textPrimary)
                                    Text("\(network.rssiDbm) dBm · ch \(network.channel) · \(network.band) GHz · \(network.security)")
                                        .font(AbundanceFont.caption)
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Spacer()
                                if network.saved {
                                    Text("saved")
                                        .font(AbundanceFont.caption)
                                        .foregroundStyle(theme.textAccentOcean)
                                }
                            }
                        }
                        .disabled(busySSID != nil)
                    }
                }
                Button("Other network…") { joinTarget = JoinTarget(ssid: "") }
                    .font(AbundanceFont.label)
                    .foregroundStyle(theme.textAccentOcean)
                    .padding(.top, AbundanceSpacing.xxs)
                    .disabled(busySSID != nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: actions

    /// Scanning stalls the phone's own path to the camera (single radio), so
    /// a transient failure here is expected — retry briefly before showing
    /// anything red.
    private func refresh(scan: Bool) async {
        guard let device = store.device else { return }
        note = nil
        do {
            saved = try await withTransientRetry { try await device.station.savedNetworksAndUplink().saved }
        } catch {
            note = describeRefreshFailure(error)
        }
        guard scan, !scanning else { return }
        scanning = true
        defer { scanning = false }
        do {
            // Strongest first — the device sorts.
            networks = try await withTransientRetry { try await device.station.scanNetworks().networks }
        } catch AbundanceError.device(let deviceError) where deviceError.code == .recordingActive {
            // Expected while a capture or preview runs; the stale list stays.
        } catch {
            note = describeRefreshFailure(error)
        }
    }

    /// Two extra attempts with a beat between them — enough to ride out a
    /// channel-hop stall without masking a genuinely unreachable camera.
    private func withTransientRetry<T>(_ operation: () async throws -> T) async throws -> T {
        for _ in 0..<2 {
            do { return try await operation() } catch let error as AbundanceError {
                if case .device = error { throw error } // real device answer — no retry
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        return try await operation()
    }

    private func describeRefreshFailure(_ error: Error) -> String {
        if case AbundanceError.device = error { return DeviceStore.describe(error) }
        return "Couldn't reach the camera — pull down to retry."
    }

    /// Returns an error message for the sheet, nil on success.
    private func join(ssid: String, passphrase: String) async -> String? {
        guard let device = store.device else { return "No camera connected." }
        busySSID = ssid
        defer { busySSID = nil }
        do {
            _ = try await device.station.join(ssid: ssid, passphrase: passphrase)
            await refresh(scan: false)
            return nil
        } catch {
            if await recoveredJoin(device: device, targetSSID: ssid) {
                return nil
            }
            if case AbundanceError.device(let deviceError) = error,
               deviceError.code == .joinFailed {
                return "Join failed — wrong password or out of range. Nothing was saved."
            }
            return DeviceStore.describe(error)
        }
    }

    /// A cross-channel join can move the SoftAP before its response reaches
    /// the phone. Once the connection returns, ask the camera for the outcome
    /// before reporting a failure.
    private func recoveredJoin(device: AbundanceDevice, targetSSID: String) async -> Bool {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1.5)) }
            guard let status = try? await device.station.savedNetworksAndUplink() else { continue }
            saved = status.saved
            if status.station?.state == "connected", status.station?.ssid == targetSSID {
                return true
            }
        }
        return false
    }

    private func forget(ssid: String) async {
        guard let device = store.device else { return }
        busySSID = ssid
        defer { busySSID = nil }
        do {
            try await device.station.forget(ssid: ssid)
            await refresh(scan: false)
        } catch {
            note = DeviceStore.describe(error)
        }
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
        }
    }
}

/// SSID (when picked from the scan) is fixed; the "Other network…" path asks
/// for it. The device saves nothing on a failed join, so retries are safe.
private struct JoinSheet: View {
    let ssid: String
    let onJoin: (String, String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.abundanceTheme) private var theme
    @State private var enteredSSID = ""
    @State private var passphrase = ""
    @State private var joining = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if ssid.isEmpty {
                    TextField("Network name", text: $enteredSSID)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                SecureField("Password", text: $passphrase)
                if let error {
                    Text(error)
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textDanger)
                }
            }
            .navigationTitle(ssid.isEmpty ? "Other network" : ssid)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(joining ? "Joining…" : "Join") {
                        joining = true
                        error = nil
                        Task {
                            let result = await onJoin(ssid.isEmpty ? enteredSSID : ssid, passphrase)
                            joining = false
                            if let result { error = result } else { dismiss() }
                        }
                    }
                    .disabled(joining || passphrase.isEmpty || (ssid.isEmpty && enteredSSID.isEmpty))
                }
            }
        }
        .presentationDetents([.medium])
    }
}
