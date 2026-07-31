import Foundation
import Network

/// Minimal loopback HTTP file server for local playback.
///
/// CoreMedia refuses HLS playlists on file:// URLs (verified: AVURLAsset fails
/// with -16913), so the downloaded `.ts` sessions are served to AVPlayer over
/// 127.0.0.1 instead. Serves only GET/HEAD for `.m3u8`/`.ts` files under the
/// recordings root, with Range support (AVFoundation probes with byte ranges).
@MainActor
final class LocalMediaServer {
    private let root: URL
    private var listener: NWListener?
    private var startTask: Task<UInt16, Error>?

    init(root: URL) {
        self.root = root
    }

    /// Starts the listener if needed and returns a URL that serves
    /// `relativePath` (e.g. "<session>/.playlist.m3u8").
    func url(for relativePath: String) async throws -> URL {
        let port = try await ensureStarted()
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/" + relativePath
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private func ensureStarted() async throws -> UInt16 {
        if let startTask { return try await startTask.value }
        let root = root
        let task = Task<UInt16, Error> {
            let params = NWParameters.tcp
            // Loopback only: recordings must never be reachable from the SoftAP
            // or any LAN peer.
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params, on: .any)
            listener.newConnectionHandler = { connection in
                Self.serve(connection, root: root)
            }
            let port: UInt16 = try await withCheckedThrowingContinuation { cont in
                let once = ResumeOnce()
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        once.run { cont.resume(returning: listener.port?.rawValue ?? 0) }
                    case .failed(let error), .waiting(let error):
                        once.run { cont.resume(throwing: error) }
                    default:
                        break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
            await MainActor.run { self.listener = listener }
            return port
        }
        startTask = task
        do {
            return try await task.value
        } catch {
            startTask = nil // a failed bind must not poison every later attempt
            throw error
        }
    }

    // MARK: - request handling (runs on the listener queue, off the main actor)

    private nonisolated static func serve(_ connection: NWConnection, root: URL) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(connection, buffer: Data()) { head in
            guard let head else {
                connection.cancel()
                return
            }
            handle(head, on: connection, root: root)
        }
    }

    /// Accumulates bytes until the header terminator. Request bodies are never
    /// expected (GET/HEAD only), so reading stops at the blank line.
    private nonisolated static func receiveRequest(_ connection: NWConnection, buffer: Data, completion: @escaping @Sendable (String?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                completion(String(data: buffer[..<range.lowerBound], encoding: .utf8))
                return
            }
            if error != nil || isComplete || buffer.count > 64 * 1024 {
                completion(nil)
                return
            }
            receiveRequest(connection, buffer: buffer, completion: completion)
        }
    }

    private nonisolated static func handle(_ head: String, on connection: NWConnection, root: URL) {
        let lines = head.components(separatedBy: "\r\n")
        let request = lines[0].components(separatedBy: " ")
        guard request.count >= 2, request[0] == "GET" || request[0] == "HEAD",
              let path = request[1].removingPercentEncoding else {
            respond(connection, status: "400 Bad Request", headers: [:], body: nil)
            return
        }
        let headOnly = request[0] == "HEAD"

        guard let file = resolve(path: path, root: root),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? nil else {
            respond(connection, status: "404 Not Found", headers: [:], body: nil)
            return
        }

        let contentType = file.pathExtension == "m3u8" ? "application/vnd.apple.mpegurl" : "video/mp2t"
        var headers = [
            "Content-Type": contentType,
            "Accept-Ranges": "bytes",
            "Connection": "close",
            "Cache-Control": "no-cache",
        ]

        let rangeHeader = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("range:") }?
            .drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)

        var status = "200 OK"
        var offset: Int64 = 0
        var length = size
        if let rangeHeader, let range = parseRange(rangeHeader, size: size) {
            status = "206 Partial Content"
            offset = range.lowerBound
            length = range.upperBound - range.lowerBound + 1
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(size)"
        } else if rangeHeader != nil {
            respond(connection, status: "416 Range Not Satisfiable", headers: ["Content-Range": "bytes */\(size)"], body: nil)
            return
        }
        headers["Content-Length"] = "\(length)"

        var header = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers { header += "\(k): \(v)\r\n" }
        header += "\r\n"

        connection.send(content: Data(header.utf8), completion: .contentProcessed { error in
            if error != nil || headOnly {
                connection.cancel()
                return
            }
            guard let handle = try? FileHandle(forReadingFrom: file),
                  (try? handle.seek(toOffset: UInt64(offset))) != nil else {
                connection.cancel()
                return
            }
            stream(handle, remaining: length, over: connection)
        })
    }

    /// Sends the file in bounded chunks, waiting for each send to be processed —
    /// segments run to ~240 MB, so the whole file must never be resident at once.
    private nonisolated static func stream(_ handle: FileHandle, remaining: Int64, over connection: NWConnection) {
        guard remaining > 0 else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        let chunkSize = Int(min(remaining, 512 * 1024))
        guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
            try? handle.close()
            connection.cancel() // short read = truncated file; drop the connection
            return
        }
        connection.send(content: chunk, completion: .contentProcessed { error in
            if error != nil {
                try? handle.close()
                connection.cancel()
                return
            }
            stream(handle, remaining: remaining - Int64(chunk.count), over: connection)
        })
    }

    /// Maps a request path to a file, refusing traversal and non-media files.
    private nonisolated static func resolve(path: String, root: URL) -> URL? {
        let clean = path.split(separator: "?")[0]
        let components = clean.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains("~") else { return nil }
        let target = components.reduce(root) { $0.appendingPathComponent($1) }
        guard ["m3u8", "ts"].contains(target.pathExtension) else { return nil }
        let rootPath = root.standardizedFileURL.path + "/"
        guard target.standardizedFileURL.path.hasPrefix(rootPath) else { return nil }
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return target
    }

    private nonisolated static func parseRange(_ value: String, size: Int64) -> ClosedRange<Int64>? {
        guard value.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = value.dropFirst("bytes=".count).split(separator: ",")[0] // multi-range unused by AVPlayer
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let start = Int64(parts[0])
        let end = Int64(parts[1])
        switch (start, end) {
        case let (s?, e?) where s <= e && s < size:
            return s...min(e, size - 1)
        case let (s?, nil) where s < size:
            return s...(size - 1)
        case let (nil, e?) where e > 0: // suffix form: last e bytes
            return max(0, size - e)...(size - 1)
        default:
            return nil
        }
    }

    private nonisolated static func respond(_ connection: NWConnection, status: String, headers: [String: String], body: Data?) {
        var head = "HTTP/1.1 \(status)\r\n"
        var all = headers
        all["Content-Length"] = "\(body?.count ?? 0)"
        all["Connection"] = "close"
        for (k, v) in all { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var payload = Data(head.utf8)
        if let body { payload.append(body) }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Resume-a-continuation-exactly-once guard for Network.framework state
/// callbacks, which can fire multiple times across queues.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
