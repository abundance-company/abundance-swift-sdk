import Foundation

/// The single error type every throwing call in the SDK throws.
public enum AbundanceError: Error, Sendable {
    /// The device answered with its JSON error envelope.
    case device(DeviceError)
    /// Socket / connection failure — the device never answered.
    case transport(String)
    /// A non-2xx response with no JSON envelope. The device's router answers
    /// unknown paths and wrong methods with plain-text 404/405, outside the
    /// envelope contract.
    case unexpectedStatus(Int)
    case decoding(String)
    /// Raised client-side: downloaded bytes failed SHA-256 verification
    /// against published metadata, before SoftAP transfer.
    case hashMismatch(artifact: String, expected: String, computed: String)
    /// APS offered firmware for a different hardware target.
    case incompatibleFirmwareRelease(expectedBoard: String, actualBoard: String)
    /// The pre-recording clock-anchor exchange failed client-side (device
    /// rejected an anchor, non-monotonic clock, timestamp overflow).
    case clockSync(String)
    /// The preview stream violated its wire contract — reconnecting cannot fix
    /// a protocol mismatch.
    case previewProtocolViolation(PreviewStreamError)
}

/// The wire error envelope: `{"error":{code,message,details?,retryable}}`.
public struct DeviceError: Sendable, Equatable {
    /// Stable machine-readable identifier — the value to switch on.
    public let code: ErrorCode
    /// Human-readable description. Show it to people; don't parse it.
    public let message: String
    /// Whether repeating the identical request can succeed once the condition
    /// clears.
    public let retryable: Bool
    /// Structured context when a code has any; the hash-mismatch codes carry
    /// `expected` and `got`.
    public let details: [String: String]

    public init(code: ErrorCode, message: String, retryable: Bool, details: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details
    }
}

/// Every error code the device emits. Closed today; future firmware may add
/// codes, so unrecognized ones decode as `.unknown` instead of failing.
public enum ErrorCode: Sendable, Hashable {
    case unauthorized
    case capabilityDenied
    case pairingClosed
    case notFound
    case restartRequired
    case segmentActive
    case recordingActive
    case sdBusy
    case updateTransferInProgress
    case updateAlreadyAttempted
    case signatureInvalid
    case lengthRequired
    case insufficientSpace
    case joinFailed
    case stationEnabled
    case shaMismatch
    case csvShaMismatch
    case framesShaMismatch
    case sdAbsent
    case cameraAbsent
    case timeNotSynced
    case validation
    case rateLimited
    case internalError
    case unknown(String)

    public init(_ raw: String) {
        switch raw {
        case "unauthorized": self = .unauthorized
        case "capability_denied": self = .capabilityDenied
        case "pairing_closed": self = .pairingClosed
        case "not_found": self = .notFound
        case "restart_required": self = .restartRequired
        case "segment_active": self = .segmentActive
        case "recording_active": self = .recordingActive
        case "sd_busy": self = .sdBusy
        case "update_transfer_in_progress": self = .updateTransferInProgress
        case "update_already_attempted": self = .updateAlreadyAttempted
        case "signature_invalid": self = .signatureInvalid
        case "length_required": self = .lengthRequired
        case "insufficient_space": self = .insufficientSpace
        case "join_failed": self = .joinFailed
        case "station_enabled": self = .stationEnabled
        case "sha_mismatch": self = .shaMismatch
        case "csv_sha_mismatch": self = .csvShaMismatch
        case "frames_sha_mismatch": self = .framesShaMismatch
        case "sd_absent": self = .sdAbsent
        case "camera_absent": self = .cameraAbsent
        case "time_not_synced": self = .timeNotSynced
        case "validation": self = .validation
        case "rate_limited": self = .rateLimited
        case "internal": self = .internalError
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .capabilityDenied: "capability_denied"
        case .pairingClosed: "pairing_closed"
        case .notFound: "not_found"
        case .restartRequired: "restart_required"
        case .segmentActive: "segment_active"
        case .recordingActive: "recording_active"
        case .sdBusy: "sd_busy"
        case .updateTransferInProgress: "update_transfer_in_progress"
        case .updateAlreadyAttempted: "update_already_attempted"
        case .signatureInvalid: "signature_invalid"
        case .lengthRequired: "length_required"
        case .insufficientSpace: "insufficient_space"
        case .joinFailed: "join_failed"
        case .stationEnabled: "station_enabled"
        case .shaMismatch: "sha_mismatch"
        case .csvShaMismatch: "csv_sha_mismatch"
        case .framesShaMismatch: "frames_sha_mismatch"
        case .sdAbsent: "sd_absent"
        case .cameraAbsent: "camera_absent"
        case .timeNotSynced: "time_not_synced"
        case .validation: "validation"
        case .rateLimited: "rate_limited"
        case .internalError: "internal"
        case .unknown(let raw): raw
        }
    }
}

/// Wire shape of the envelope. Decoded with the plain key names it uses.
struct WireErrorEnvelope: Decodable {
    let error: Body

    struct Body: Decodable {
        let code: String
        let message: String
        let retryable: Bool
        let details: [String: String]

        private enum CodingKeys: String, CodingKey {
            case code, message, retryable, details
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decode(String.self, forKey: .code)
            message = try container.decode(String.self, forKey: .message)
            retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
            // details is open-shaped context; a future non-string value must
            // not make the whole envelope undecodable.
            details = (try? container.decode([String: String].self, forKey: .details)) ?? [:]
        }
    }

    var deviceError: DeviceError {
        DeviceError(
            code: ErrorCode(error.code),
            message: error.message,
            retryable: error.retryable,
            details: error.details
        )
    }
}
