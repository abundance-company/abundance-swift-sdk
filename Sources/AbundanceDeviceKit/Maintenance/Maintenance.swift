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
    public let scanSeconds: Double?
    public let cachedAgeS: Double?
}
