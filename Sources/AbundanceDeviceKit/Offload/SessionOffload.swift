import Foundation

/// Session offload: list, download with verification, ack, discard, logs —
/// plus the whole-session courier. Requires `offload`.
///
/// The contract: nothing is deleted until you ack, the ack carries the hashes
/// of what you downloaded, and acks go in segment order. A failed download
/// costs nothing.
public struct SessionOffload: Sendable {
    let connection: DeviceConnection

    init(connection: DeviceConnection) {
        self.connection = connection
    }

    // MARK: - Listing

    /// Every published session on the card, newest first. The authoritative
    /// backlog — drain it on every connect and reconnect. Sessions still
    /// recording or converting are absent.
    public func list() async throws -> [RecordingSession] {
        struct Response: Decodable { let recordings: [Wire] }
        struct Wire: Decodable {
            let id: String
            let segmentCount: Int
            let totalBytes: Int64
            let state: String
            let reason: String?
        }
        let response: Response = try await connection.get("/v1/recordings")
        return response.recordings.map {
            RecordingSession(
                id: $0.id,
                segmentCount: $0.segmentCount,
                totalBytes: $0.totalBytes,
                state: SessionState($0.state),
                reason: $0.reason
            )
        }
    }

    /// The session's manifest. Persist it before acking anything — it is your
    /// only copy of the timing guarantees once the device's copy is gone.
    public func manifest(_ sessionID: String) async throws -> RecordingManifest {
        try await rawManifest(sessionID).manifest
    }

    /// Wire bytes + decoded manifest in one fetch, so the courier can persist
    /// the document verbatim.
    func rawManifest(_ sessionID: String) async throws -> (data: Data, manifest: RecordingManifest) {
        let (data, _) = try await connection.data("/v1/recordings/\(escaped(sessionID))/manifest")
        do {
            return (data, try JSONDecoder.abundance.decode(RecordingManifest.self, from: data))
        } catch {
            throw AbundanceError.decoding(String(describing: error))
        }
    }

    // MARK: - Downloads

    /// One segment's video (MPEG-TS, ~120 s), streamed to `destination` with
    /// resume and verified against the manifest before returning.
    public func downloadSegment(_ sessionID: String, index: Int, to destination: URL) async throws {
        let segment = try await segmentInfo(sessionID, index: index)
        try await connection.download(
            segmentPath(sessionID, index),
            to: destination,
            expectedSHA256: segment.video.sha256
        )
    }

    /// The segment's IMU CSV, verified.
    public func downloadIMU(_ sessionID: String, index: Int, to destination: URL) async throws {
        let segment = try await segmentInfo(sessionID, index: index)
        try await connection.download(
            segmentPath(sessionID, index) + "/imu",
            to: destination,
            expectedSHA256: segment.imu.sha256
        )
    }

    /// The segment's frame-timing CSV, verified.
    public func downloadFrames(_ sessionID: String, index: Int, to destination: URL) async throws {
        let segment = try await segmentInfo(sessionID, index: index)
        try await connection.download(
            segmentPath(sessionID, index) + "/frames",
            to: destination,
            expectedSHA256: segment.frames.sha256
        )
    }

    /// One segment triple into `directory` under the artifacts' wire names,
    /// each verified. Deliberately does NOT ack — ack only after your own
    /// bookkeeping records the files as safely stored.
    public func fetchSegment(
        _ sessionID: String,
        segment: SegmentInfo,
        into directory: URL
    ) async throws -> SegmentFiles {
        let files = SegmentFiles(
            videoURL: directory.appending(path: segment.video.name),
            imuURL: directory.appending(path: segment.imu.name),
            framesURL: directory.appending(path: segment.frames.name)
        )
        try await connection.download(
            segmentPath(sessionID, segment.index),
            to: files.videoURL,
            expectedSHA256: segment.video.sha256
        )
        try await connection.download(
            segmentPath(sessionID, segment.index) + "/imu",
            to: files.imuURL,
            expectedSHA256: segment.imu.sha256
        )
        try await connection.download(
            segmentPath(sessionID, segment.index) + "/frames",
            to: files.framesURL,
            expectedSHA256: segment.frames.sha256
        )
        return files
    }

