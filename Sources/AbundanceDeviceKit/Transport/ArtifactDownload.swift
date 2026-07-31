import Foundation
import CryptoKit

extension DeviceConnection {
    /// Streams one artifact to disk with resume and verification:
    ///
    /// - An interrupted transfer leaves `<destination>.partial`; the next call
    ///   hashes the prefix and continues from its byte count with a `Range`
    ///   request (206), so a 240 MB segment is never restarted for a Wi-Fi blip.
    /// - Bytes are SHA-256-hashed as they arrive and verified against the
    ///   manifest hash before the file reaches `destination` — a mismatch
    ///   deletes the partial and throws, so no unverified file survives.
    /// - `progress` reports cumulative bytes (including any resumed prefix).
    func download(
        _ path: String,
        to destination: URL,
        expectedSHA256: String,
        progress: (@Sendable (Int64) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // A finished file from an earlier run (e.g. the courier re-driving a
        // session after the ack failed) is accepted only if it still hashes
        // to the manifest value.
        if fm.fileExists(atPath: destination.path) {
            if Data(try hashFile(destination)).hexString == expectedSHA256 {
                progress?(fileSize(destination))
                return
            }
            try fm.removeItem(at: destination)
        }

        let partial = destination.appendingPathExtension("partial")
        var hasher = SHA256()
        var received: Int64 = 0
        if fm.fileExists(atPath: partial.path) {
            received = try hashInto(&hasher, file: partial)
        }

        var request = request("GET", path, body: nil)
        if received > 0 {
            request.setValue("bytes=\(received)-", forHTTPHeaderField: "Range")
        }

        let bytes: URLSession.AsyncBytes
        let http: HTTPURLResponse
        do {
            let (b, response) = try await streamingSession.bytes(for: request)
            guard let h = response as? HTTPURLResponse else {
                throw AbundanceError.transport("non-HTTP response")
            }
            bytes = b
            http = h
        } catch let error as AbundanceError {
            throw error
        } catch {
            throw AbundanceError.transport(error.localizedDescription)
        }

        switch http.statusCode {
        case 206:
            break // appending to the partial
        case 200:
            // The device served the whole artifact (no partial, or it ignored
            // the Range — which RFC 9110 allows). Start the hash and the file
            // over.
            if received > 0 {
                try? fm.removeItem(at: partial)
                hasher = SHA256()
                received = 0
            }
        default:
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 4096 { break }
            }
            throw DeviceConnection.error(status: http.statusCode, body: body)
        }

        // The device sends its stored hash with every artifact. If it already
        // disagrees with the manifest, the device's copy is corrupt and the
        // download can never verify — fail before moving the bytes.
        if let deviceHash = http.value(forHTTPHeaderField: "X-Abundance-SHA256"),
           deviceHash != expectedSHA256 {
            throw AbundanceError.hashMismatch(
                artifact: destination.lastPathComponent,
                expected: expectedSHA256,
                computed: deviceHash
            )
        }

        if !fm.fileExists(atPath: partial.path) {
            fm.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var buffer = Data(capacity: Self.flushThreshold)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Self.flushThreshold {
                    hasher.update(data: buffer)
                    try handle.write(contentsOf: buffer)
                    received += Int64(buffer.count)
                    progress?(received)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        } catch {
            // Keep the partial for resume; the bytes written so far are good.
            if !buffer.isEmpty {
                hasher.update(data: buffer)
                try? handle.write(contentsOf: buffer)
            }
            throw AbundanceError.transport(error.localizedDescription)
        }
        if !buffer.isEmpty {
            hasher.update(data: buffer)
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            progress?(received)
        }
        try handle.close()

        let computed = Data(hasher.finalize()).hexString
        guard computed == expectedSHA256 else {
            // The partial is poison — a retry must start clean.
            try? fm.removeItem(at: partial)
            throw AbundanceError.hashMismatch(
                artifact: destination.lastPathComponent,
                expected: expectedSHA256,
                computed: computed
            )
        }
        _ = try fm.replaceItemAt(destination, withItemAt: partial)
    }

    private static let flushThreshold = 128 << 10

    /// Long downloads get their own session: the JSON session's default
    /// timeouts are tuned for small calls, while a segment transfer needs an
    /// idle-data timeout that survives SD-card I/O stalls.
    private var streamingSession: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: config)
    }

    private func hashFile(_ url: URL) throws -> SHA256.Digest {
        var hasher = SHA256()
        _ = try hashInto(&hasher, file: url)
        return hasher.finalize()
    }

    /// Streams `file` through `hasher`; returns its byte count.
    private func hashInto(_ hasher: inout SHA256, file: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        return total
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64).flatMap { $0 } ?? 0
    }
}

extension Data {
    /// Lowercase hex, the wire's hash spelling.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
