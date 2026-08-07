import Foundation

/// Device-wide capture settings. Reading requires `metrics`; changing them
/// requires `config` and is refused while a recording is active.
///
/// BETA — ships with device firmware 1.1.0. On earlier firmware these
/// endpoints throw `AbundanceError.unexpectedStatus(404)`; feature-gate on
/// `device.firmwareVersion`.
public struct SettingsControl: Sendable {
    private let connection: DeviceConnection

    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// The effective capture settings (`GET /v1/settings`).
    public func current() async throws -> DeviceSettings {
        try await connection.get("/v1/settings")
    }

    /// Replaces the capture settings (`PUT /v1/settings`). The response is the
    /// full effective settings. Refused with `.device(.recordingActive)` while
    /// a capture is running.
    @discardableResult
    public func update(_ settings: DeviceSettings) async throws -> DeviceSettings {
        try await connection.send("PUT", "/v1/settings", body: settings)
    }
}

// MARK: - Models

public struct DeviceSettings: Sendable, Equatable {
    /// Local mains frequency compensated for by the camera.
    public var antiFlickerHz: AntiFlicker
    /// Recorder video bitrate in Mbps. The device accepts values from 4 to 20.
    public var videoBitrateMbps: Int
}

extension DeviceSettings: Codable {}

public enum AntiFlicker: Sendable, Equatable {
    case hz50
    case hz60
}

extension AntiFlicker: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(Int.self) {
        case 50:
            self = .hz50
        case 60:
            self = .hz60
        case let value:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unsupported anti-flicker frequency \(value)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .hz50:
            try container.encode(50)
        case .hz60:
            try container.encode(60)
        }
    }
}