    // MARK: - Reclaim

    /// The ack IS the delete: the device re-checks all three hashes against
    /// its copies, then unlinks the triple. All three are required
    /// (fail-closed), and acks must go in index order — ahead-of-order
    /// returns `.device(.segmentActive)`.
    public func ack(
        _ sessionID: String,
        index: Int,
        video: String,
        imu: String,
        frames: String
    ) async throws {
        struct Response: Decodable { let acked: Bool }
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "sha256", value: video),
            URLQueryItem(name: "csv_sha256", value: imu),
            URLQueryItem(name: "frames_sha256", value: frames),
        ]
        let query = components.percentEncodedQuery ?? ""
        let _: Response = try await connection.delete(
            "/v1/recordings/\(escaped(sessionID))/segments/\(index)?\(query)"
        )
    }

    /// Deletes a session outright — recordings, staging, and logs — with no
    /// hash proof and nothing transferred first. The escape hatch for a
    /// session marked `.incomplete`, which can never be acked; on a ready one
    /// you are throwing away good data.
    public func discard(_ sessionID: String) async throws {
        struct Response: Decodable { let discarded: Bool }
        let _: Response = try await connection.delete("/v1/recordings/\(escaped(sessionID))")
    }

    // MARK: - Session logs

    /// Finalized logs for a session: `uvc.log`, `wifi.log`, `device.log`,
    /// `capture-health.json`, `clock-model.json`. A log appears only after it
    /// has stopped growing.
    public func logs(_ sessionID: String) async throws -> [LogArtifact] {
        struct Response: Decodable {
            let id: String
            let logs: [LogArtifact]
        }
        let response: Response = try await connection.get(
            "/v1/recordings/\(escaped(sessionID))/logs"
        )
        return response.logs
    }

    /// One log, verified against its listed hash.
    public func downloadLog(_ sessionID: String, name: String, to destination: URL) async throws {
        let artifacts = try await logs(sessionID)
        guard let artifact = artifacts.first(where: { $0.name == name }) else {
            throw AbundanceError.device(DeviceError(
                code: .notFound,
                message: "log \(name) is not listed for session \(sessionID)",
                retryable: false
            ))
        }
        try await connection.download(
            logPath(sessionID, name),
            to: destination,
            expectedSHA256: artifact.sha256
        )
    }

    /// Ack-and-delete one log. `sha256` is optional; when present the device
    /// verifies it first.
    public func ackLog(_ sessionID: String, name: String, sha256: String? = nil) async throws {
        struct Response: Decodable { let acked: Bool }
        var path = "/v1/recordings/\(escaped(sessionID))/logs/\(escaped(name))"
        if let sha256 {
            var components = URLComponents()
            components.queryItems = [URLQueryItem(name: "sha256", value: sha256)]
            path += "?" + (components.percentEncodedQuery ?? "")
        }
        let _: Response = try await connection.delete(path)
    }

    // MARK: - Paths

    func segmentPath(_ sessionID: String, _ index: Int) -> String {
        "/v1/recordings/\(escaped(sessionID))/segments/\(index)"
    }

    func logPath(_ sessionID: String, _ name: String) -> String {
        "/v1/recordings/\(escaped(sessionID))/logs/\(escaped(name))"
    }

    private func segmentInfo(_ sessionID: String, index: Int) async throws -> SegmentInfo {
        let manifest = try await manifest(sessionID)
        guard let segment = manifest.segments.first(where: { $0.index == index }) else {
            throw AbundanceError.device(DeviceError(
                code: .notFound,
                message: "segment \(index) is not in the manifest for \(sessionID)",
                retryable: false
            ))
        }
        return segment
    }

    private func escaped(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? component
    }
}
