import Foundation

/// Everything needed to re-attach to a paired device. `Codable` and yours to
/// persist — Keychain, `UserDefaults`, wherever; the SDK never stores it.
public struct AbundanceCredentials: Codable, Sendable, Equatable {
    public let deviceID: String
    public let host: String
    public let port: Int
    public let sessionToken: String
    public let tokenExpiresAt: Date
    public let capabilities: Set<Capability>

    public init(
        deviceID: String,
        host: String,
        port: Int = 8443,
        sessionToken: String,
        tokenExpiresAt: Date,
        capabilities: Set<Capability>
    ) {
        self.deviceID = deviceID
        self.host = host
        self.port = port
        self.sessionToken = sessionToken
        self.tokenExpiresAt = tokenExpiresAt
        self.capabilities = capabilities
    }

    var baseURL: URL {
        // host/port come from pairing, which already built and used this URL.
        guard let url = URL(string: "http://\(host):\(port)") else {
            preconditionFailure("unbuildable base URL for host \(host)")
        }
        return url
    }
}
