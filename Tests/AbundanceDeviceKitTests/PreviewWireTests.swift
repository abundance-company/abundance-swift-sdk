import XCTest
@testable import AbundanceDeviceKit

/// The ABPV pull-parser against synthetic byte streams.
final class PreviewWireTests: XCTestCase {

    private func stream(_ bytes: [UInt8]) -> AsyncStream<UInt8> {
        AsyncStream { continuation in
            for byte in bytes { continuation.yield(byte) }
            continuation.finish()
        }
    }

    private var validHeader: [UInt8] { [0x41, 0x42, 0x50, 0x56, 0x01, 0x01, 0x00, 0x00] }

    private func framed(_ payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count).bigEndian
        return withUnsafeBytes(of: length) { Array($0) } + payload
    }

    func testHeaderAndFrames() async throws {
        let sps: [UInt8] = [0x67, 0x42, 0x00, 0x33]
        let idr: [UInt8] = [0x65, 0x88, 0x84, 0x00, 0x01]
        var reader = NALUnitReader(stream(validHeader + framed(sps) + framed(idr)))

        try await reader.readHeader()
        let first = try await reader.nextNALUnit()
        XCTAssertEqual(first, Data(sps))
        let second = try await reader.nextNALUnit()
        XCTAssertEqual(second, Data(idr))
        // Clean EOF at a frame boundary is the device ending the stream.
        let third = try await reader.nextNALUnit()
        XCTAssertNil(third)
    }

    func testBadMagicIsProtocolViolation() async {
        var reader = NALUnitReader(stream([0x00, 0x42, 0x50, 0x56, 0x01, 0x01, 0x00, 0x00]))
        do {
            try await reader.readHeader()
            XCTFail("expected badMagic")
        } catch let error as PreviewStreamError {
            XCTAssertEqual(error, .badMagic)
            XCTAssertTrue(error.isProtocolViolation)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testUnsupportedVersion() async {
        var reader = NALUnitReader(stream([0x41, 0x42, 0x50, 0x56, 0x02, 0x01, 0x00, 0x00]))
        do {
            try await reader.readHeader()
            XCTFail("expected unsupportedVersion")
        } catch let error as PreviewStreamError {
            XCTAssertEqual(error, .unsupportedVersion(2))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testZeroLengthFrame() async throws {
        var reader = NALUnitReader(stream(validHeader + [0x00, 0x00, 0x00, 0x00]))
        try await reader.readHeader()
        do {
            _ = try await reader.nextNALUnit()
            XCTFail("expected zeroLengthFrame")
        } catch let error as PreviewStreamError {
            XCTAssertEqual(error, .zeroLengthFrame)
            XCTAssertTrue(error.isProtocolViolation)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testOversizeFrame() async throws {
        // 8 MiB length prefix — over the 4 MiB contract cap.
        var reader = NALUnitReader(stream(validHeader + [0x00, 0x80, 0x00, 0x00]))
        try await reader.readHeader()
        do {
            _ = try await reader.nextNALUnit()
            XCTFail("expected oversizeFrame")
        } catch let error as PreviewStreamError {
            XCTAssertEqual(error, .oversizeFrame(8 << 20))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTruncatedMidFrame() async throws {
        // Declares 5 bytes, delivers 2.
        var reader = NALUnitReader(stream(validHeader + [0x00, 0x00, 0x00, 0x05, 0x65, 0x88]))
        try await reader.readHeader()
        do {
            _ = try await reader.nextNALUnit()
            XCTFail("expected truncatedStream")
        } catch let error as PreviewStreamError {
            XCTAssertEqual(error, .truncatedStream)
            XCTAssertFalse(error.isProtocolViolation) // transport condition — reconnect
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testErrorMapping() {
        let violation = PreviewStream.mapped(PreviewStreamError.badMagic)
        guard case .previewProtocolViolation(.badMagic) = violation else {
            return XCTFail("expected previewProtocolViolation, got \(violation)")
        }
        let transport = PreviewStream.mapped(PreviewStreamError.truncatedStream)
        guard case .transport = transport else {
            return XCTFail("expected transport, got \(transport)")
        }
        let passthrough = PreviewStream.mapped(AbundanceError.device(DeviceError(
            code: .cameraAbsent, message: "no camera connected", retryable: true
        )))
        guard case .device(let device) = passthrough, device.code == .cameraAbsent else {
            return XCTFail("expected device passthrough, got \(passthrough)")
        }
    }
}
