import Foundation

/// Whole-device actions and storage accounting. Reboot, shutdown, and eject
/// all refuse with `.device(.recordingActive)` while a capture runs — stop it
/// explicitly first. Requires `control` (`metrics` for storage).
public struct Maintenance: Sendable {
    private let connection: DeviceConnection

    init(connection: DeviceConnection) {
        self.connection = connection
    }

    /// What is using space on the recording volume (`GET /v1/storage`):
    /// top-level entries, largest first, including everything the device did
    /// not write itself. Diagnostic, not contract — display entry names,
    /// don't build logic on them.
    ///
    /// Results are cached for 60 s; pass `refresh: true` after freeing space
    /// (a rescan is real SD I/O).
    public func storage(refresh: Bool = false) async throws -> StorageBreakdown {
        try await connection.get(refresh ? "/v1/storage?refresh=1" : "/v1/storage")
    }

    /// Reboots the device (`POST /v1/device/reboot`). The response returns
    /// before the reboot fires (~1.5 s later); treat what follows as any
    /// reconnect. A recorder wedged in `.starting` or `.error` can always be
    /// rebooted out of it.
    public func reboot() async throws {
        struct Response: Decodable { let accepted: Bool }
        let _: Response = try await connection.post("/v1/device/reboot")
    }

    /// Powers the device off cleanly (`POST /v1/device/shutdown`). It has to
    /// be powered back on by hand; halting and then pulling the card is
    /// always a safe eject.
    public func shutdown() async throws {
        struct Response: Decodable { let accepted: Bool }
        let _: Response = try await connection.post("/v1/device/shutdown")
    }

    /// Flushes writes and unmounts the card so it can be pulled safely
    /// (`POST /v1/sd/eject`). Anything not yet acked leaves with the card.
    /// Returns `false` when the card was already unmounted. Re-insertion is
    /// picked up automatically.
    ///
    /// Throws `.device(.sdBusy)` while card files are still in use, e.g. an
    /// in-flight segment download — retryable.
    @discardableResult
    public func ejectSDCard() async throws -> Bool {
        struct Response: Decodable { let changed: Bool }
        let response: Response = try await connection.post("/v1/sd/eject")
        return response.changed
    }
    /// Streams a signed bundle from memory to the device eMMC upgrade
    /// directory (`PUT /v1/update/bundle`). The device verifies the signature
    /// before it arms the bundle. Stop recording first, then call `reboot()`.
    public func sendFirmwareBundle(
        bundleData: Data,
        signature: String,
        reportProgress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> FirmwareBundleReceipt {
        try await connection.upload(
            "/v1/update/bundle",
            payload: bundleData,
            headers: ["X-Bundle-Signature": signature],
            reportProgress: reportProgress
        )
    }

    /// Streams a verified downloaded release to the device and checks the
    /// device's receipt against the release: the received hash and byte count
    /// must match what the feed published. Returns normally only when the
    /// device holds the exact release bytes; throws `.hashMismatch` otherwise
    /// — do not reboot after that throw. Stop recording first, then call
    /// `reboot()`.
    public func sendFirmwareBundle(
        _ bundle: VerifiedFirmwareBundle,
        reportProgress: (@Sendable (_ sentBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws {
        let receipt = try await sendFirmwareBundle(
            bundleData: bundle.bundleData,
            signature: bundle.signature,
            reportProgress: reportProgress
        )
        let release = bundle.release
        guard receipt.sha256.lowercased() == release.bundleSHA256.lowercased(),
              receipt.size == release.bundleBytes else {
            throw AbundanceError.hashMismatch(
                artifact: release.bundleURL.lastPathComponent,
                expected: "\(release.bundleSHA256) (\(release.bundleBytes) bytes)",
                computed: "\(receipt.sha256) (\(receipt.size) bytes)"
            )
        }
    }

    /// Returns the last boot-time update verdict
    /// (`GET /v1/update/last-result`). Call after reconnect when the running
    /// firmware version differs from the expected version.
    public func readLastUpdateResult() async throws -> UpdateResult {
        try await connection.get("/v1/update/last-result")
    }
}


/// Verified receipt from `PUT /v1/update/bundle`.
public struct FirmwareBundleReceipt: Decodable, Sendable, Equatable {
    public let sha256: String
    public let size: Int64
}

/// Boot-time update verdict from `GET /v1/update/last-result`.
public struct UpdateResult: Decodable, Sendable, Equatable {
    public let deviceID: String
    public let status: UpdateStatus
    public let bundleSHA256: String
    public let bundleVersion: String
    public let previousVersion: String
    public let installedVersion: String
    public let error: String
    public let uptimeSeconds: Double
    public let wallclock: String
    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case status
        case bundleSHA256 = "bundleSha256"
        case bundleVersion
        case previousVersion
        case installedVersion
        case error
        case uptimeSeconds
        case wallclock
    }
}

/// Boot-time updater verdict status. Closed set today, but future firmware
/// may add values, so unrecognized ones decode as `.unknown` instead of
/// failing.
public enum UpdateStatus: Sendable, Hashable, Decodable {
    case success
    case multipleBundles
    case missingSignature
    case signatureInvalid
    case ingestFailed
    case manifestInvalid
    case extractFailed
    case installFailed
    case unknown(String)

    public init(_ raw: String) {
        switch raw {
        case "success": self = .success
        case "multiple_bundles": self = .multipleBundles
        case "missing_signature": self = .missingSignature
        case "signature_invalid": self = .signatureInvalid
        case "ingest_failed": self = .ingestFailed
        case "manifest_invalid": self = .manifestInvalid
        case "extract_failed": self = .extractFailed
        case "install_failed": self = .installFailed
        default: self = .unknown(raw)
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public var rawValue: String {
        switch self {
        case .success: "success"
        case .multipleBundles: "multiple_bundles"
        case .missingSignature: "missing_signature"
        case .signatureInvalid: "signature_invalid"
        case .ingestFailed: "ingest_failed"
        case .manifestInvalid: "manifest_invalid"
        case .extractFailed: "extract_failed"
        case .installFailed: "install_failed"
        case .unknown(let raw): raw
        }
    }
}


/// `GET /v1/storage` — byte attribution for the recording volume.
public struct StorageBreakdown: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        /// False marks an entry the device has no model for, such as a
        /// directory left by a desktop that mounted the card.
        public let known: Bool
    }

    public let mountpoint: String
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let usedBytes: Int64
    /// Used space no entry explains — filesystem overhead, files still held
    /// open after deletion.
    public let unaccountedBytes: Int64
    public let entries: [Entry]
    public let scanSeconds: Double
    public let cachedAgeS: Double
}
