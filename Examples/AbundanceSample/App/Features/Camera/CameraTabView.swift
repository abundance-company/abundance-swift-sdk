import SwiftUI
import UIKit
import AbundanceDeviceKit

/// Camera tab: radar pairing when no device, else the live camera screen.
struct CameraTabView: View {
    @Environment(DeviceStore.self) private var store

    var body: some View {
        Group {
            if store.isPaired {
                CameraView()
            } else {
                PairDeviceView()
            }
        }
    }
}

// MARK: - Pairing

/// Radar-style pairing. Searching shows expanding ripples; the moment the
/// phone lands on the camera's Wi-Fi the device appears. A device this app
/// paired before reconnects with its stored `AbundanceCredentials` on its own;
/// anything else gets one big Connect pill (`AbundanceDevice.pair` — being on the
/// SoftAP is the credential). Troubleshooting lives behind "Don't see your
/// camera?" so the happy path is a single visual beat.
struct PairDeviceView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.abundanceTheme) private var theme
    @State private var found: DeviceHealth?
    @State private var isPairing = false
    @State private var isReconnecting = false
    @State private var pairError: String?
    @State private var showHelp = false

    var body: some View {
        AbundanceBackground {
            VStack(spacing: AbundanceSpacing.lg) {
                Spacer()
                RadarSearchView(found: found != nil)
                VStack(spacing: AbundanceSpacing.xs) {
                    Text(found == nil ? "Looking for your camera…" : "Camera found")
                        .font(AbundanceFont.titleLarge)
                        .foregroundStyle(theme.textPrimary)
                    Text(subtitle)
                        .font(AbundanceFont.bodyMedium)
                        .foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                footer
            }
            .padding(AbundanceSpacing.lg)
        }
        .navigationTitle("Camera")
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showHelp) { PairHelpSheet() }
        // Runs while the screen is visible. The user hops to Settings, joins
        // the camera's Wi-Fi, comes back — the camera appears on its own.
        .task {
            #if DEBUG
            // Simulator smoke tests: `-uiPairFound` renders the found state
            // without a reachable device.
            if ProcessInfo.processInfo.arguments.contains("-uiPairFound") {
                found = DeviceHealth(
                    deviceID: "261ed43dabcdef",
                    firmwareVersion: "1.0.7",
                    host: AbundanceDeviceFinder.gatewayHost
                )
            }
            #endif
            while !Task.isCancelled {
                if found == nil, let health = await AbundanceDeviceFinder.probe(attempts: 1) {
                    found = health
                    // Paired before → `AbundanceDevice.connect` needs no tap at all.
                    isReconnecting = true
                    let connected = await store.reconnect(to: health)
                    isReconnecting = false
                    if connected { return }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var subtitle: String {
        if let found {
            return "Abundance \(String(found.deviceID.prefix(8))) · v\(found.firmwareVersion)"
        }
        return "Join the camera's Wi-Fi to connect —\nthe network starts with “A4-Abundance”."
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: AbundanceSpacing.sm) {
            if let pairError {
                Text(pairError)
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textDanger)
                    .multilineTextAlignment(.center)
            }
            if let found {
                Button {
                    Task { await pair() }
                } label: {
                    Text(isPairing || isReconnecting
                         ? "Connecting…"
                         : "Connect \(String(found.deviceID.prefix(8)).uppercased())")
                }
                .buttonStyle(AbundancePrimaryButtonStyle())
                .disabled(isPairing || isReconnecting)
            } else {
                Button("Don't see your camera?") { showHelp = true }
                    .buttonStyle(AbundanceQuietButtonStyle())
            }
        }
        .padding(.bottom, AbundanceSpacing.sm)
        .animation(.easeInOut(duration: 0.2), value: found != nil)
    }

    private func pair() async {
        guard let found else { return }
        pairError = nil
        isPairing = true
        await store.pair(host: found.host)
        isPairing = false
        if !store.isPaired {
            pairError = store.lastError ?? "Pairing didn't finish — try again."
        }
    }
}

/// The "Don't see device?" checklist, as a medium sheet.
private struct PairHelpSheet: View {
    @Environment(\.abundanceTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: AbundanceSpacing.lg) {
            Text("Don't see your camera?")
                .font(AbundanceFont.titleMedium)
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: AbundanceSpacing.md) {
                row("power", "The camera is powered on", "Wait for its light to come on.")
                row("wifi", "Your phone is on the camera's Wi-Fi", "The network name starts with “A4-Abundance”.")
                row("dot.radiowaves.left.and.right", "You're within range", "Stay close to the camera while connecting.")
                row("arrow.clockwise", "Still nothing?", "Power-cycle the camera and check again.")
            }
            Button("Open Wi-Fi Settings") { openWiFiSettings() }
                .buttonStyle(AbundancePrimaryButtonStyle())
        }
        .padding(AbundanceSpacing.lg)
        .presentationDetents([.medium])
        .presentationBackground(theme.surfaceDefault)
        .presentationDragIndicator(.visible)
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: AbundanceSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textAccentOcean)
                .frame(width: 36, height: 36)
                .background(theme.bgAccentSubtle, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AbundanceFont.body)
                    .foregroundStyle(theme.textPrimary)
                Text(detail)
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    /// Wi-Fi settings deep links are private API whose spelling drifts across
    /// iOS releases ("App-Prefs:WIFI" on current builds, "root=WIFI" on older
    /// ones), and the simulator has no Wi-Fi pane at all — so walk the
    /// candidates in order and end at plain Settings, never the app's own
    /// settings page (it has no path to Wi-Fi). Production apps can skip this
    /// screen entirely — `AbundanceDeviceFinder.joinDeviceNetwork(passphrase:)` joins
    /// the SoftAP programmatically with the Hotspot Configuration entitlement.
    private func openWiFiSettings() {
        openFirst(of: [
            "App-Prefs:WIFI",                    // current device builds → Wi-Fi pane
            "App-Prefs:root=WIFI",               // older device builds
            "App-Prefs:",                        // Settings root — one tap from Wi-Fi
            UIApplication.openSettingsURLString, // last resort: guaranteed to open
        ])
    }

    private func openFirst(of candidates: [String]) {
        guard let first = candidates.first, let url = URL(string: first) else { return }
        UIApplication.shared.open(url) { ok in
            if !ok {
                openFirst(of: Array(candidates.dropFirst()))
            }
        }
    }
}

