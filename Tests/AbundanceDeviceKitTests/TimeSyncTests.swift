import XCTest
@testable import AbundanceDeviceKit

/// The RTT-compensation algorithm, against injected clocks and exchanges.
final class TimeSyncTests: XCTestCase {

    /// Recorded exchange requests plus a scripted monotonic clock.
    private final class Harness: @unchecked Sendable {
        let lock = NSLock()
        var requests: [AnchorRequest] = []
        var monotonic: [UInt64] = []
        var nextMonotonic: UInt64 = 0

        func record(_ request: AnchorRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        /// Each call advances by `step` — a constant round trip.
        func tick(step: UInt64) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            let value = nextMonotonic
            nextMonotonic += step
            return value
        }
    }

    private func makeSync(
        harness: Harness,
        roundTripNanoseconds: UInt64,
        unixNanoseconds: Int64 = 1_000_000_000_000
    ) -> TimeSync {
        TimeSync(
            exchange: { request in
                harness.record(request)
                return TimeAnchor(
                    timeSynced: true,
                    bootID: "boot-1",
                    utcUnixNanoseconds: request.unixNs,
                    fpgaNanoseconds: 42,
                    uncertaintyNanoseconds: request.uncertaintyNs
                )
            },
            unixEpochNanoseconds: { unixNanoseconds },
            // Two ticks per sample (start + finish) → the tick step is half
            // the observed round trip... no: start and finish are one step
            // apart, so the round trip IS the step.
            monotonicNanoseconds: { harness.tick(step: roundTripNanoseconds) }
        )
    }

    func testFirstSampleMeasuresPathWithOneSecondUncertainty() async throws {
        let harness = Harness()
        let sync = makeSync(harness: harness, roundTripNanoseconds: 8_000_000)
        let result = try await sync.sync(samples: 1)

        XCTAssertEqual(harness.requests.count, 1)
        // No prior RTT: no adjustment, 1 s declared uncertainty.
        XCTAssertEqual(harness.requests[0].unixNs, 1_000_000_000_000)
        XCTAssertEqual(harness.requests[0].uncertaintyNs, 1_000_000_000)
        XCTAssertEqual(result.roundTripNanoseconds, 8_000_000)
        XCTAssertEqual(result.bestRoundTripNanoseconds, 8_000_000)
        XCTAssertEqual(result.appliedAdjustmentNanoseconds, 0)
    }

    func testLaterSamplesAddHalfBestRoundTrip() async throws {
        let harness = Harness()
        let sync = makeSync(harness: harness, roundTripNanoseconds: 8_000_000)
        let result = try await sync.sync(samples: 3)

        XCTAssertEqual(harness.requests.count, 3)
        // Samples 2 and 3 offset the clock by half the best RTT and declare
        // that same half as uncertainty.
        XCTAssertEqual(harness.requests[1].unixNs, 1_000_000_000_000 + 4_000_000)
        XCTAssertEqual(harness.requests[1].uncertaintyNs, 4_000_000)
        XCTAssertEqual(harness.requests[2].uncertaintyNs, 4_000_000)
        XCTAssertEqual(result.appliedAdjustmentNanoseconds, 4_000_000)
        XCTAssertEqual(result.uncertaintyNanoseconds, 4_000_000)
    }

    func testBestRoundTripIsRememberedAcrossSyncs() async throws {
        let harness = Harness()
        let sync = makeSync(harness: harness, roundTripNanoseconds: 8_000_000)
        _ = try await sync.sync(samples: 1)
        _ = try await sync.sync(samples: 1)

        // The second sync's FIRST sample already carries the adjustment
        // learned by the first sync.
        XCTAssertEqual(harness.requests[1].unixNs, 1_000_000_000_000 + 4_000_000)
        XCTAssertEqual(harness.requests[1].uncertaintyNs, 4_000_000)
    }

    func testRejectedAnchorThrows() async {
        let sync = TimeSync(
            exchange: { request in
                TimeAnchor(
                    timeSynced: false,
                    bootID: "b",
                    utcUnixNanoseconds: request.unixNs,
                    fpgaNanoseconds: 0,
                    uncertaintyNanoseconds: request.uncertaintyNs
                )
            },
            unixEpochNanoseconds: { 1 },
            monotonicNanoseconds: { 0 }
        )
        do {
            _ = try await sync.sync()
            XCTFail("expected rejection")
        } catch let error as TimeSynchronizationError {
            XCTAssertEqual(error, .rejected)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testInvalidSampleCountThrows() async {
        let sync = TimeSync(
            exchange: { _ in
                XCTFail("must not exchange")
                throw TimeSynchronizationError.rejected
            },
            unixEpochNanoseconds: { 1 },
            monotonicNanoseconds: { 0 }
        )
        do {
            _ = try await sync.sync(samples: 0)
            XCTFail("expected invalidSampleCount")
        } catch let error as TimeSynchronizationError {
            XCTAssertEqual(error, .invalidSampleCount)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
