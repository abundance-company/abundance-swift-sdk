import CryptoKit
import Foundation

/// Public APS description of one signed firmware release.
public struct FirmwareRelease: Decodable, Sendable, Equatable {
    public let board: String
    public let version: String
    public let bundleSHA256: String
    public let bundleBytes: Int64
    public let bundleURL: URL
    public let signatureURL: URL
    /// Short "what's new" text for the update screen. Optional feed key.
    public let notes: String?
    /// Marks a release the app should escalate (for example a data-loss
    /// fix). Optional feed key; missing reads as `false`.
    public let critical: Bool
    /// Audit data only. Update decisions must not use device wallclock time.
    public let releasedAt: String

    private enum CodingKeys: String, CodingKey {
        case board
        case version
        case bundleSHA256 = "bundle_sha256"
        case bundleBytes = "bundle_bytes"
        case bundleURL = "bundle_url"
        case signatureURL = "signature_url"
        case notes
        case critical
        case releasedAt = "released_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        board = try container.decode(String.self, forKey: .board)
        version = try container.decode(String.self, forKey: .version)
        bundleSHA256 = try container.decode(String.self, forKey: .bundleSHA256)
        bundleBytes = try container.decode(Int64.self, forKey: .bundleBytes)
        bundleURL = try container.decode(URL.self, forKey: .bundleURL)
        signatureURL = try container.decode(URL.self, forKey: .signatureURL)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        critical = try container.decodeIfPresent(Bool.self, forKey: .critical) ?? false
        releasedAt = try container.decode(String.self, forKey: .releasedAt)
    }
}

/// A verified bundle held in memory, ready for
/// `Maintenance.sendFirmwareBundle`. Never written to disk on the phone;
/// if the app loses it (e.g. the screen is recreated), download again.
public struct VerifiedFirmwareBundle: Sendable, Equatable {
    public let release: FirmwareRelease
    public let bundleData: Data
    public let signature: String
}

/// Reads the APS release feed and verifies downloaded bundle bytes before
/// SoftAP transfer. APS selects a release; the device signature remains the
/// install trust decision.
public struct FirmwareReleaseFeed: Sendable {
    public typealias AuthorizeFeedRequest = @Sendable (URLRequest) async throws -> URLRequest

    private let feedURL: URL
    private let expectedBoard: String
    private let session: URLSession
    private let authorizeFeedRequest: AuthorizeFeedRequest?

    public init(
        feedURL: URL,
        expectedBoard: String = "a4-nanopi",
        session: URLSession = .shared,
        authorizeFeedRequest: AuthorizeFeedRequest? = nil
    ) {
        self.feedURL = feedURL
        self.expectedBoard = expectedBoard
        self.session = session
        self.authorizeFeedRequest = authorizeFeedRequest
    }

    public func fetchLatestFirmwareRelease() async throws -> FirmwareRelease {
        var request = makeRequest(url: feedURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorizeFeedRequest {
            request = try await authorizeFeedRequest(request)
        }
        let (data, response) = try await fetchData(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AbundanceError.unexpectedStatus(response.statusCode)
        }

        // The feed announces its own contract: a missing `format` reads as 1
        // (pre-format feeds), any other value is refused with a named error
        // instead of a field-level decode failure.
        let release: FirmwareRelease
        do {
            let format = try JSONDecoder().decode(FeedFormat.self, from: data).format ?? 1
            guard format == 1 else {
                throw AbundanceError.decoding("feed format \(format); this SDK understands only format 1")
            }
            release = try JSONDecoder().decode(FirmwareRelease.self, from: data)
        } catch let error as AbundanceError {
            throw error
        } catch {
            throw AbundanceError.decoding(String(describing: error))
        }
        guard release.board == expectedBoard else {
            throw AbundanceError.incompatibleFirmwareRelease(
                expectedBoard: expectedBoard,
                actualBoard: release.board
            )
        }
        return release
    }

    private struct FeedFormat: Decodable {
        let format: Int?
    }

    public func downloadFirmwareBundle(
        _ release: FirmwareRelease,
        reportProgress: (@Sendable (_ receivedBytes: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> VerifiedFirmwareBundle {
        guard release.board == expectedBoard else {
            throw AbundanceError.incompatibleFirmwareRelease(
                expectedBoard: expectedBoard,
                actualBoard: release.board
            )
        }

        reportProgress?(0, release.bundleBytes)
        let (bundleData, bundleResponse) = try await fetchBundleBytes(
            request: makeRequest(url: release.bundleURL),
            expectedBytes: release.bundleBytes,
            reportProgress: reportProgress
        )
        guard (200..<300).contains(bundleResponse.statusCode) else {
            throw AbundanceError.unexpectedStatus(bundleResponse.statusCode)
        }
        guard Int64(bundleData.count) == release.bundleBytes else {
            throw AbundanceError.hashMismatch(
                artifact: release.bundleURL.lastPathComponent,
                expected: "bytes:\(release.bundleBytes)",
                computed: "bytes:\(bundleData.count)"
            )
        }
        let computedSHA256 = sha256(of: bundleData)
        guard computedSHA256 == release.bundleSHA256.lowercased() else {
            throw AbundanceError.hashMismatch(
                artifact: release.bundleURL.lastPathComponent,
                expected: release.bundleSHA256,
                computed: computedSHA256
            )
        }

        let (signatureData, signatureResponse) = try await fetchData(from: release.signatureURL)
        guard (200..<300).contains(signatureResponse.statusCode) else {
            throw AbundanceError.unexpectedStatus(signatureResponse.statusCode)
        }
        guard let signature = String(data: signatureData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !signature.isEmpty
        else {
            throw AbundanceError.decoding("firmware signature is not non-empty UTF-8 text")
        }

        return VerifiedFirmwareBundle(
            release: release,
            bundleData: bundleData,
            signature: signature
        )
    }

    /// Data-task fetch that reports received bytes as they arrive. A per-task
    /// delegate keeps the shared session untouched.
    private func fetchBundleBytes(
        request: URLRequest,
        expectedBytes: Int64,
        reportProgress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> (Data, HTTPURLResponse) {
        let collector = BundleDownloadCollector(
            expectedBytes: expectedBytes,
            reportProgress: reportProgress
        )
        do {
            return try await withCheckedThrowingContinuation { continuation in
                collector.continuation = continuation
                let task = session.dataTask(with: request)
                task.delegate = collector
                task.resume()
            }
        } catch let error as AbundanceError {
            throw error
        } catch {
            throw AbundanceError.transport(error.localizedDescription)
        }
    }

    private func fetchData(from url: URL) async throws -> (Data, HTTPURLResponse) {
        try await fetchData(makeRequest(url: url))
    }

    private func fetchData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AbundanceError.transport(error.localizedDescription)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AbundanceError.transport("non-HTTP response")
        }
        return (data, httpResponse)
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return request
    }
}

private func sha256(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private final class BundleDownloadCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let reportProgress: (@Sendable (Int64, Int64) -> Void)?
    private var receivedData = Data()
    private var httpResponse: HTTPURLResponse?
    var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    init(
        expectedBytes: Int64,
        reportProgress: (@Sendable (Int64, Int64) -> Void)?
    ) {
        self.expectedBytes = expectedBytes
        self.reportProgress = reportProgress
        receivedData.reserveCapacity(Int(max(expectedBytes, 0)))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        httpResponse = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        reportProgress?(Int64(receivedData.count), expectedBytes)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: error)
            return
        }
        guard let httpResponse else {
            continuation.resume(throwing: AbundanceError.transport("non-HTTP response"))
            return
        }
        continuation.resume(returning: (receivedData, httpResponse))
    }
}
