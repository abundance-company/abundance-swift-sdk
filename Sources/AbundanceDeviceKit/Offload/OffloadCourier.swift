import Foundation

public extension SessionOffload {
    /// The whole courier in one call: persists the manifest, walks segments
    /// oldest-first (download, verify, ack), then collects and acks the
    /// session logs. Consume the returned stream for progress; it finishes
    /// when the session is fully offloaded.
    ///
    /// Resumable at any point: partial downloads continue from their byte
    /// count, finished files re-verify instead of re-downloading, and already
    /// acked segments are simply gone from the manifest on the next run.
    func offload(
        _ sessionID: String,
        to directory: URL,
        includeLogs: Bool = true
    ) -> AsyncThrowingStream<OffloadProgress, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let task = Task {
                do {
                    try await runOffload(sessionID, into: directory, includeLogs: includeLogs) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension SessionOffload {
    func runOffload(
        _ sessionID: String,
        into root: URL,
        includeLogs: Bool,
        emit: @escaping @Sendable (OffloadProgress) -> Void
    ) async throws {
        let directory = root.appending(path: sessionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The manifest is persisted verbatim FIRST: once every segment is
        // acked the device forgets the session, and this file is the only
        // remaining record of its hashes and timing guarantees.
        let (manifestData, manifest) = try await rawManifest(sessionID)
        try manifestData.write(
            to: directory.appending(path: "session-manifest.json"),
            options: .atomic
        )
        emit(OffloadProgress(
            sessionID: sessionID,
            phase: .manifest,
            artifactName: "session-manifest.json",
            bytesReceived: Int64(manifestData.count),
            totalBytes: Int64(manifestData.count),
            acked: false
        ))

        for segment in manifest.segments.sorted(by: { $0.index < $1.index }) {
            let artifacts: [(ArtifactRef, String)] = [
                (segment.video, segmentPath(sessionID, segment.index)),
                (segment.imu, segmentPath(sessionID, segment.index) + "/imu"),
                (segment.frames, segmentPath(sessionID, segment.index) + "/frames"),
            ]
            for (artifact, path) in artifacts {
                try await connection.download(
                    path,
                    to: directory.appending(path: artifact.name),
                    expectedSHA256: artifact.sha256
                ) { received in
                    emit(OffloadProgress(
                        sessionID: sessionID,
                        phase: .segment(segment.index),
                        artifactName: artifact.name,
                        bytesReceived: received,
                        totalBytes: artifact.sizeBytes,
                        acked: false
                    ))
                }
            }
            try await ack(
                sessionID,
                index: segment.index,
                video: segment.video.sha256,
                imu: segment.imu.sha256,
                frames: segment.frames.sha256
            )
            let tripleBytes = segment.video.sizeBytes + segment.imu.sizeBytes + segment.frames.sizeBytes
            emit(OffloadProgress(
                sessionID: sessionID,
                phase: .segment(segment.index),
                artifactName: nil,
                bytesReceived: tripleBytes,
                totalBytes: tripleBytes,
                acked: true
            ))
        }

        if includeLogs {
            // Session logs live in a parallel directory and survive the
            // segment acks above; they ack independently.
            let logsDirectory = directory.appending(path: "logs")
            for log in try await logs(sessionID) {
                try await connection.download(
                    logPath(sessionID, log.name),
                    to: logsDirectory.appending(path: log.name),
                    expectedSHA256: log.sha256
                ) { received in
                    emit(OffloadProgress(
                        sessionID: sessionID,
                        phase: .log(log.name),
                        artifactName: log.name,
                        bytesReceived: received,
                        totalBytes: log.sizeBytes,
                        acked: false
                    ))
                }
                try await ackLog(sessionID, name: log.name, sha256: log.sha256)
                emit(OffloadProgress(
                    sessionID: sessionID,
                    phase: .log(log.name),
                    artifactName: nil,
                    bytesReceived: log.sizeBytes,
                    totalBytes: log.sizeBytes,
                    acked: true
                ))
            }
        }

        emit(OffloadProgress(
            sessionID: sessionID,
            phase: .done,
            artifactName: nil,
            bytesReceived: 0,
            totalBytes: 0,
            acked: true
        ))
    }
}
