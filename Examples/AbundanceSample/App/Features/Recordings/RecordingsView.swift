import SwiftUI
import AbundanceDeviceKit

/// Recordings: the phone's library, playable in-app. Clips still on the camera
/// surface at the top (`recordings.list()`) with a Save button only when there
/// are any; a session the device marked incomplete can only be discarded.
struct RecordingsView: View {
    @Environment(DeviceStore.self) private var store
    @Environment(LocalLibraryStore.self) private var library
    @Environment(\.abundanceTheme) private var theme

    @State private var deviceSessions: [RecordingSession] = []
    @State private var playing: LocalRecording?
    /// Live Station-upload progress, polled only while Station mode has
    /// sessions in flight; `current` names the session and percent on the wire.
    @State private var uploadStatus: UploadStatus?

    var body: some View {
        AbundanceBackground {
            ScrollView {
                VStack(alignment: .leading, spacing: AbundanceSpacing.xl) {
                    if showsCameraSection {
                        cameraSection
                    }
                    librarySection
                }
                .padding(AbundanceSpacing.lg)
            }
        }
        .navigationTitle("Recordings")
        .task {
            library.refresh()
            await refreshDeviceList()
            await store.refreshStationUpload()
        }
        .refreshable {
            library.refresh()
            await refreshDeviceList()
        }
        // Downloads empty the camera as they finish; keep the list in step.
        .onChange(of: store.downloads.phases) {
            Task { await refreshDeviceList() }
        }
        // A session enters the device's list only once publishing finishes —
        // refetch the moment the publishing group appears or clears.
        .onChange(of: store.snapshot?.publishing?.sessionId) {
            Task { await refreshDeviceList() }
        }
        .onChange(of: store.publishedCount) {
            Task { await refreshDeviceList() }
        }
        // Station mode with sessions on the card: poll the uploader so rows
        // show live percent and vanish when the camera finishes.
        .task(id: stationPollActive) {
            guard stationPollActive, let device = store.device else { return }
            while !Task.isCancelled, store.stationUploadEnabled, showsCameraSection {
                uploadStatus = try? await device.station.uploadStatus()
                await refreshDeviceList()
                try? await Task.sleep(for: .seconds(2))
            }
            uploadStatus = nil
        }
        .fullScreenCover(item: $playing) { recording in
            RecordingPlayerView(recording: recording)
        }
    }

    // MARK: - on the camera

    /// The camera section also appears while a stopped session is still being
    /// processed on the device — it isn't listed by `recordings.list()` until
    /// publishing finishes, but the operator should see it exists.
    private var showsCameraSection: Bool {
        store.isPaired && (!deviceSessions.isEmpty || store.snapshot?.publishing?.sessionId != nil)
    }

    // MARK: - offload destination

