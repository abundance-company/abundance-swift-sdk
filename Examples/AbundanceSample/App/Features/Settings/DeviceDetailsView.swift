import SwiftUI
import AbundanceDeviceKit

/// Device health + forensics: live recorder state (session, restarts, last
/// pipeline error) and the tail of the device's durable event log
/// (`device.deviceLog`) — so "what happened?" is answerable from the phone
/// instead of SSH.
struct DeviceDetailsView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(\.abundanceTheme) private var theme
    @State private var logLines: [String]?
    @State private var logError: String?

    var body: some View {
        AbundanceBackground {
            ScrollView {
                VStack(spacing: AbundanceSpacing.md) {
                    recorderCard
                    deviceCard
                    eventsCard
                }
                .padding(AbundanceSpacing.lg)
            }
        }
        .navigationTitle("Device details")
        .task { await loadLog() }
        .refreshable { await loadLog() }
    }

    // MARK: recorder health

    private var recorderCard: some View {
        let recording = store.snapshot?.recording
        return AbundanceCard {
            VStack(alignment: .leading, spacing: AbundanceSpacing.xs) {
                SectionHeader("Recorder")
                row("State", store.snapshot?.recordingState.rawValue ?? "—")
                row("Session", recording?.sessionId ?? "—")
                row("Pipeline restarts",
                    recording?.gstRestarts.map(String.init) ?? "0",
                    danger: (recording?.gstRestarts ?? 0) > 0)
                row("Last error", (recording?.lastError).flatMap { $0.isEmpty ? nil : $0 } ?? "None",
                    danger: (recording?.lastError ?? "").isEmpty == false)
                row("Segments on card", recording?.segmentsOnDisk.map(String.init) ?? "—")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: device

    private var deviceCard: some View {
        let snap = store.snapshot
        return AbundanceCard {
            VStack(alignment: .leading, spacing: AbundanceSpacing.xs) {
                SectionHeader("Device")
                row("Connection", store.isConnected ? "Live" : "Disconnected",
                    danger: !store.isConnected)
                row("Camera", snap?.camera?.state ?? "—",
                    danger: snap?.cameraState == .absent)
                row("UTC time", snap?.meta?.timeSynced == true ? "Synchronized" : "Not synchronized")
                row("Boot", (snap?.meta?.bootId).map { String($0.prefix(8)) } ?? "—")
                if let uptime = snap?.meta?.deviceUptimeS {
                    row("Uptime", RecordingTimerText.format(uptime))
                }
                if let volume = snap?.storage?.volumes?.first {
                    row("SD card", volume.mounted == true
                        ? String(format: "%.0f%% used", volume.usedPct ?? 0)
                        : "Not inserted",
                        danger: volume.mounted != true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: durable event log

    private var eventsCard: some View {
        AbundanceCard {
            VStack(alignment: .leading, spacing: AbundanceSpacing.xs) {
                SectionHeader("Device events")
                if let logError {
                    Text(logError)
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textWarning)
                } else if let logLines {
                    if logLines.isEmpty {
                        Text("No events recorded yet.")
                            .font(AbundanceFont.caption)
                            .foregroundStyle(theme.textTertiary)
                    } else {
                        // Newest first: the question is always "what just happened?"
                        ForEach(Array(logLines.reversed().enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.textTertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
                Button("Refresh") { Task { await loadLog() } }
                    .font(AbundanceFont.label)
                    .foregroundStyle(theme.textAccentOcean)
                    .padding(.top, AbundanceSpacing.xxs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func loadLog() async {
        guard let device = store.device else {
            logError = "Not connected to the camera."
            return
        }
        do {
            logLines = try await device.deviceLog(lines: 50)
            logError = nil
        } catch {
            logError = DeviceStore.describe(error)
        }
    }

    private func row(_ label: String, _ value: String, danger: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(AbundanceFont.caption)
                .foregroundStyle(theme.textTertiary)
            Spacer(minLength: AbundanceSpacing.sm)
            Text(value)
                .font(AbundanceFont.caption)
                .foregroundStyle(danger ? theme.textDanger : theme.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }
}
