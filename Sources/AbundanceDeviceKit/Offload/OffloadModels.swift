import Foundation

/// One session as listed by `GET /v1/recordings`.
public struct RecordingSession: Sendable, Equatable, Identifiable {
    public let id: String
    public let segmentCount: Int
    /// Artifact bytes for a ready session; the whole directory tree (what a
    /// discard reclaims) for an incomplete one.
    public let totalBytes: Int64
    public let state: SessionState
    /// Why the session is incomplete; absent when ready.
    public let reason: String?
}

/// The session's record (`GET /v1/recordings/{id}/manifest`): what was
/// recorded, how accurate its timing is, and the hash of every file. Store it
/// before downloading anything — every later verification is against this,
/// and once the last segment is acked the device's copy is gone.
public struct RecordingManifest: Decodable, Sendable, Equatable {
    public let version: Int
    public let state: ManifestState
    public let sessionID: String
    /// Boot recovery published this session (the open tail was dropped and
    /// the end anchor synthesized).
    public let recovered: Bool
    public let droppedSegmentIndices: [Int]
    /// Bounds the error on every timestamp in the session's IMU and frame
    /// CSVs — both anchoring and clock-fit error sources.
    public let utcAccuracyNanoseconds: Int64
    /// The sensor-delay offset has been applied to the IMU CSV; false means a
    /// known systematic bias is still uncorrected.
    public let absoluteUVCLatencyCalibrated: Bool
    /// The exact correction applied. Invertible: the raw FPGA column is
    /// untouched, so subtracting this returns the uncorrected value.
    public let imuTimeOffsetNanoseconds: Int64
    public let deviceId: String
    public let factoryUuid: String
    public let cameraFirmwareVersion: String
    public let nanopiFirmwareVersion: String
    public let videoBitrateMbps: Int
    public let segments: [SegmentInfo]

    private enum CodingKeys: String, CodingKey {
        // Post-snake-conversion key names (the decoder maps utc_accuracy_ns
        // → utcAccuracyNs before matching).
        case version
        case state
        case sessionId
        case recovered
        case droppedSegmentIndices
        case utcAccuracyNs
        case absoluteUvcLatencyCalibrated
        case imuTimeOffsetNs
        case deviceId
        case factoryUuid
        case cameraFirmwareVersion
        case nanopiFirmwareVersion
        case videoBitrateMbps
        case segments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        state = ManifestState(try container.decode(String.self, forKey: .state))
        sessionID = try container.decode(String.self, forKey: .sessionId)
        recovered = try container.decode(Bool.self, forKey: .recovered)
        droppedSegmentIndices = try container.decode([Int].self, forKey: .droppedSegmentIndices)
        utcAccuracyNanoseconds = try container.decode(Int64.self, forKey: .utcAccuracyNs)
        absoluteUVCLatencyCalibrated = try container.decode(Bool.self, forKey: .absoluteUvcLatencyCalibrated)
        imuTimeOffsetNanoseconds = try container.decode(Int64.self, forKey: .imuTimeOffsetNs)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        factoryUuid = try container.decode(String.self, forKey: .factoryUuid)
        cameraFirmwareVersion = try container.decode(String.self, forKey: .cameraFirmwareVersion)
        nanopiFirmwareVersion = try container.decode(String.self, forKey: .nanopiFirmwareVersion)
        videoBitrateMbps = try container.decode(Int.self, forKey: .videoBitrateMbps)
        segments = try container.decode([SegmentInfo].self, forKey: .segments)
    }
}

/// One segment's downloadable triple, as listed on the manifest.
public struct SegmentInfo: Decodable, Sendable, Equatable, Identifiable {
    public let index: Int
    public let video: ArtifactRef
    public let imu: ArtifactRef
    public let frames: ArtifactRef

    public var id: Int { index }
}

/// What one segment fetch left on disk, verified.
public struct SegmentFiles: Sendable, Equatable {
    public let videoURL: URL
    public let imuURL: URL
    public let framesURL: URL
}

/// One finalized per-session log artifact (`GET /v1/recordings/{id}/logs`).
public struct LogArtifact: Sendable, Equatable, Decodable {
    public let name: String
    public let sizeBytes: Int64
    public let sha256: String
}

/// Progress of the whole-session courier.
public struct OffloadProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case manifest
        case segment(Int)
        case log(String)
        case done
    }

    public let sessionID: String
    public let phase: Phase
    /// The artifact currently transferring; nil on ack and done events.
    public let artifactName: String?
    public let bytesReceived: Int64
    public let totalBytes: Int64
    /// True once the phase's artifacts are acked — the device's copy is gone.
    public let acked: Bool
}
