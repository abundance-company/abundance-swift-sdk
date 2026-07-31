import Foundation

/// UTC anchoring (`POST /v1/time`), internal plumbing behind
/// `RecordingControl`. The device has no battery-backed clock; these anchors
/// are what date every timestamp in a published session. The SDK runs the
/// prescribed exchange itself — customers never operate the clock.
struct TimeSync: Sendable {
    typealias Exchange = @Sendable (AnchorRequest) async throws -> TimeAnchor

    private let exchange: Exchange
    private let unixEpochNanoseconds: @Sendable () -> Int64
    private let monotonicNanoseconds: @Sendable () -> UInt64
    private let rttCache: RTTCache

    init(connection: DeviceConnection) {
        self.init(
            exchange: { request in
                try await connection.send("POST", "/v1/time", body: request)
            },
            unixEpochNanoseconds: {
                var realtime = timespec()
                precondition(clock_gettime(CLOCK_REALTIME, &realtime) == 0)
                return Int64(realtime.tv_sec) * 1_000_000_000 + Int64(realtime.tv_nsec)
            },
            monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds }
        )
    }

    /// Test seam: injected exchange and clocks.
    init(
        exchange: @escaping Exchange,
        unixEpochNanoseconds: @escaping @Sendable () -> Int64,
        monotonicNanoseconds: @escaping @Sendable () -> UInt64
    ) {
        self.exchange = exchange
        self.unixEpochNanoseconds = unixEpochNanoseconds
        self.monotonicNanoseconds = monotonicNanoseconds
        self.rttCache = RTTCache()
    }

    /// The prescribed exchange: `samples` anchors back to back, each
    /// RTT-compensated — the clock value is offset by half the best observed
    /// round trip, and that same half is reported as the anchor's
    /// uncertainty. The first exchange (1 s uncertainty) measures the path.
    ///
    /// The best round trip is remembered across calls, so later syncs start
    /// tight.
    @discardableResult
    func sync(samples: Int = 3) async throws -> TimeSynchronization {
        guard samples > 0 else { throw TimeSynchronizationError.invalidSampleCount }

        var bestRoundTrip = await rttCache.best
        var final: TimeSynchronization?

        for _ in 0..<samples {
            let adjustment = bestRoundTrip.map { $0 / 2 } ?? 0
            guard adjustment <= UInt64(Int64.max) else {
                throw TimeSynchronizationError.timestampOverflow
            }
            let (unixNanoseconds, overflow) = unixEpochNanoseconds()
                .addingReportingOverflow(Int64(adjustment))
            guard !overflow else { throw TimeSynchronizationError.timestampOverflow }

            let uncertainty = bestRoundTrip == nil
                ? Self.initialUncertaintyNanoseconds
                : max(adjustment, 1)

            let started = monotonicNanoseconds()
            let anchor = try await exchange(AnchorRequest(
                unixNs: unixNanoseconds,
                uncertaintyNs: Int64(uncertainty)
            ))
            let finished = monotonicNanoseconds()

            guard anchor.timeSynced else { throw TimeSynchronizationError.rejected }
            guard finished >= started else { throw TimeSynchronizationError.nonMonotonicClock }

            let roundTrip = finished - started
            bestRoundTrip = min(bestRoundTrip ?? roundTrip, roundTrip)
            final = TimeSynchronization(
                bootID: anchor.bootID,
                utcUnixNanoseconds: anchor.utcUnixNanoseconds,
                deviceFPGANanoseconds: anchor.fpgaNanoseconds,
                roundTripNanoseconds: Int64(roundTrip),
                bestRoundTripNanoseconds: Int64(bestRoundTrip ?? roundTrip),
                appliedAdjustmentNanoseconds: Int64(adjustment),
                uncertaintyNanoseconds: anchor.uncertaintyNanoseconds
            )
        }

        // samples is validated above; finishing without an exchange is an
        // internal invariant violation, not a recoverable state.
        guard let final else { throw TimeSynchronizationError.invalidSampleCount }
        if let bestRoundTrip {
            await rttCache.update(bestRoundTrip)
        }
        return final
    }

    /// Cadence for long recordings — more anchors, tighter clock fit. Runs
    /// until the surrounding task is cancelled.
    ///
    /// A failed tick is skipped, not surfaced: this loop only *tightens* the
    /// fit, and start/stop still fail loudly on their own sync.
    func maintainAnchors(every interval: Duration = .seconds(15)) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            _ = try? await sync()
        }
    }

    private static let initialUncertaintyNanoseconds: UInt64 = 1_000_000_000
}

/// One stored anchor, as the device confirms it.
struct TimeAnchor: Sendable, Equatable, Decodable {
    let timeSynced: Bool
    let bootID: String
    let utcUnixNanoseconds: Int64
    let fpgaNanoseconds: Int64
    let uncertaintyNanoseconds: Int64

    private enum CodingKeys: String, CodingKey {
        case timeSynced
        case bootId
        case utcUnixNs
        case fpgaNs
        case monotonicNs
        case uncertaintyNs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timeSynced = try container.decode(Bool.self, forKey: .timeSynced)
        bootID = try container.decode(String.self, forKey: .bootId)
        utcUnixNanoseconds = try container.decode(Int64.self, forKey: .utcUnixNs)
        // Firmware 1.0.6 named this counter `monotonic_ns`; the finalized API
        // calls it `fpga_ns`. Same value, one field — accept either spelling
        // until the fleet is past the rename.
        if let fpga = try container.decodeIfPresent(Int64.self, forKey: .fpgaNs) {
            fpgaNanoseconds = fpga
        } else {
            fpgaNanoseconds = try container.decode(Int64.self, forKey: .monotonicNs)
        }
        uncertaintyNanoseconds = try container.decodeIfPresent(Int64.self, forKey: .uncertaintyNs)
            ?? 1_000_000_000
    }

    init(
        timeSynced: Bool,
        bootID: String,
        utcUnixNanoseconds: Int64,
        fpgaNanoseconds: Int64,
        uncertaintyNanoseconds: Int64
    ) {
        self.timeSynced = timeSynced
        self.bootID = bootID
        self.utcUnixNanoseconds = utcUnixNanoseconds
        self.fpgaNanoseconds = fpgaNanoseconds
        self.uncertaintyNanoseconds = uncertaintyNanoseconds
    }
}

/// The result of one `sync()` — the last anchor plus the measured path.
struct TimeSynchronization: Sendable, Equatable {
    let bootID: String
    let utcUnixNanoseconds: Int64
    let deviceFPGANanoseconds: Int64
    let roundTripNanoseconds: Int64
    let bestRoundTripNanoseconds: Int64
    let appliedAdjustmentNanoseconds: Int64
    let uncertaintyNanoseconds: Int64
}

/// Client-side synchronization failures. Surfaced to customers as
/// `AbundanceError.clockSync` by `RecordingControl`.
enum TimeSynchronizationError: Error, Sendable, Equatable {
    case invalidSampleCount
    case nonMonotonicClock
    case rejected
    case timestampOverflow
}

struct AnchorRequest: Encodable, Sendable, Equatable {
    let unixNs: Int64
    let uncertaintyNs: Int64
}

/// Remembers the best observed round trip across syncs so every later
/// exchange starts with a tight adjustment.
actor RTTCache {
    private(set) var best: UInt64?

    func update(_ value: UInt64) {
        best = min(best ?? value, value)
    }
}
