import Foundation

/// Start and stop capture. Recording runs on the device — the app can
/// disconnect mid-session and the capture continues. Requires `control`.
///
/// The clock is handled for you: `start()` sends fresh UTC anchors before
/// starting and keeps them topped up in the background while recording;
/// `stop()` sends the closing anchors that date the session's tail.
public struct RecordingControl: Sendable {
    private let connection: DeviceConnection
    private let clock: RecordingClock

    init(connection: DeviceConnection, time: TimeSync) {
        self.connection = connection
        self.clock = RecordingClock(time: time)
    }

    /// The full prescribed flow in one call: three fresh time anchors, then
    /// `POST /v1/recording/start` (the gate requires an anchor ≤ 30 s old on
    /// the current boot). While recording, anchors keep flowing every 15 s so
    /// long sessions still get a tight clock fit.
    ///
    /// Idempotent: `changed: false` means the device was already recording —
    /// a result, not an error. Pre-gates surface as retryable
    /// `.device(.timeNotSynced / .cameraAbsent / .sdAbsent)`.
    @discardableResult
    public func start() async throws -> RecordingChange {
        try await clock.syncForStart()
        let wire: WireRecordingChange = try await connection.post("/v1/recording/start")
        await clock.beginMaintenance()
        return RecordingChange(changed: wire.changed, state: RecordingState(wire.state))
    }

    /// Closing anchors first — they close the clock fit that dates every
    /// timestamp in the session — then `POST /v1/recording/stop`. The device
    /// converts and publishes on its own afterwards: watch `telemetry` events
    /// for progress and `sessionPublished` for done.
    @discardableResult
    public func stop() async throws -> RecordingChange {
        await clock.endMaintenance()
        await clock.syncBestEffort()
        let wire: WireRecordingChange = try await connection.post("/v1/recording/stop")
        return RecordingChange(changed: wire.changed, state: RecordingState(wire.state))
    }
}

/// Both recording calls' result: `changed: true` means a transition began
/// (202), `false` means the device was already in that state (200).
public struct RecordingChange: Sendable, Equatable {
    public let changed: Bool
    public let state: RecordingState
}

private struct WireRecordingChange: Decodable {
    let changed: Bool
    let state: String
}

/// Owns the recording's clock plumbing: pre-start sync, the background
/// anchor cadence while recording, and the best-effort closing sync.
actor RecordingClock {
    private let time: TimeSync
    private var maintenance: Task<Void, Never>?

    init(time: TimeSync) {
        self.time = time
    }

    func syncForStart() async throws {
        do {
            try await time.sync()
        } catch let failure as TimeSynchronizationError {
            throw AbundanceError.clockSync(String(describing: failure))
        }
    }

    func syncBestEffort() async {
        // A failed closing anchor degrades the fit's tail; a blocked stop
        // loses the operator's control of the device. Stop always wins.
        _ = try? await time.sync()
    }

    func beginMaintenance() {
        guard maintenance == nil else { return }
        let time = time
        // Deliberately not tied to observed device state: extra anchors after
        // an external stop are harmless (per-boot, capped device-side), while
        // watching for one would couple recording control to the event stream.
        maintenance = Task { await time.maintainAnchors() }
    }

    func endMaintenance() {
        maintenance?.cancel()
        maintenance = nil
    }
}
