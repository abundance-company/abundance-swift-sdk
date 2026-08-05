import Foundation
import UIKit
import AbundanceDeviceKit

/// The paired camera and everything the UI derives from it, built entirely on
/// `AbundanceDeviceKit`: `AbundanceDevice` is the handle, `device.events` is the
/// single source of live truth, and the store just projects the latest
/// `DeviceSnapshot` (plus a short-lived optimistic overlay around start/stop)
/// into observable state every tab shares.
@MainActor
@Observable
final class DeviceStore {
    private(set) var device: AbundanceDevice?
    private(set) var snapshot: DeviceSnapshot?
    private(set) var isConnected = false
    /// One-line, non-sticky condition worth telling the operator about
    /// (a failed command, storage past its thresholds).
    private(set) var note: String?
    /// When the device was first observed recording, for the elapsed-time UI.
    /// The device reports no start timestamp, so this anchors on the observed
    /// transition; joining mid-recording leaves it nil (a wrong number would
    /// be worse than none). Only a non-recording snapshot clears it.
    private(set) var recordingSince: Date?
    /// A mid-recording pipeline interruption (`recordingInterrupted` event):
    /// the capture silently split into a new session. Sticky — cleared only by
    /// the next start() or an explicit dismissal.
    private(set) var interruption: RecordingInterruption?
    var lastError: String?

    /// Automatic backlog drain plus manual per-session downloads.
    let downloads: OffloadStore

    struct RecordingInterruption: Equatable {
        let message: String
        /// Restart count reported by the device (1 = first split this take).
        let restarts: Int
    }

    // MARK: - Record phase (device truth + optimistic overlay)

    /// The SDK's `RecordingState` has no `stopping` (stop returns when the
    /// device has stopped); the UI wants one, so the overlay adds it while a
    /// command is in flight — transiently ahead of truth, never contradicting
    /// a reported terminal state.
    enum RecordPhase: Equatable {
        case idle, starting, recording, stopping, error, unknown
    }

    private enum PendingKind { case start, stop }
    private struct PendingCommand {
        let kind: PendingKind
        let deadline: Date
    }

    private var pending: PendingCommand?

    var recordPhase: RecordPhase {
        if let pending, pending.deadline > Date() {
            return pending.kind == .start ? .starting : .stopping
        }
        switch snapshot?.recordingState {
        case .idle: return .idle
        case .starting: return .starting
        case .recording: return .recording
        case .error: return .error
        case .unknown, nil: return .unknown
        }
    }

    var isPaired: Bool { device != nil }

    private var eventTask: Task<Void, Never>?
    private var stopInFlight = false
    private let defaults: UserDefaults

