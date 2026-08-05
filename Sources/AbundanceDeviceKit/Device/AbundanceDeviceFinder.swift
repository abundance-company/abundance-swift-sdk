import Foundation
#if os(iOS)
import NetworkExtension
#endif

/// The device answering `GET /v1/health` — unauthenticated identity, usable
/// before pairing.
public struct DeviceHealth: Sendable, Equatable {
    public let deviceID: String
    public let firmwareVersion: String
    public let host: String

    public init(deviceID: String, firmwareVersion: String, host: String) {
        self.deviceID = deviceID
        self.firmwareVersion = firmwareVersion
        self.host = host
    }
}

public enum DeviceWiFiError: Error, Sendable {
    case unsupportedPlatform
    case joinFailed(String)
}

/// Gets you onto the device's network. iOS has no public Wi-Fi scan API, so
/// the flow is join-then-ask: `NEHotspotConfiguration` joins whichever
/// in-range network matches the device SSID prefix, then the fixed SoftAP
/// gateway is probed for its identity.
public enum AbundanceDeviceFinder {
    // Wire constant — the device firmware broadcasts "A4-Abundance-<id prefix>"
    // as its SoftAP name; this must match the radio, not the SDK branding.
    public static let ssidPrefix = "A4-Abundance-"
    public static let gatewayHost = "192.168.42.1"

    #if os(iOS)
    /// Asks iOS to join the in-range device network (one system confirmation
    /// dialog). The passphrase is the device's Wi-Fi password — the access
    /// credential you distribute. Requires the Hotspot Configuration
    /// entitlement.
    public static func joinDeviceNetwork(passphrase: String) async throws {
        let config = NEHotspotConfiguration(ssidPrefix: ssidPrefix, passphrase: passphrase, isWEP: false)
        config.joinOnce = false // persist so the phone re-joins on its own later
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NEHotspotConfigurationManager.shared.apply(config) { error in
                guard let error else {
                    continuation.resume()
                    return
                }
                let ns = error as NSError
                // Already on the device network — success for our purposes.
                if ns.domain == NEHotspotConfigurationErrorDomain,
                   ns.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                    continuation.resume()
                    return
                }
                continuation.resume(throwing: DeviceWiFiError.joinFailed(describe(ns)))
            }
        }
    }
    #endif

    /// `GET /v1/health` on the SoftAP gateway, retried about once a second —
    /// right after the Wi-Fi join, DHCP may not have settled yet.
    public static func probe(
        host: String = gatewayHost,
        port: Int = 8443,
        attempts: Int = 8
    ) async -> DeviceHealth? {
        guard let url = URL(string: "http://\(host):\(port)/v1/health") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.waitsForConnectivity = false
        config.allowsCellularAccess = false
        let session = URLSession(configuration: config)
        struct Health: Decodable {
            let deviceId: String
            let firmwareVersion: String
        }
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let health = try? JSONDecoder.abundance.decode(Health.self, from: data) else { continue }
            return DeviceHealth(
                deviceID: health.deviceId,
                firmwareVersion: health.firmwareVersion,
                host: host
            )
        }
        return nil
    }

    #if os(iOS)
    private static func describe(_ error: NSError) -> String {
        guard error.domain == NEHotspotConfigurationErrorDomain,
              let code = NEHotspotConfigurationError(rawValue: error.code) else {
            return error.localizedDescription
        }
        switch code {
        case .userDenied: return "Join request was cancelled."
        case .invalidWPAPassphrase: return "That doesn't look like a valid Wi-Fi password (8–63 characters)."
        case .applicationIsNotInForeground: return "Bring the app to the foreground and try again."
        case .systemConfiguration: return "This network is managed by iOS Settings — forget it there first."
        default: return "Couldn't join the device Wi-Fi (\(error.localizedDescription))."
        }
    }
    #endif
}