    private var stationPollActive: Bool {
        store.stationUploadEnabled && showsCameraSection
    }

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: AbundanceSpacing.sm) {
            SectionHeader("On the camera")
            if let publishing = store.snapshot?.publishing, let id = publishing.sessionId {
                processingRow(publishing, id: id)
            }
            ForEach(deviceSessions) { session in
                deviceRow(session)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A just-stopped session mid-publication: live phase + percent from the
    /// snapshot's `publishing` group (pushed via telemetry events). Done is
    /// signalled by `sessionPublished` — the row then becomes a normal
    /// downloadable session below.
    private func processingRow(_ publishing: DeviceSnapshot.Publishing, id: String) -> some View {
        HStack(spacing: AbundanceSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionDisplay.title(forID: id))
                    .font(AbundanceFont.body)
                    .foregroundStyle(theme.textPrimary)
                Text(processingCaption(publishing))
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
            HStack(spacing: AbundanceSpacing.xs) {
                if let percent = publishing.percent {
                    Text("\(Int(percent))%")
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textAccentOcean)
                        .monospacedDigit()
                }
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, AbundanceSpacing.xxs)
    }

    private func processingCaption(_ publishing: DeviceSnapshot.Publishing) -> String {
        if let phase = publishing.phase, !phase.isEmpty {
            return "Processing on the camera · \(phase)"
        }
        return "Processing on the camera"
    }

    private func deviceRow(_ session: RecordingSession) -> some View {
        VStack(alignment: .leading, spacing: AbundanceSpacing.xxs) {
            HStack(spacing: AbundanceSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SessionDisplay.title(forID: session.id))
                        .font(AbundanceFont.body)
                        .foregroundStyle(theme.textPrimary)
                    Text(subtitle(for: session))
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer()
                deviceRowControl(session)
            }
            if case .failed(let message)? = store.downloads.phase(for: session.id) {
                Text(message)
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textDanger)
            }
        }
        .padding(.vertical, AbundanceSpacing.xxs)
    }

    private func subtitle(for session: RecordingSession) -> String {
        let base = "\(session.segmentCount) clip\(session.segmentCount == 1 ? "" : "s") · \(format(bytes: session.totalBytes))"
        if session.state == .incomplete {
            return base + " · incomplete"
        }
        return base
    }

    @ViewBuilder private func deviceRowControl(_ session: RecordingSession) -> some View {
        if store.stationUploadEnabled {
            // Station mode: the camera uploads and deletes these itself. No
            // Save (a local copy contradicts the chosen destination) and no
            // Discard (the device refuses deletion-bearing calls anyway).
            if let current = uploadStatus?.current, current.sessionId == session.id {
                HStack(spacing: AbundanceSpacing.xs) {
                    Text("\(Int(current.percent))%")
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textAccentOcean)
                        .monospacedDigit()
                    ProgressView(value: min(current.percent, 100), total: 100)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(theme.textAccentOcean)
                }
            } else {
                Text("→ Station")
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textAccentOcean)
            }
        } else if session.state == .incomplete {
            Button("Discard") {
                Task {
                    _ = await store.downloads.discard(session.id)
                    await refreshDeviceList()
                }
            }
            .font(AbundanceFont.label)
            .foregroundStyle(theme.textDanger)
        } else {
            switch store.downloads.phase(for: session.id) {
            case .preparing:
                ProgressView().controlSize(.small)
            case .downloading(let done, let total):
                HStack(spacing: AbundanceSpacing.xs) {
                    Text("\(done)/\(total)")
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textAccentOcean)
                        .monospacedDigit()
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                    Button {
                        store.downloads.cancel(session.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            case .finished:
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(AbundanceFont.label)
                    .foregroundStyle(theme.textAccentOcean)
            case .failed, nil:
                Button {
                    store.downloads.download(session)
                } label: {
                    Text(store.downloads.phase(for: session.id) == nil ? "Save" : "Retry")
                        .font(AbundanceFont.label)
                        .foregroundStyle(theme.textInverse)
                        .padding(.horizontal, AbundanceSpacing.sm)
                        .padding(.vertical, AbundanceSpacing.xxs + 2)
                        .background(theme.bgPrimary, in: Capsule())
                }
            }
        }
    }

    // MARK: - on this phone

    @ViewBuilder private var librarySection: some View {
        if library.recordings.isEmpty {
            VStack(spacing: AbundanceSpacing.xs) {
                Image(systemName: "film.stack")
                    .font(.system(size: 34))
                    .foregroundStyle(theme.textTertiary)
                Text("No recordings yet")
                    .font(AbundanceFont.titleSmall)
                    .foregroundStyle(theme.textPrimary)
                Text("Clips you save from the camera appear here.")
                    .font(AbundanceFont.caption)
                    .foregroundStyle(theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, AbundanceSpacing.xl * 2)
        } else {
            VStack(alignment: .leading, spacing: AbundanceSpacing.sm) {
                if showsCameraSection {
                    SectionHeader("On this iPhone")
                }
                ForEach(library.recordings) { recording in
                    libraryRow(recording)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func libraryRow(_ recording: LocalRecording) -> some View {
        Button {
            playing = recording
        } label: {
            HStack(spacing: AbundanceSpacing.sm) {
                thumbnail(recording)
                VStack(alignment: .leading, spacing: AbundanceSpacing.xxs) {
                    Text(recording.title)
                        .font(AbundanceFont.body)
                        .foregroundStyle(theme.textPrimary)
                    Text("\(recording.clipCount) clip\(recording.clipCount == 1 ? "" : "s") · \(format(bytes: recording.totalBytes))")
                        .font(AbundanceFont.caption)
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer()
            }
            .padding(.vertical, AbundanceSpacing.xxs)
        }
        .buttonStyle(.plain)
        .task { library.requestThumbnail(for: recording) }
        .contextMenu {
            Button(role: .destructive) {
                library.delete(recording)
            } label: {
                Label("Delete from iPhone", systemImage: "trash")
            }
        }
    }

    private func thumbnail(_ recording: LocalRecording) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = library.thumbnails[recording.id] {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        theme.surfaceOverlay
                        Image(systemName: "film")
                            .font(.system(size: 20))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            .frame(width: 112, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: AbundanceRadius.sm, style: .continuous))

            if let seconds = recording.durationSeconds {
                Text(RecordingTimerText.format(seconds))
                    .font(AbundanceFont.label)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, AbundanceSpacing.xxs + 2)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(AbundanceSpacing.xxs)
            }
        }
    }

    // MARK: - helpers

    private func refreshDeviceList() async {
        guard let device = store.device else {
            deviceSessions = []
            return
        }
        // Off the camera's Wi-Fi this fails fast — the section simply hides.
        deviceSessions = (try? await device.recordings.list()) ?? []
    }

    private func format(bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
