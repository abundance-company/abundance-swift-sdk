import Foundation
import AbundanceDeviceKit

/// Serial offload shared by automatic backlog draining and manual downloads,
/// built on the SDK's whole-session courier: `recordings.offload(_:to:)`
/// persists the manifest, downloads each segment triple with hash
/// verification, acks it (the ack is what deletes the device's copy), then
/// collects the session logs — this store just projects its progress stream
/// into per-session UI phases.
@MainActor
@Observable
final class OffloadStore {
    enum Phase: Equatable {
        case preparing
        case downloading(done: Int, total: Int)
        case finished
        case failed(String)

        var isActive: Bool {
            switch self {
            case .preparing, .downloading: return true
            case .finished, .failed: return false
            }
        }
    }

    private(set) var phases: [String: Phase] = [:]

    /// True while Station upload owns deletion. Automatic drains stay quiet
    /// because firmware rejects their acks with `409 station_enabled`.
    /// Wired by DeviceStore.
    var stationOwnsDeletion: () -> Bool = { false }

    /// Fired after each segment lands on disk, so the library view refreshes.
    var onSaved: (() -> Void)?

    private var offload: SessionOffload?
    private let directory: URL
    private var tasks: [String: Task<Void, Never>] = [:]
    private var drainTask: Task<Void, Never>?
    private var drainRequested = false
    private var pausedSessions: Set<String> = []

    init(directory: URL) {
        self.directory = directory
    }

    func attach(_ offload: SessionOffload) {
        self.offload = offload
    }

    func detach() {
        drainTask?.cancel()
        drainTask = nil
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        offload = nil
    }

    func phase(for sessionID: String) -> Phase? { phases[sessionID] }

    // MARK: - Automatic drain

    /// Called on every connect, `sessionPublished`, and `segmentReady` event.
    /// Correctness never depends on one nudge: `list()` is the authoritative
    /// backlog, and the next connect re-drains anything a failure left behind.
    func drain() {
        drainRequested = true
        guard drainTask == nil, offload != nil else { return }
        drainTask = Task { await runDrain() }
    }

    private func runDrain() async {
        defer { drainTask = nil }
        while drainRequested, !Task.isCancelled, let offload {
            drainRequested = false
            // Station mode: the camera uploads and deletes on its own — an
            // unprompted phone copy here just looks like a rogue offload.
            // Re-checked per session because the flag refreshes async and a
            // publish nudge can race it.
            if stationOwnsDeletion() { return }
            guard let sessions = try? await offload.list() else {
                // Unreachable (typically off the camera's Wi-Fi) — stop; the
                // next connected event drains again.
                return
            }
            // Oldest-first, skipping paused and in-flight sessions. A session
            // in a failed phase is eligible again — this IS the retry.
            let eligible = sessions.reversed().filter {
                $0.state == .ready
                    && !pausedSessions.contains($0.id)
                    && phases[$0.id]?.isActive != true
                    && phases[$0.id] != .finished
            }
            for session in eligible {
                guard !Task.isCancelled, !pausedSessions.contains(session.id) else { continue }
                if stationOwnsDeletion() { return }
                if await !run(session) { return } // transfer failed → wait for the next nudge
            }
        }
    }

    // MARK: - Manual controls

    func download(_ session: RecordingSession) {
        guard phases[session.id]?.isActive != true else { return }
        pausedSessions.remove(session.id)
        tasks[session.id] = Task {
            _ = await run(session)
            tasks[session.id] = nil
        }
    }

    func cancel(_ sessionID: String) {
        // Pausing keeps the automatic drain from immediately restarting it.
        pausedSessions.insert(sessionID)
        tasks[sessionID]?.cancel()
        tasks[sessionID] = nil
        phases[sessionID] = nil
    }

    /// Deletes an `.incomplete` session outright — it can never be acked, so
    /// `discard` is the only way to reclaim its space. Destructive: nothing is
    /// transferred first.
    func discard(_ sessionID: String) async -> Bool {
        guard let offload else { return false }
        do {
            try await offload.discard(sessionID)
            phases[sessionID] = nil
            return true
        } catch {
            phases[sessionID] = .failed(DeviceStore.describe(error))
            return false
        }
    }

    // MARK: - One session, end to end

    private func run(_ session: RecordingSession) async -> Bool {
        guard let offload else { return false }
        phases[session.id] = .preparing
        var ackedSegments = 0
        do {
            for try await progress in offload.offload(session.id, to: directory) {
                guard !Task.isCancelled else {
                    phases[session.id] = nil
                    return false
                }
                switch progress.phase {
                case .manifest:
                    phases[session.id] = .downloading(done: 0, total: session.segmentCount)
                case .segment:
                    // The completion emission (nil artifact) means the triple
                    // is verified on disk and its ack was accepted. If Station
                    // takes ownership mid-run, firmware rejects the ack with
                    // `409 station_enabled`; the next nudge re-drains it.
                    if progress.artifactName == nil {
                        ackedSegments += 1
                        onSaved?()
                    }
                    phases[session.id] = .downloading(done: ackedSegments, total: session.segmentCount)
                case .log, .done:
                    break
                }
            }
            phases[session.id] = .finished
            return true
        } catch {
            if Task.isCancelled {
                phases[session.id] = nil
            } else {
                phases[session.id] = .failed(DeviceStore.describe(error))
            }
            return false
        }
    }
}
