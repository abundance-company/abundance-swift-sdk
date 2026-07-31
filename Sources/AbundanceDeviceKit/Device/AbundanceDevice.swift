import Foundation

/// The handle everything hangs off. Get one with `pair` (first run) or
/// `connect` (every later run), then use the capability managers.
public actor AbundanceDevice {
    public nonisolated let deviceID: String
    public nonisolated let firmwareVersion: String
    public nonisolated let grantedCapabilities: Set<Capability>

    /// Live event stream — requires `metrics`.
    public nonisolated let events: DeviceEvents
    /// Start/stop capture, clock anchoring included — requires `control`.
    public nonisolated let recording: RecordingControl
    /// Live viewfinder — requires `control`.
    public nonisolated let preview: PreviewStream
    /// Session offload, logs, discard — requires `offload`.
    public nonisolated let recordings: SessionOffload
    /// Wi-Fi uplink + upload broker settings — requires `config`,
    /// firmware ≥ 1.1.0.
    public nonisolated let station: StationControl
    /// Storage breakdown, reboot, shutdown, SD eject — requires `control`
    /// (`metrics` for storage).
    public nonisolated let maintenance: Maintenance

    private let connection: DeviceConnection
    private var storedCredentials: AbundanceCredentials

    private init(connection: DeviceConnection, credentials: AbundanceCredentials, firmwareVersion: String) {
        self.connection = connection
        self.storedCredentials = credentials
        self.deviceID = credentials.deviceID
        self.firmwareVersion = firmwareVersion
        self.grantedCapabilities = credentials.capabilities
        self.recording = RecordingControl(connection: connection, time: TimeSync(connection: connection))
        self.events = DeviceEvents(broadcaster: EventBroadcaster(connection: connection))
        self.preview = PreviewStream(connection: connection)
        self.recordings = SessionOffload(connection: connection)
        self.station = StationControl(connection: connection)
        self.maintenance = Maintenance(connection: connection)
    }

    // MARK: - Entry points

    /// First run: pairs this client and returns a live handle. Being on the
    /// device's SoftAP is the access check — there is no other secret.
    ///
    /// `clientID` must survive app restarts: pairing again with the same id
    /// replaces this client's older tokens (how you recover from a lost
    /// token), while a different id adds a peer — the device holds 8 and
    /// evicts the oldest.
    public static func pair(
        host: String,
        port: Int = 8443,
        clientID: String,
        clientName: String
    ) async throws -> AbundanceDevice {
        let connection = DeviceConnection(baseURL: baseURL(host: host, port: port), token: nil)
        struct PairRequest: Encodable {
            let clientId: String
            let clientName: String
        }
        struct PairResponse: Decodable {
            let deviceId: String
            let firmwareVersion: String
            let sessionToken: String
            let tokenExpiresAt: Int64
            let capabilities: [String]
        }
        let response: PairResponse = try await connection.send(
            "POST", "/v1/pair",
            body: PairRequest(clientId: clientID, clientName: clientName)
        )
        await connection.setToken(response.sessionToken)
        let credentials = AbundanceCredentials(
            deviceID: response.deviceId,
            host: host,
            port: port,
            sessionToken: response.sessionToken,
            tokenExpiresAt: Date(timeIntervalSince1970: TimeInterval(response.tokenExpiresAt)),
            capabilities: Set(response.capabilities.map(Capability.init))
        )
        return AbundanceDevice(
            connection: connection,
            credentials: credentials,
            firmwareVersion: response.firmwareVersion
        )
    }

    /// Every later run: re-attaches with stored credentials. The fail-fast
    /// gate — one authenticated `GET /v1/capabilities` proves the device is
    /// reachable, the token is live, and reads firmware + granted
    /// capabilities before any other call.
    ///
    /// Throws `.device(.unauthorized)` when the token has expired — pair
    /// again with the same `clientID` to replace it.
    public static func connect(credentials: AbundanceCredentials) async throws -> AbundanceDevice {
        let connection = DeviceConnection(
            baseURL: credentials.baseURL,
            token: credentials.sessionToken
        )
        let identity: WireIdentity = try await connection.get("/v1/capabilities")
        guard identity.deviceId == credentials.deviceID else {
            // A different device answering on the same gateway IP must not be
            // silently adopted under the stored identity.
            throw AbundanceError.transport(
                "device at \(credentials.host) is \(identity.deviceId), not the paired \(credentials.deviceID)"
            )
        }
        let refreshed = AbundanceCredentials(
            deviceID: credentials.deviceID,
            host: credentials.host,
            port: credentials.port,
            sessionToken: credentials.sessionToken,
            tokenExpiresAt: credentials.tokenExpiresAt,
            capabilities: Set(identity.capabilities.map(Capability.init))
        )
        return AbundanceDevice(
            connection: connection,
            credentials: refreshed,
            firmwareVersion: identity.firmwareVersion
        )
    }

    // MARK: - Credentials

    /// The current credentials, including any refreshed token — persist these
    /// after `refreshToken`.
    public var credentials: AbundanceCredentials { storedCredentials }

    /// Issues a new session token with the same capabilities and a later
    /// expiry (`POST /v1/token/refresh`). Tokens last 30 days.
    @discardableResult
    public func refreshToken() async throws -> AbundanceCredentials {
        struct RefreshResponse: Decodable {
            let sessionToken: String
            let tokenExpiresAt: Int64
            let capabilities: [String]
        }
        let response: RefreshResponse = try await connection.post("/v1/token/refresh")
        await connection.setToken(response.sessionToken)
        storedCredentials = AbundanceCredentials(
            deviceID: storedCredentials.deviceID,
            host: storedCredentials.host,
            port: storedCredentials.port,
            sessionToken: response.sessionToken,
            tokenExpiresAt: Date(timeIntervalSince1970: TimeInterval(response.tokenExpiresAt)),
            capabilities: Set(response.capabilities.map(Capability.init))
        )
        return storedCredentials
    }

    /// Refreshes only when the token expires within `margin` (default 7
    /// days) — call on every launch and persist the result.
    @discardableResult
    public func refreshTokenIfNeeded(
        expiringWithin margin: Duration = .seconds(7 * 86_400)
    ) async throws -> AbundanceCredentials {
        let horizon = Date.now.addingTimeInterval(TimeInterval(margin.components.seconds))
        guard storedCredentials.tokenExpiresAt <= horizon else { return storedCredentials }
        return try await refreshToken()
    }

    // MARK: - Device-level calls

    /// The full device state in one response (`GET /v1/status`). Requires
    /// `metrics`.
    public func status() async throws -> DeviceSnapshot {
        try await connection.get("/v1/status")
    }

    /// Identity + granted capabilities (`GET /v1/capabilities`) — the
    /// compatibility gate. Requires `metrics`.
    public func identity() async throws -> DeviceIdentity {
        let identity: WireIdentity = try await connection.get("/v1/capabilities")
        return DeviceIdentity(
            deviceID: identity.deviceId,
            firmwareVersion: identity.firmwareVersion,
            capabilities: Set(identity.capabilities.map(Capability.init))
        )
    }

    /// Tail of the device's black-box event log (`GET /v1/device-log`),
    /// oldest first. Diagnostic text, not a stable contract — display it,
    /// don't parse it. `lines` is 1...500. Requires `metrics`.
    public func deviceLog(lines: Int = 100) async throws -> [String] {
        struct Response: Decodable { let lines: [String] }
        let response: Response = try await connection.get("/v1/device-log?n=\(lines)")
        return response.lines
    }

    private static func baseURL(host: String, port: Int) -> URL {
        guard let url = URL(string: "http://\(host):\(port)") else {
            preconditionFailure("unbuildable base URL for host \(host)")
        }
        return url
    }
}

private struct WireIdentity: Decodable {
    let deviceId: String
    let firmwareVersion: String
    let capabilities: [String]
}
