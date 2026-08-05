import Foundation
import XCTest
@testable import AbundanceDeviceKit

final class UpgradeTransportTests: XCTestCase {
    override func tearDown() {
        UpgradeURLProtocol.handler = nil
        super.tearDown()
    }

    func testSendFirmwareBundlePrimitiveReturnsReceipt() async throws {
        let bundleData = Data("bundle bytes".utf8)

        UpgradeURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/v1/update/bundle")
            XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Bundle-Signature"), "base64-signature")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Length"), "12")
            return (200, Data(#"{"sha256":"abc","size":12}"#.utf8))
        }

        let progressRecorder = UpgradeProgressRecorder()
        let maintenance = Maintenance(connection: testConnection())
        let receipt = try await maintenance.sendFirmwareBundle(
            bundleData: bundleData,
            signature: "base64-signature",
            reportProgress: progressRecorder.record
        )

        XCTAssertEqual(receipt, FirmwareBundleReceipt(sha256: "abc", size: 12))
        let progress = progressRecorder.snapshot()
        XCTAssertEqual(progress.first?.sentBytes, 0)
        XCTAssertEqual(progress.first?.totalBytes, 12)
        XCTAssertEqual(progress.last?.sentBytes, 12)
        XCTAssertEqual(progress.last?.totalBytes, 12)
    }

    func testReadLastUpdateResultDecodesUpdaterVerdict() async throws {
        UpgradeURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/update/last-result")
            return (200, Data(#"{"device_id":"device","hostname":"host","status":"success","bundle_sha256":"bundle","bundle_version":"1.0.1","previous_version":"1.0.0","installed_version":"1.0.1","error":"","updater_version":"1.0.0","uptime_seconds":2.5,"wallclock":"2026-08-03T00:00:00Z"}"#.utf8))
        }

        let maintenance = Maintenance(connection: testConnection())
        let result = try await maintenance.readLastUpdateResult()

        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.bundleVersion, "1.0.1")
    }

    func testUpdateStatusDecodesUnknownValueWithoutFailing() throws {
        let result = try JSONDecoder.abundance.decode(
            UpdateStatus.self,
            from: Data(#""rollback_pending""#.utf8)
        )
        XCTAssertEqual(result, .unknown("rollback_pending"))
        XCTAssertEqual(result.rawValue, "rollback_pending")
        XCTAssertEqual(UpdateStatus("install_failed"), .installFailed)
    }

    func testSendFirmwareBundleThrowsHashMismatchOnReceiptDivergence() async throws {
        UpgradeURLProtocol.handler = { _ in
            (200, Data(#"{"sha256":"deadbeef","size":12}"#.utf8))
        }

        let release = try JSONDecoder().decode(FirmwareRelease.self, from: Data(#"""
        {"board":"a4-nanopi","version":"1.0.1",
         "bundle_sha256":"abc","bundle_bytes":12,
         "bundle_url":"https://releases.test/abundance-1.0.1.tar.gz",
         "signature_url":"https://releases.test/abundance-1.0.1.tar.gz.sig",
         "released_at":"2026-08-03T00:00:00Z"}
        """#.utf8))
        let bundle = VerifiedFirmwareBundle(
            release: release,
            bundleData: Data("bundle bytes".utf8),
            signature: "base64-signature"
        )

        let maintenance = Maintenance(connection: testConnection())
        do {
            try await maintenance.sendFirmwareBundle(bundle)
            XCTFail("expected hashMismatch")
        } catch let AbundanceError.hashMismatch(artifact, expected, computed) {
            XCTAssertEqual(artifact, "abundance-1.0.1.tar.gz")
            XCTAssertTrue(expected.contains("abc"))
            XCTAssertTrue(computed.contains("deadbeef"))
        }
    }

    func testSendFirmwareBundleAcceptsMatchingReceipt() async throws {
        UpgradeURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Bundle-Signature"), "base64-signature")
            return (200, Data(#"{"sha256":"ABC","size":12}"#.utf8))
        }

        let release = try JSONDecoder().decode(FirmwareRelease.self, from: Data(#"""
        {"board":"a4-nanopi","version":"1.0.1",
         "bundle_sha256":"abc","bundle_bytes":12,
         "bundle_url":"https://releases.test/abundance-1.0.1.tar.gz",
         "signature_url":"https://releases.test/abundance-1.0.1.tar.gz.sig",
         "released_at":"2026-08-03T00:00:00Z"}
        """#.utf8))
        let bundle = VerifiedFirmwareBundle(
            release: release,
            bundleData: Data("bundle bytes".utf8),
            signature: "base64-signature"
        )

        let maintenance = Maintenance(connection: testConnection())
        try await maintenance.sendFirmwareBundle(bundle)
    }

    private func testConnection() -> DeviceConnection {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpgradeURLProtocol.self]
        return DeviceConnection(
            baseURL: URL(string: "http://device.test")!,
            token: "token",
            session: URLSession(configuration: configuration)
        )
    }
}

private final class UpgradeProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(sentBytes: Int64, totalBytes: Int64)] = []

    func record(sentBytes: Int64, totalBytes: Int64) {
        lock.lock()
        values.append((sentBytes, totalBytes))
        lock.unlock()
    }

    func snapshot() -> [(sentBytes: Int64, totalBytes: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class UpgradeURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("missing HTTP handler")
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
