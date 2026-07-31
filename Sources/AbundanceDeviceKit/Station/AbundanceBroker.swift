import Foundation

/// The Station upload broker contract — the three calls the *device* makes to
/// *your* service. You implement the server; these types are both sides of
/// that exchange, `Codable` and Foundation-only so they work server-side.
///
/// The flow, idempotent by session id:
/// 1. **Announce** — `POST {base_url}/sessions` with a `SessionAnnouncement`;
///    you reply with an `UploadPlan` (a destination per artifact + a
///    completion URL). Destinations are opaque to the device — presigned S3,
///    your own endpoints, anything. Omit an artifact and the device treats it
///    as already held (how a retry skips what landed).
/// 2. **Upload** — one `PUT` per artifact, serial, largest last, each with
///    `X-Abundance-SHA256`. Your 2xx means you verified the bytes.
/// 3. **Complete** — `POST {complete_url}` with a `CompletionReport`. Your
///    200 permits deletion; reply 409 with the missing names for a partial
///    re-upload.
///
/// Every device request carries `Authorization: Bearer <your token>` and
/// `X-Abundance-Device-Id`. A device that crashes mid-upload re-announces the
/// same session — treat a repeat as a request for fresh destinations.
public enum AbundanceBroker {
    // MARK: - Step 1 · announce

    /// What the device sends to `POST {base_url}/sessions`: its whole
    /// manifest plus identity.
    public struct SessionAnnouncement: Codable, Sendable, Equatable {
        public let sessionID: String
        public let deviceID: String
        public let firmwareVersion: String
        public let utcAccuracyNanoseconds: Int64
        public let absoluteUVCLatencyCalibrated: Bool
        public let imuTimeOffsetNanoseconds: Int64
        public let recovered: Bool
        public let droppedSegmentIndices: [Int]
        public let segments: [AnnouncedSegment]
        public let logs: [AnnouncedArtifact]

        public init(
            sessionID: String,
            deviceID: String,
            firmwareVersion: String,
            utcAccuracyNanoseconds: Int64,
            absoluteUVCLatencyCalibrated: Bool,
            imuTimeOffsetNanoseconds: Int64,
            recovered: Bool,
            droppedSegmentIndices: [Int],
            segments: [AnnouncedSegment],
            logs: [AnnouncedArtifact]
        ) {
            self.sessionID = sessionID
            self.deviceID = deviceID
            self.firmwareVersion = firmwareVersion
            self.utcAccuracyNanoseconds = utcAccuracyNanoseconds
            self.absoluteUVCLatencyCalibrated = absoluteUVCLatencyCalibrated
            self.imuTimeOffsetNanoseconds = imuTimeOffsetNanoseconds
            self.recovered = recovered
            self.droppedSegmentIndices = droppedSegmentIndices
            self.segments = segments
            self.logs = logs
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case deviceID = "device_id"
            case firmwareVersion = "firmware_version"
            case utcAccuracyNanoseconds = "utc_accuracy_ns"
            case absoluteUVCLatencyCalibrated = "absolute_uvc_latency_calibrated"
            case imuTimeOffsetNanoseconds = "imu_time_offset_ns"
            case recovered
            case droppedSegmentIndices = "dropped_segment_indices"
            case segments
            case logs
        }
    }

    public struct AnnouncedSegment: Codable, Sendable, Equatable {
        public let index: Int
        public let video: AnnouncedArtifact
        public let imu: AnnouncedArtifact
        public let frames: AnnouncedArtifact

        public init(index: Int, video: AnnouncedArtifact, imu: AnnouncedArtifact, frames: AnnouncedArtifact) {
            self.index = index
            self.video = video
            self.imu = imu
            self.frames = frames
        }
    }

    /// `{name, bytes, sha256}` — the announce spelling (the local manifest
    /// uses `size_bytes`; the broker wire uses `bytes`).
    public struct AnnouncedArtifact: Codable, Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public let sha256: String

        public init(name: String, bytes: Int64, sha256: String) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
        }

        /// The Content-Type the device sends when uploading this artifact.
        public var contentType: String {
            if name.hasSuffix(".ts") { return "video/mp2t" }
            if name.hasSuffix(".csv") { return "text/csv" }
            if name.hasSuffix(".json") { return "application/json" }
            return "text/plain"
        }
    }

    // MARK: - Step 1 · your reply

    /// Your response to an announce: one destination per artifact you still
    /// need, plus where the device reports completion. `expiresAt` lets you
    /// keep destinations short-lived; if they expire mid-transfer the device
    /// re-announces.
    public struct UploadPlan: Codable, Sendable, Equatable {
        public var uploads: [ArtifactDestination]
        public var completeURL: URL
        public var expiresAt: Date?

        public init(uploads: [ArtifactDestination], completeURL: URL, expiresAt: Date? = nil) {
            self.uploads = uploads
            self.completeURL = completeURL
            self.expiresAt = expiresAt
        }

        private enum CodingKeys: String, CodingKey {
            case uploads
            case completeURL = "complete_url"
            case expiresAt = "expires_at"
        }
    }

    public struct ArtifactDestination: Codable, Sendable, Equatable {
        public var name: String
        public var method: String
        public var url: URL
        public var headers: [String: String]

        public init(name: String, method: String = "PUT", url: URL, headers: [String: String] = [:]) {
            self.name = name
            self.method = method
            self.url = url
            self.headers = headers
        }
    }

    // MARK: - Step 3 · complete

    /// What the device posts to `complete_url`: every artifact it uploaded
    /// and the hash it sent.
    public struct CompletionReport: Codable, Sendable, Equatable {
        public let sessionID: String
        public let uploaded: [UploadedArtifact]

        public init(sessionID: String, uploaded: [UploadedArtifact]) {
            self.sessionID = sessionID
            self.uploaded = uploaded
        }

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case uploaded
        }
    }

    public struct UploadedArtifact: Codable, Sendable, Equatable {
        public let name: String
        public let sha256: String

        public init(name: String, sha256: String) {
            self.name = name
            self.sha256 = sha256
        }
    }

    /// Your 200 body. "Safe to delete" is a decision you make once, here —
    /// not something inferred from individual PUT responses.
    public struct CompletionResponse: Codable, Sendable, Equatable {
        public var confirmed: Bool

        public init(confirmed: Bool) {
            self.confirmed = confirmed
        }
    }

    // MARK: - Coders

    /// Pre-configured for the broker wire: explicit snake_case keys,
    /// unix-seconds dates.
    public static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}
