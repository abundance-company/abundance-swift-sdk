import Foundation

/// Everything the device knows about itself, in one object — returned by
/// `GET /v1/status` and carried in event-stream frames.
///
/// Every group except `meta` is optional: a group the device cannot read is
/// omitted or null, never a fabricated zero.
public struct DeviceSnapshot: Decodable, Sendable, Equatable {
    public var meta: Meta?
    public var camera: Camera?
    public var storage: Storage?
    public var recording: Recording?
    public var publishing: Publishing?
    public var stream: Stream?
    public var network: Network?

    public struct Meta: Decodable, Sendable, Equatable {
        public var bootId: String?
        public var deviceUptimeS: Double?
        public var timeSynced: Bool?
    }

    public struct Camera: Decodable, Sendable, Equatable {
        public var state: String?
        public var devicePath: String?
        /// Daemon-observed presence; resets when the device's service restarts.
        public var uptimeS: Double?
    }

    public struct Storage: Decodable, Sendable, Equatable {
        public var recordTarget: String?
        public var volumes: [Volume]?

        public struct Volume: Decodable, Sendable, Equatable {
            public var mountpoint: String?
            public var mounted: Bool?
            public var uptimeS: Double?
            public var totalBytes: Int64?
            public var freeBytes: Int64?
            public var usedBytes: Int64?
            public var usedPct: Double?
        }
    }

    public struct Recording: Decodable, Sendable, Equatable {
        public var state: String?
        /// The recorder is installed — not that it can start right now. The
        /// real start conditions come back as errors from `recording.start()`.
        public var available: Bool?
        public var segmentSeconds: Int?
        public var segmentsOnDisk: Int?
        public var currentSegment: CurrentSegment?
        public var source: String?
        public var errorCode: String?
        public var errorMsg: String?
        public var sessionId: String?
        /// Seconds since this session's recording began.
        public var uptimeS: Double?
        /// Mid-recording pipeline restarts — each one split the capture into a
        /// new session.
        public var gstRestarts: Int?
        public var lastError: String?

        public struct CurrentSegment: Decodable, Sendable, Equatable {
            public var name: String?
            public var index: Int?
            public var sizeBytes: Int64?
        }
    }

    /// Present only while a stopped session is being processed; completion
    /// arrives as the `sessionPublished` event, never as 100%.
    public struct Publishing: Decodable, Sendable, Equatable {
        public var sessionId: String?
        public var phase: String?
        public var percent: Double?
    }

    public struct Stream: Decodable, Sendable, Equatable {
        public var state: String?
        public var available: Bool?
        public var port: Int?
    }

    /// Station uplink status (firmware 1.1.0+); nil on earlier firmware.
    public struct Network: Decodable, Sendable, Equatable {
        public var station: StationStatus?
        public var ap: AccessPoint?
    }
}

public extension DeviceSnapshot {
    var cameraState: CameraState { CameraState(camera?.state) }
    var recordingState: RecordingState { RecordingState(recording?.state) }
    var streamState: StreamState { StreamState(stream?.state) }
    var publishingPhase: PublishingPhase? { publishing.map { PublishingPhase($0.phase) } }
}

/// `GET /v1/capabilities` — the compatibility gate: identity, firmware, and
/// what the token may reach.
public struct DeviceIdentity: Sendable, Equatable {
    public let deviceID: String
    public let firmwareVersion: String
    public let capabilities: Set<Capability>
}

extension JSONDecoder {
    /// Decoder configured for the device's snake_case wire format.
    static var abundance: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

extension JSONEncoder {
    /// Encoder matching `JSONDecoder.abundance`.
    static var abundance: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
}
