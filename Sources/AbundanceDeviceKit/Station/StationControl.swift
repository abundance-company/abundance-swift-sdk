import Foundation

/// Station: the device joins an ordinary Wi-Fi network and uploads finished
/// sessions itself, so the phone never carries the data. Requires `config`
/// (`metrics` for `uploadStatus`).
///
/// BETA — ships with device firmware 1.1.0. On earlier firmware these
/// endpoints throw `AbundanceError.unexpectedStatus(404)`; feature-gate on
/// `device.firmwareVersion`.
public struct StationControl: Sendable {
    private let connection: DeviceConnection

    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// Scans from the device's radio (`GET /v1/wifi/scan`). The single radio
    /// hops channels while scanning, so expect a brief SoftAP stall — not a
    /// disconnect. Refused with `.device(.recordingActive)` while a capture
    /// or preview runs.
    public func scanNetworks() async throws -> WifiScan {
        try await connection.get("/v1/wifi/scan")
    }

    /// Saves a network and joins it (`POST /v1/wifi`), blocking for up to 30
    /// seconds. The profile persists — the device rejoins on every boot — but
    /// a failed join saves nothing, so a typo never leaves the device retrying
    /// a bad credential. The SoftAP follows the uplink channel, so joining a
    /// network on another channel can briefly blip your connection.
    ///
    /// Wrong password or out of range throws `.device(.joinFailed)`.
    public func join(ssid: String, passphrase: String) async throws -> StationStatus {
        struct JoinRequest: Encodable {
            let ssid: String
            let psk: String
        }
        return try await connection.send(
            "POST", "/v1/wifi",
            body: JoinRequest(ssid: ssid, psk: passphrase)
        )
    }

    /// Saved networks, current uplink, and the SoftAP (`GET /v1/wifi`). The
    /// same information rides in the snapshot's `network` group, so a client
    /// already reading snapshots does not need this call.
    public func savedNetworksAndUplink() async throws -> WifiStatus {
        try await connection.get("/v1/wifi")
    }

    /// Forgets a saved network (`DELETE /v1/wifi/{ssid}`). If it is the
    /// current uplink the device disconnects; the SoftAP — and your
    /// connection — is unaffected.
    public func forget(ssid: String) async throws {
        struct Response: Decodable { let forgotten: Bool }
        let escaped = ssid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ssid
        let _: Response = try await connection.delete("/v1/wifi/\(escaped)")
    }

    /// Upload state and backlog (`GET /v1/upload`). Progress persists across
    /// disconnects, so the counts are accurate even for uploads that ran
    /// while no client was attached. Requires `metrics`.
    public func uploadStatus() async throws -> UploadStatus {
        try await connection.get("/v1/upload")
    }

    /// Points the device at your upload broker (`PUT /v1/upload`): one base
    /// URL and one bearer token — the device holds nothing else. Send
    /// `enabled: false` to pause without forgetting the destination.
    @discardableResult
    public func setUploadTarget(_ target: UploadTarget) async throws -> UploadTargetStatus {
        try await connection.send("PUT", "/v1/upload", body: target)
    }
}

// MARK: - Models

public struct WifiScan: Decodable, Sendable, Equatable {
    public let networks: [WifiNetwork]
    public let scannedUptimeS: Double?
}

public struct WifiNetwork: Decodable, Sendable, Equatable {
    public let ssid: String
    public let rssiDbm: Int
    public let channel: Int
    /// "2.4" | "5"
    public let band: String
    public let security: String
    /// The device already holds a profile for this network.
    public let saved: Bool
}

/// The device's uplink, as reported after a join or in `WifiStatus`.
public struct StationStatus: Decodable, Sendable, Equatable {
    public let ssid: String
    /// Closed enum: "disconnected" | "connecting" | "connected"
    public let state: String
    public let rssiDbm: Int?
    public let channel: Int?
    public let hasInternet: Bool?
}

public struct WifiStatus: Decodable, Sendable, Equatable {
    public let saved: [String]
    public let station: StationStatus?
    public let ap: AccessPoint?
}

/// The device's own SoftAP.
public struct AccessPoint: Decodable, Sendable, Equatable {
    public let ssid: String?
    public let channel: Int?
    public let widthMhz: Int?
}

/// What you configure: broker base URL + bearer token.
public struct UploadTarget: Encodable, Sendable, Equatable {
    public var enabled: Bool
    public var baseURL: URL
    public var token: String

    public init(enabled: Bool, baseURL: URL, token: String) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.token = token
    }

    private enum CodingKeys: String, CodingKey {
        // Post-camel key: the encoder converts baseUrl → base_url; a property
        // named baseURL alone would become base_u_r_l.
        case enabled
        case baseURL = "baseUrl"
        case token
    }
}

/// `PUT /v1/upload`'s confirmation.
public struct UploadTargetStatus: Decodable, Sendable, Equatable {
    public let enabled: Bool
    public let baseURL: URL?
    public let reachable: Bool?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case baseURL = "baseUrl"
        case reachable
    }
}

/// `GET /v1/upload` — state and backlog.
public struct UploadStatus: Decodable, Sendable, Equatable {
    public struct CurrentUpload: Decodable, Sendable, Equatable {
        public let sessionId: String
        public let artifact: String
        public let percent: Double
    }

    public let enabled: Bool
    public let baseURL: URL?
    /// Closed enum: "disabled" | "idle" | "waiting_network" | "paused" |
    /// "uploading" | "error"
    public let state: String?
    public let pendingSessions: Int?
    public let pendingBytes: Int64?
    public let current: CurrentUpload?
    public let lastSuccessUptimeS: Double?
    public let lastError: String?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case baseURL = "baseUrl"
        case state
        case pendingSessions
        case pendingBytes
        case current
        case lastSuccessUptimeS
        case lastError
    }
}
