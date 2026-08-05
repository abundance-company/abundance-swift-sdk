import Foundation
import XCTest
@testable import AbundanceDeviceKit

final class FirmwareReleaseFeedTests: XCTestCase {
    private let bundle = Data("bundle bytes".utf8)
    private let bundleSHA256 = "f40a912044d47ea7c32f37340db4fd5eb853ffb8fcd983f605d9eb4f8b02fbc2"

    override func tearDown() {
        FirmwareReleaseURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchLatestFirmwareReleaseDecodesFeed() async throws {
        FirmwareReleaseURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/latest.json")
            return (200, self.releaseJSON())
        }

        let release = try await makeFeed().fetchLatestFirmwareRelease()

        XCTAssertEqual(release.board, "a4-nanopi")
        XCTAssertEqual(release.version, "1.0.14")
        XCTAssertEqual(release.bundleSHA256, bundleSHA256)
        XCTAssertEqual(release.bundleBytes, Int64(bundle.count))
        XCTAssertEqual(release.bundleURL.absoluteString, "https://firmware.test/releases/abundance-1.0.14.tar.gz")
        XCTAssertEqual(release.signatureURL.absoluteString, "https://firmware.test/releases/abundance-1.0.14.tar.gz.sig")
        XCTAssertEqual(release.releasedAt, "2026-08-03T00:00:00Z")
        XCTAssertNil(release.notes)
        XCTAssertFalse(release.critical)
    }

    func testFetchLatestFirmwareReleaseRejectsWrongBoard() async throws {
        FirmwareReleaseURLProtocol.handler = { _ in
            (200, self.releaseJSON(board: "a5"))
        }

        do {
            _ = try await makeFeed().fetchLatestFirmwareRelease()
            XCTFail("wrong-board release was accepted")
        } catch AbundanceError.incompatibleFirmwareRelease(let expectedBoard, let actualBoard) {
            XCTAssertEqual(expectedBoard, "a4-nanopi")
            XCTAssertEqual(actualBoard, "a5")
        }
    }

    func testDownloadFirmwareBundleVerifiesBytesInMemory() async throws {
        FirmwareReleaseURLProtocol.handler = { request in
            switch request.url?.path {
            case "/latest.json":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer future-token")
                return (200, self.releaseJSON())
            case "/releases/abundance-1.0.14.tar.gz":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, self.bundle)
            case "/releases/abundance-1.0.14.tar.gz.sig":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, Data("base64-signature\n".utf8))
            default:
                XCTFail("unexpected request: \(request.url?.absoluteString ?? "nil")")
                return (404, Data())
            }
        }
        let feed = makeFeed(authorizeFeedRequest: { request in
            var authorizedRequest = request
            authorizedRequest.setValue("Bearer future-token", forHTTPHeaderField: "Authorization")
            return authorizedRequest
        })
        let release = try await feed.fetchLatestFirmwareRelease()

        let downloadedBundle = try await feed.downloadFirmwareBundle(release)

        XCTAssertEqual(downloadedBundle.release, release)
        XCTAssertEqual(downloadedBundle.signature, "base64-signature")
        XCTAssertEqual(downloadedBundle.bundleData, bundle)
    }

    func testDownloadFirmwareBundleRejectsWrongHash() async throws {
        FirmwareReleaseURLProtocol.handler = { request in
            switch request.url?.path {
            case "/latest.json":
                return (200, self.releaseJSON(bundleSHA256: String(repeating: "0", count: 64)))
            case "/releases/abundance-1.0.14.tar.gz":
                return (200, self.bundle)
            default:
                XCTFail("signature must not download after a bundle hash mismatch")
                return (500, Data())
            }
        }
        let feed = makeFeed()
        let release = try await feed.fetchLatestFirmwareRelease()

        do {
            _ = try await feed.downloadFirmwareBundle(release)
            XCTFail("bundle with wrong hash was accepted")
        } catch AbundanceError.hashMismatch(let artifact, let expected, let computed) {
            XCTAssertEqual(artifact, "abundance-1.0.14.tar.gz")
            XCTAssertEqual(expected, String(repeating: "0", count: 64))
            XCTAssertEqual(computed, bundleSHA256)
        }
    }

    private func makeFeed(
        authorizeFeedRequest: FirmwareReleaseFeed.AuthorizeFeedRequest? = nil
    ) -> FirmwareReleaseFeed {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirmwareReleaseURLProtocol.self]
        return FirmwareReleaseFeed(
            feedURL: URL(string: "https://firmware.test/latest.json")!,
            session: URLSession(configuration: configuration),
            authorizeFeedRequest: authorizeFeedRequest
        )
    }

    private func releaseJSON(
        board: String = "a4-nanopi",
        bundleSHA256: String? = nil,
        formatField: String = #""format":1,"#
    ) -> Data {
        Data(#"{\#(formatField)"board":"\#(board)","version":"1.0.14","bundle_sha256":"\#(bundleSHA256 ?? self.bundleSHA256)","bundle_bytes":\#(bundle.count),"bundle_url":"https://firmware.test/releases/abundance-1.0.14.tar.gz","signature_url":"https://firmware.test/releases/abundance-1.0.14.tar.gz.sig","released_at":"2026-08-03T00:00:00Z"}"#.utf8)
    }

    func testFetchLatestFirmwareReleaseAcceptsFeedWithoutFormat() async throws {
        FirmwareReleaseURLProtocol.handler = { _ in
            (200, self.releaseJSON(formatField: ""))
        }

        let release = try await makeFeed().fetchLatestFirmwareRelease()
        XCTAssertEqual(release.version, "1.0.14")
    }

    func testFetchLatestFirmwareReleaseRefusesNewerFormat() async throws {
        FirmwareReleaseURLProtocol.handler = { _ in
            (200, self.releaseJSON(formatField: #""format":2,"#))
        }

        do {
            _ = try await makeFeed().fetchLatestFirmwareRelease()
            XCTFail("expected decoding error")
        } catch let AbundanceError.decoding(detail) {
            XCTAssertTrue(detail.contains("format 2"), detail)
        }
    }

    func testFetchLatestFirmwareReleaseDecodesNotesAndCritical() async throws {
        FirmwareReleaseURLProtocol.handler = { _ in
            (200, self.releaseJSON(formatField: #""format":1,"notes":"Fixes recording stop.","critical":true,"#))
        }

        let release = try await makeFeed().fetchLatestFirmwareRelease()
        XCTAssertEqual(release.notes, "Fixes recording stop.")
        XCTAssertTrue(release.critical)
    }
}

private final class FirmwareReleaseURLProtocol: URLProtocol {
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
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
