import Foundation

/// The live event stream (`GET /v1/events`, SSE). Requires `metrics`.
///
/// Multi-observer: every `subscribe()` gets its own stream fed from one
/// shared connection, which opens with the first subscriber and closes after
/// the last one cancels. Reconnects automatically with 1 s → 60 s backoff;
/// every (re)connect starts with a fresh full snapshot.
public struct DeviceEvents: Sendable {
    private let broadcaster: EventBroadcaster

    init(broadcaster: EventBroadcaster) {
        self.broadcaster = broadcaster
    }

    /// Subscribe by iterating; cancel by ending the loop.
    public func subscribe() -> AsyncStream<AbundanceEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let id = UUID()
            let broadcaster = broadcaster
            continuation.onTermination = { _ in
                Task { await broadcaster.remove(id) }
            }
            Task { await broadcaster.add(id, continuation) }
        }
    }

    /// The most recent snapshot seen on the stream, from any frame kind.
    public func latestSnapshot() async -> DeviceSnapshot? {
        await broadcaster.latest
    }
}

/// One shared SSE connection fanned out to every subscriber.
actor EventBroadcaster {
    private let connection: DeviceConnection
    private var continuations: [UUID: AsyncStream<AbundanceEvent>.Continuation] = [:]
    private var pump: Task<Void, Never>?
    private(set) var latest: DeviceSnapshot?

    init(connection: DeviceConnection) {
        self.connection = connection
    }

    func add(_ id: UUID, _ continuation: AsyncStream<AbundanceEvent>.Continuation) {
        continuations[id] = continuation
        if pump == nil {
            pump = Task { await run() }
        }
    }

    func remove(_ id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            pump?.cancel()
            pump = nil
        }
    }

    private func broadcast(_ event: AbundanceEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func run() async {
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled, !continuations.isEmpty {
            do {
                try await streamOnce()
                // Clean end (device closed the response) — reconnect promptly:
                // the wire has no resume, a fresh connect re-snapshots.
                broadcast(.disconnected(reason: nil))
                backoff = .seconds(1)
            } catch {
                broadcast(.disconnected(reason: describe(error)))
            }
            if Task.isCancelled || continuations.isEmpty { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(60))
        }
    }

    private func streamOnce() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        // Idle-data timeout: the device sends a ": ping" comment every 15 s,
        // so 60 s of silence means the connection is dead, not quiet.
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: connection.url(for: "/v1/events"))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let token = await connection.bearerToken() {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AbundanceError.transport("non-HTTP response")
        }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 4096 { break }
            }
            throw DeviceConnection.error(status: http.statusCode, body: body)
        }

        broadcast(.connected)
        for try await line in bytes.lines {
            if Task.isCancelled { break }
            guard line.hasPrefix("data: ") else { continue } // ": ping" keep-alives, blanks
            // Forward compatibility: a frame shape this build has never seen
            // must not kill the stream for the frames it does understand.
            guard let data = line.dropFirst(6).data(using: .utf8),
                  let envelope = try? JSONDecoder.abundance.decode(Envelope<LiveFrame>.self, from: data)
            else { continue }
            handle(envelope.data)
        }
    }

    private func handle(_ frame: LiveFrame) {
        if let snapshot = frame.snapshot {
            latest = snapshot
        }
        switch frame.type {
        case "snapshot":
            guard let snapshot = frame.snapshot else { return }
            broadcast(.snapshot(snapshot))
        case "state":
            guard let snapshot = frame.snapshot else { return }
            broadcast(.stateChanged(snapshot, source: StateSource(frame.source)))
        case "telemetry":
            guard let snapshot = frame.snapshot else { return }
            broadcast(.telemetry(snapshot))
        case "session_published":
            guard let session = frame.session else { return }
            broadcast(.sessionPublished(
                sessionID: session,
                segmentCount: frame.segmentCount ?? 0
            ))
        case "segment_ready":
            guard let segment = frame.segment else { return }
            broadcast(.segmentReady(segment))
        case "error":
            guard let code = frame.code else { return }
            broadcast(.deviceError(
                code: EventCode(code),
                message: frame.message ?? "",
                snapshot: frame.snapshot
            ))
        default:
            break // future event types ride through unannounced
        }
    }

    private func describe(_ error: Error) -> String {
        if case AbundanceError.device(let deviceError) = error {
            return deviceError.message
        }
        return String(describing: error)
    }
}
