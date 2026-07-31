import Foundation

/// Everything the device pushes over its live event stream, typed.
public enum AbundanceEvent: Sendable {
    /// Stream (re)established. Drain `recordings.list()` on every one — it is
    /// the authoritative backlog, so a missed nudge loses nothing.
    case connected
    /// Full snapshot: the first frame on every connect, then a heartbeat
    /// every 20 s. Apply as an idempotent merge.
    case snapshot(DeviceSnapshot)
    /// A camera, recording, preview, or SD-card transition, with a fresh
    /// snapshot. `.app` means a command caused it; `.reconciled` means the
    /// device changed on its own and the ~2 s watcher caught it.
    case stateChanged(DeviceSnapshot, source: StateSource)
    /// Post-stop publication progress in `snapshot.publishing`. Never treat
    /// 100% as done — completion is `sessionPublished`.
    case telemetry(DeviceSnapshot)
    /// A session finished publishing; every segment is offloadable.
    /// At-least-once: a device restart mid-offload re-announces with the
    /// remaining count, so treat repeats as updates.
    case sessionPublished(sessionID: String, segmentCount: Int)
    /// One segment triple finalized — a low-latency download nudge only.
    case segmentReady(SegmentRef)
    /// A failure or tripped threshold; see `EventCode`.
    case deviceError(code: EventCode, message: String, snapshot: DeviceSnapshot?)
    /// The connection dropped; the SDK is already backing off to reconnect.
    case disconnected(reason: String?)
}

/// One downloadable artifact as listed on the manifest and the
/// `segmentReady` nudge.
public struct ArtifactRef: Codable, Sendable, Equatable {
    public let name: String
    public let sizeBytes: Int64
    public let sha256: String

    public init(name: String, sizeBytes: Int64, sha256: String) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

/// A freshly finalized segment triple.
public struct SegmentRef: Decodable, Sendable, Equatable {
    public let session: String
    public let index: Int
    public let video: ArtifactRef
    public let imu: ArtifactRef
    public let frames: ArtifactRef
}

/// Wire envelope every SSE frame arrives in.
struct Envelope<T: Decodable & Sendable>: Decodable, Sendable {
    let v: Int
    let seq: Int?
    let ts: Double?
    let data: T
}

/// The `data` payload of a live frame, straight off the wire.
struct LiveFrame: Decodable, Sendable {
    let type: String
    let snapshot: DeviceSnapshot?
    let source: String?
    let code: String?
    let message: String?
    let segment: SegmentRef?
    let session: String?
    let segmentCount: Int?
}