// MARK: - Camera (paired)

/// The live camera screen, GoPro-style: the viewfinder is the hero in the
/// middle, the elapsed-time readout floats large above it, and one big record
/// control sits at the bottom. Text appears only when something needs
/// explaining; device details live in Settings.
struct CameraView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.abundanceTheme) private var theme
    @State private var previewModel: PreviewModel?

    var body: some View {
        AbundanceBackground {
            VStack(spacing: AbundanceSpacing.lg) {
                statusRow
                Spacer(minLength: 0)
                timerReadout
                if let previewModel {
                    LivePreviewView(model: previewModel, store: store)
                }
                if store.recordPhase == .recording, let line = sessionLine {
                    Text(line)
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textTertiary)
                }
                if let interruption = store.interruption {
                    interruptionBanner(interruption)
                }
                if let issue {
                    issueBanner(issue)
                }
                if let note = store.note {
                    Text(note)
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textWarning)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AbundanceSpacing.md)
                }
                Spacer(minLength: 0)
                recordControl
            }
            .padding(AbundanceSpacing.lg)
            .animation(.easeInOut(duration: 0.25), value: store.recordPhase)
        }
        .navigationTitle("Camera")
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            if previewModel == nil {
                let store = store
                previewModel = PreviewModel { store.device?.preview }
            }
        }
        .onChange(of: store.interruption) { old, new in
            // The split just happened on the device: the operator is filming,
            // not watching the phone — buzz so they look down.
            if new != nil, new != old {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    // MARK: top chrome

    /// Slim glass chip: free space on the right. Everything else about the
    /// device lives in Settings.
    private var statusRow: some View {
        HStack {
            Spacer()
            if let free = freeSpaceLine {
                Text(free)
                    .font(AbundanceFont.label)
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, AbundanceSpacing.sm)
                    .padding(.vertical, AbundanceSpacing.xs)
                    .abundanceGlassCapsule()
            }
        }
    }

    private var freeSpaceLine: String? {
        guard let volume = store.snapshot?.storage?.volumes?.first(where: { $0.mounted == true }),
              let free = volume.freeBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
    }

    /// The big elapsed-time readout above the viewfinder while a take runs.
    @ViewBuilder private var timerReadout: some View {
        if store.recordPhase == .recording, let since = store.recordingSince {
            RecordingTimerText(since: since)
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .transition(.opacity)
        }
    }

    // MARK: recording interrupted (loud, sticky)

    private func interruptionBanner(_ interruption: DeviceStore.RecordingInterruption) -> some View {
        HStack(alignment: .top, spacing: AbundanceSpacing.sm) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textDanger)
                .frame(width: 36, height: 36)
                .background(theme.bgAccentSubtle, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(interruption.restarts > 1
                     ? "Recording interrupted \(interruption.restarts)×"
                     : "Recording interrupted")
                    .font(AbundanceFont.body)
                    .foregroundStyle(theme.textDanger)
                Text("A camera error restarted the recording — the footage is now split, and the part before the interruption cannot get UTC timestamps.")
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textPrimary)
                Text(interruption.message)
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 0)
            Button {
                store.dismissInterruption()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(AbundanceSpacing.sm)
        .abundanceGlass(cornerRadius: AbundanceRadius.lg)
        .overlay(
            RoundedRectangle(cornerRadius: AbundanceRadius.lg, style: .continuous)
                .strokeBorder(theme.textDanger.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: device issues

    /// The one condition currently blocking recording, worst first. The device
    /// reports these in every snapshot; the app's job is to say them plainly.
    private enum Issue {
        case unreachable
        case noCamera
        case noSD
        case recordingError(String)
    }

    private var issue: Issue? {
        guard store.isConnected else { return .unreachable }
        if store.snapshot?.cameraState == .absent { return .noCamera }
        if sdMissing { return .noSD }
        if store.snapshot?.recordingState == .error {
            return .recordingError(store.snapshot?.recording?.errorMsg ?? "The camera reported a recording error.")
        }
        return nil
    }

    /// True when the device reports its storage but no mounted volume — the
    /// recorder can start yet will sit waiting for a card forever.
    private var sdMissing: Bool {
        guard let volumes = store.snapshot?.storage?.volumes else { return false }
        return !volumes.contains { $0.mounted == true }
    }

    private func issueBanner(_ issue: Issue) -> some View {
        let (icon, title, detail): (String, String, String) = {
            switch issue {
            case .unreachable:
                return ("wifi.exclamationmark", "Camera isn't reachable",
                        "Join the camera's Wi-Fi (A4-Abundance-…) and stay on it.")
            case .noCamera:
                return ("video.slash.fill", "Camera module isn't connected",
                        "Plug the USB camera into the device.")
            case .noSD:
                return ("sdcard", "SD card isn't inserted",
                        "Insert an SD card into the device to record.")
            case .recordingError(let message):
                return ("exclamationmark.triangle.fill", "Recording error", message)
            }
        }()
        return HStack(alignment: .top, spacing: AbundanceSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.iconWarning)
                .frame(width: 36, height: 36)
                .background(theme.bgAccentSubtle, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AbundanceFont.body)
                    .foregroundStyle(theme.textPrimary)
                Text(detail)
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(AbundanceSpacing.sm)
        .abundanceGlass(cornerRadius: AbundanceRadius.lg)
    }

    // MARK: record control

    private var recordControl: some View {
        let phase = store.recordPhase
        let active = (phase == .recording || phase == .starting || phase == .stopping)
        return VStack(spacing: AbundanceSpacing.sm) {
            Button {
                Task {
                    if active { await store.stop() } else { await store.start() }
                }
            } label: {
                RecordButtonShape(recording: active)
            }
            .buttonStyle(.plain)
            .disabled(recordDisabled(phase))
            .opacity(recordDisabled(phase) ? 0.4 : 1)
            if let reason = hint(phase) {
                Text(reason)
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// "s000058 · 3 segments" (+ restart count when the take has split) so the
    /// operator can see exactly which session is being written.
    private var sessionLine: String? {
        guard let recording = store.snapshot?.recording,
              let session = recording.sessionId, !session.isEmpty else { return nil }
        var parts = [String(session.prefix(7))]
        if let segments = recording.segmentsOnDisk {
            parts.append("\(segments) segment\(segments == 1 ? "" : "s")")
        }
        if let restarts = recording.gstRestarts, restarts > 0 {
            parts.append("\(restarts) restart\(restarts == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private func recordDisabled(_ phase: DeviceStore.RecordPhase) -> Bool {
        guard store.isConnected, !sdMissing else { return true }
        switch phase {
        case .starting, .stopping: return true
        case .idle, .error, .unknown:
            return store.snapshot?.cameraState != .ready
        case .recording:
            return false // nothing may ever prevent stopping
        }
    }

    /// Only the transient states — everything else is the issue banner's job.
    private func hint(_ phase: DeviceStore.RecordPhase) -> String? {
        switch phase {
        case .starting: return "Starting…"
        case .stopping: return "Stopping…"
        default: return nil
        }
    }
}

/// Camera-app idiom: red circle to start, red square to stop, with a slow
/// pulse ring while a take is running.
private struct RecordButtonShape: View {
    @Environment(\.abundanceTheme) private var theme
    let recording: Bool
    @State private var pulsing = false

    var body: some View {
        ZStack {
            if recording {
                Circle()
                    .stroke(theme.bgRecord.opacity(pulsing ? 0 : 0.5), lineWidth: 2)
                    .frame(width: 78, height: 78)
                    .scaleEffect(pulsing ? 1.35 : 1)
                    .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulsing)
                    .onAppear { pulsing = true }
                    .onDisappear { pulsing = false }
            }
            Circle()
                .strokeBorder(theme.textPrimary.opacity(0.9), lineWidth: 4)
                .frame(width: 78, height: 78)
            if recording {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.bgRecord)
                    .frame(width: 32, height: 32)
            } else {
                Circle()
                    .fill(theme.bgRecord)
                    .frame(width: 62, height: 62)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: recording)
    }
}