    // Sample-app simplicity: credentials live in UserDefaults. They grant
    // control of the camera, so a production app should use the Keychain —
    // `AbundanceCredentials` is Codable either way.
    private static let credentialsKey = "abundance.credentials"
    private static let clientIDKey = "abundance.clientID"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        self.downloads = OffloadStore(directory: dir)
    }

    // MARK: - Pairing & reconnecting

    /// First run (or a stale token): `AbundanceDevice.pair`. Being on the device's
    /// SoftAP is the credential — pairing with the same clientID replaces this
    /// client's older tokens instead of adding a peer.
    func pair(host: String) async {
        lastError = nil
        do {
            let device = try await AbundanceDevice.pair(
                host: host,
                clientID: clientID(),
                clientName: UIDevice.current.name
            )
            persist(await device.credentials)
            adopt(device)
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Every later run: `AbundanceDevice.connect` with the stored credentials, once
    /// the radar sees the same device answering. Returns false when there is
    /// nothing stored for this device or the token no longer works — the
    /// caller falls back to the one-tap pair.
    func reconnect(to found: DeviceHealth) async -> Bool {
        guard let saved = storedCredentials(), saved.deviceID == found.deviceID else {
            return false
        }
        do {
            let refreshed = try await AbundanceDevice.connect(credentials: saved)
            persist(try await refreshed.refreshTokenIfNeeded())
            close()
            adopt(refreshed)
            return true
        } catch let error as AbundanceError {
            // Only an authoritative rejection burns the stored token; a
            // transient failure keeps it for the next probe.
            if case .device(let e) = error, e.code == .unauthorized {
                defaults.removeObject(forKey: Self.credentialsKey)
            }
            return false
        } catch {
            return false
        }
    }

    func unpair() {
        close()
        downloads.detach()
        device = nil
        snapshot = nil
        note = nil
        interruption = nil
        recordingSince = nil
        defaults.removeObject(forKey: Self.credentialsKey)
    }

    private func adopt(_ device: AbundanceDevice) {
        self.device = device
        downloads.attach(device.recordings)
        open()
    }

    // MARK: - Event stream lifecycle

    /// Opens the shared event stream. The SDK reconnects on its own with
    /// backoff; ending the loop (close) releases the connection.
    func open() {
        guard eventTask == nil, let device else { return }
        eventTask = Task {
            for await event in device.events.subscribe() {
                handle(event)
            }
        }
    }

    func close() {
        eventTask?.cancel()
        eventTask = nil
        isConnected = false
    }

    private func handle(_ event: AbundanceEvent) {
        switch event {
        case .connected:
            isConnected = true
            // The list endpoint is the authoritative backlog: drain it on
            // every (re)connect so a missed nudge loses nothing.
            downloads.drain()

        case .snapshot(let snap):
            apply(snap)

        case .stateChanged(let snap, source: _):
            apply(snap)

        case .telemetry(let snap):
            apply(snap)

        case .sessionPublished:
            downloads.drain()

        case .segmentReady:
            // A hint only — sessions become downloadable once published.
            downloads.drain()

        case .deviceError(let code, let message, let snap):
            switch code {
            case .recordingInterrupted:
                interruption = RecordingInterruption(
                    message: message.isEmpty
                        ? "The camera pipeline restarted mid-recording." : message,
                    restarts: snap?.recording?.gstRestarts
                        ?? (interruption.map { $0.restarts + 1 } ?? 1)
                )
            case .bufferWarn:
                note = "The camera's storage is 90% full."
            case .bufferFull:
                note = "The camera's storage is 97% full — stop and save soon."
            case .unknown:
                note = message
            }
            if let snap { apply(snap) }

        case .disconnected:
            isConnected = false
        }
    }

    private func apply(_ snap: DeviceSnapshot) {
        snapshot = snap
        updateRecordingAnchor()
        reconcile()
    }

    private func updateRecordingAnchor() {
        switch snapshot?.recordingState {
        case .recording, .starting:
            // `starting` counts: the app-initiated transition is pushed
            // instantly, and the first seconds of footage belong to the take.
            if recordingSince == nil { recordingSince = Date() }
        case .idle, .error:
            recordingSince = nil
        case .unknown, nil:
            break // a terminal state will clear it; unknown keeps the anchor
        }
    }

    // MARK: - Recording

    /// `recording.start()` runs the whole prescribed flow — fresh UTC anchors,
    /// then start, then background anchors every 15 s. Nothing to schedule.
    func start() async {
        guard let device else { return }
        note = nil
        interruption = nil       // new take, fresh slate
        pending = PendingCommand(kind: .start, deadline: Date().addingTimeInterval(8))
        scheduleExpiry()
        do {
            try await device.recording.start()
        } catch {
            pending = nil
            note = Self.describe(error)
        }
    }

    /// `recording.stop()` sends the closing anchors itself; an anchor failure
    /// never blocks the stop. Afterwards the device converts and publishes on
    /// its own — the `sessionPublished` event says when downloads can begin.
    func stop() async {
        guard !stopInFlight, let device else { return }
        stopInFlight = true
        defer { stopInFlight = false }
        note = nil
        pending = PendingCommand(kind: .stop, deadline: Date().addingTimeInterval(8))
        scheduleExpiry()
        do {
            try await device.recording.stop()
        } catch {
            pending = nil
            note = Self.describe(error)
        }
    }

    /// The interruption banner is sticky by design; this is the operator's
    /// explicit "I've seen it".
    func dismissInterruption() { interruption = nil }

    private func reconcile() {
        guard let p = pending else { return }
        let state = snapshot?.recordingState ?? .unknown
        switch p.kind {
        case .start:
            if state == .recording || state == .starting {
                pending = nil
            } else if state == .error {
                pending = nil
                note = "Recording didn't start."
            }
        case .stop:
            if state == .idle || state == .error {
                pending = nil
            }
        }
    }

    private func scheduleExpiry() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8.5))
            guard let self, let p = self.pending, p.deadline <= Date() else { return }
            self.pending = nil
        }
    }

    // MARK: - Credentials

    private func storedCredentials() -> AbundanceCredentials? {
        guard let data = defaults.data(forKey: Self.credentialsKey) else { return nil }
        return try? JSONDecoder().decode(AbundanceCredentials.self, from: data)
    }

    private func persist(_ credentials: AbundanceCredentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        defaults.set(data, forKey: Self.credentialsKey)
    }

    /// A stable per-install client id — the device keys the paired peer by it,
    /// so re-pairing replaces this install's token instead of evicting peers.
    private func clientID() -> String {
        if let existing = defaults.string(forKey: Self.clientIDKey) { return existing }
        let id = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        defaults.set(id, forKey: Self.clientIDKey)
        return id
    }

    // MARK: - Errors

    /// Every throwing SDK call throws `AbundanceError`; device-reported failures
    /// carry a human-readable `message` meant for display.
    static func describe(_ error: Error) -> String {
        guard let sdkError = error as? AbundanceError else { return error.localizedDescription }
        switch sdkError {
        case .device(let e):
            return e.message
        case .transport:
            return "Couldn't reach the camera — join its Wi-Fi (A4-Abundance-…) and stay on it."
        case .unexpectedStatus(let status):
            return "The camera sent an unexpected response (HTTP \(status))."
        case .decoding:
            return "The camera sent a response this app doesn't understand."
        case .hashMismatch(let artifact, _, _):
            return "\(artifact) failed hash verification — try the download again."
        case .incompatibleFirmwareRelease:
            return "This release does not support this camera model."
        case .previewProtocolViolation:
            return "Preview protocol error — update the app or the device."
        case .clockSync:
            return "UTC time synchronization failed — check the connection and try again."
        }
    }
}
