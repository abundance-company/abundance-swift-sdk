import Foundation

// Every state on the wire is a closed string enum, and every one of them
// decodes future firmware's unrecognized values to `.unknown` instead of
// failing the parse — the contract's forward-compatibility rule.

/// Camera physical-layer state (`camera.state`).
public enum CameraState: String, Sendable, Equatable {
    case absent, detected, ready, unknown
    public init(_ raw: String?) { self = CameraState(rawValue: raw ?? "") ?? .unknown }
}

/// Recorder lifecycle (`recording.state`). `.error` is wedged; the field
/// recovery is a device reboot.
public enum RecordingState: String, Sendable, Equatable {
    case idle, starting, recording, error, unknown
    public init(_ raw: String?) { self = RecordingState(rawValue: raw ?? "") ?? .unknown }
}

/// Preview pipeline state (`stream.state`).
public enum StreamState: String, Sendable, Equatable {
    case idle, starting, streaming, error, unknown
    public init(_ raw: String?) { self = StreamState(rawValue: raw ?? "") ?? .unknown }
}

/// Post-stop publication progress (`publishing.phase`). Strictly ordered;
/// completion arrives as the `sessionPublished` event, never as 100%.
public enum PublishingPhase: String, Sendable, Equatable {
    case preparing, loading, fitting, converting, finalizing, unknown
    public init(_ raw: String?) { self = PublishingPhase(rawValue: raw ?? "") ?? .unknown }
}

/// A listed session's offloadability (`recordings[].state`). `.incomplete`
/// can never be acked — discard is the only way to reclaim its space.
public enum SessionState: String, Sendable, Equatable {
    case ready, incomplete, unknown
    public init(_ raw: String?) { self = SessionState(rawValue: raw ?? "") ?? .unknown }
}

/// `manifest.state` — `published` is the only value the endpoint serves.
public enum ManifestState: String, Sendable, Equatable {
    case published, unknown
    public init(_ raw: String?) { self = ManifestState(rawValue: raw ?? "") ?? .unknown }
}

/// Who caused a `stateChanged` event: a command (`.app`, pushed instantly) or
/// the device on its own (`.reconciled`, caught by the ~2 s watcher poll).
public enum StateSource: String, Sendable, Equatable {
    case app, reconciled, unknown
    public init(_ raw: String?) { self = StateSource(rawValue: raw ?? "") ?? .unknown }
}

/// Event-stream error namespace (`data.code`) — separate from the HTTP
/// `ErrorCode` table.
public enum EventCode: Sendable, Hashable {
    /// The recorder pipeline crash-restarted, silently splitting the capture
    /// into a new session.
    case recordingInterrupted
    /// Recording storage passed 90% full. One-shot; re-arms below 90%.
    case bufferWarn
    /// Recording storage passed 97% full. Recording is not stopped
    /// automatically.
    case bufferFull
    case unknown(String)

    public init(_ raw: String) {
        switch raw {
        case "recording_interrupted": self = .recordingInterrupted
        case "buffer_warn": self = .bufferWarn
        case "buffer_full": self = .bufferFull
        default: self = .unknown(raw)
        }
    }
}

/// What a paired token may reach. Each manager documents the capability it
/// requires; a token without it gets `403 capability_denied`.
public enum Capability: Sendable, Hashable, Codable {
    case metrics
    case control
    case config
    case offload
    case unknown(String)

    public init(_ raw: String) {
        switch raw {
        case "metrics": self = .metrics
        case "control": self = .control
        case "config": self = .config
        case "offload": self = .offload
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .metrics: "metrics"
        case .control: "control"
        case .config: "config"
        case .offload: "offload"
        case .unknown(let raw): raw
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
