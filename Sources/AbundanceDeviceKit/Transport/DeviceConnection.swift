import Foundation

/// The one HTTP client under every manager: plaintext HTTP on the device's
/// private SoftAP, bearer token as the sole credential. Actor-isolated so a
/// token refresh is race-free against in-flight calls.
actor DeviceConnection {
    nonisolated let baseURL: URL
    private let session: URLSession
    private var token: String?

    init(baseURL: URL, token: String?, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.token = token
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.ephemeral
        // The SoftAP has no internet; waiting for "connectivity" would stall
        // every call behind iOS's reachability heuristics.
        config.waitsForConnectivity = false
        config.allowsCellularAccess = false
        self.session = URLSession(configuration: config)
    }

    func setToken(_ newToken: String) { token = newToken }
    func bearerToken() -> String? { token }

    // MARK: - JSON verbs

    func get<T: Decodable & Sendable>(_ path: String) async throws -> T {
        try await run(request("GET", path, body: nil))
    }

    func post<T: Decodable & Sendable>(_ path: String) async throws -> T {
        try await run(request("POST", path, body: nil))
    }

    func send<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ method: String, _ path: String, body: Body
    ) async throws -> T {
        let data: Data
        do {
            data = try JSONEncoder.abundance.encode(body)
        } catch {
            throw AbundanceError.decoding(String(describing: error))
        }
        return try await run(request(method, path, body: data))
    }

    /// DELETE never carries a body — the reclaim endpoints take their proof as
    /// query parameters because content on DELETE has no defined semantics and
    /// is dropped by some HTTP stacks.
    func delete<T: Decodable & Sendable>(_ path: String) async throws -> T {
        try await run(request("DELETE", path, body: nil))
    }

    /// Raw fetch for small non-JSON payloads (verbatim manifest bytes, logs
    /// listings the caller wants untouched). Maps non-2xx to `AbundanceError`.
    func data(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let request = request("GET", path, body: nil)
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw DeviceConnection.error(status: response.statusCode, body: data)
        }
        return (data, response)
    }

    func upload<T: Decodable & Sendable>(
        _ path: String,
        payload: Data,
        headers: [String: String],
        reportProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> T {
        var request = request("PUT", path, body: nil)
        request.setValue(String(payload.count), forHTTPHeaderField: "Content-Length")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let totalBytes = Int64(payload.count)
        let data: Data
        let response: URLResponse
        do {
            reportProgress?(0, totalBytes)
            let progressDelegate = DeviceUploadProgressDelegate(reportProgress: reportProgress)
            (data, response) = try await session.upload(
                for: request,
                from: payload,
                delegate: progressDelegate
            )
            reportProgress?(totalBytes, totalBytes)
        } catch {
            throw AbundanceError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AbundanceError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DeviceConnection.error(status: http.statusCode, body: data)
        }
        do {
            return try JSONDecoder.abundance.decode(T.self, from: data)
        } catch {
            throw AbundanceError.decoding(String(describing: error))
        }
    }

    // MARK: - Request plumbing

    func request(_ method: String, _ path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    nonisolated func url(for path: String) -> URL {
        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        let suffix = path.hasPrefix("/") ? path : "/" + path
        // Paths are SDK-built from validated identifiers; a malformed one is a
        // programmer error, not a runtime condition.
        guard let url = URL(string: base + suffix) else {
            preconditionFailure("unbuildable device URL for path \(path)")
        }
        return url
    }

    private func run<T: Decodable & Sendable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else {
            throw DeviceConnection.error(status: response.statusCode, body: data)
        }
        do {
            return try JSONDecoder.abundance.decode(T.self, from: data)
        } catch {
            throw AbundanceError.decoding(String(describing: error))
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AbundanceError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AbundanceError.transport("non-HTTP response")
        }
        return (data, http)
    }

    /// Non-2xx mapping shared by every path: the JSON envelope when present,
    /// otherwise the raw status (the device's router answers unknown paths and
    /// wrong methods with plain text).
    static func error(status: Int, body: Data) -> AbundanceError {
        if let envelope = try? JSONDecoder.abundance.decode(WireErrorEnvelope.self, from: body) {
            return .device(envelope.deviceError)
        }
        return .unexpectedStatus(status)
    }
}


private final class DeviceUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let reportProgress: (@Sendable (Int64, Int64) -> Void)?

    init(reportProgress: (@Sendable (Int64, Int64) -> Void)?) {
        self.reportProgress = reportProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        reportProgress?(totalBytesSent, totalBytesExpectedToSend)
    }
}