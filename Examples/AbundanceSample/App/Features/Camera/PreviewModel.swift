import Foundation
import CoreMedia
import AbundanceDeviceKit

/// Drives the live preview from the SDK's primitives: `preview.nalUnits()`
/// (raw ABPV frames) → `H264SampleBufferAssembler` (CMSampleBuffers) →
/// `SampleBufferVideoView`. The viewfinder auto-starts it whenever the camera
/// screen is visible and the device can serve it. start()/stop() are
/// idempotent.
///
/// `PreviewVideoView(preview:)` is the SDK's one-line alternative; this model
/// exists because the viewfinder UI wants connection phases (connecting /
/// streaming / stalled / error) the drop-in view doesn't expose.
@MainActor
@Observable
final class PreviewModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case streaming
        /// Connection open but no data for >2 s — expected for 1-2 s while the
        /// device swaps pipelines around recording start/stop.
        case stalled
        case error(String)
    }

    private(set) var phase: Phase = .idle
    /// Why the stream isn't up yet, surfaced once reconnects stop looking like
    /// a blip (an endless spinner with no reason is undebuggable in the field).
    private(set) var diagnostic: String?
    let videoView = SampleBufferVideoView()

    private let makeStream: @MainActor () -> PreviewStream?
    private var streamTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var lastDataAt: ContinuousClock.Instant?
    private var consecutiveDecodeFailures = 0
    private var failedAttempts = 0
    private var lastFailureMessage: String?

    init(makeStream: @escaping @MainActor () -> PreviewStream?) {
        self.makeStream = makeStream
    }

    func start() {
        guard streamTask == nil else { return }
        phase = .connecting
        consecutiveDecodeFailures = 0
        failedAttempts = 0
        diagnostic = nil
        streamTask = Task { await runLoop() }
        watchdogTask = Task { await watchdog() }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        videoView.flush(clearingImage: true)
        phase = .idle
        diagnostic = nil
    }

    private enum AttemptOutcome {
        case retriable(streamed: Bool)
        case fatal(String)
    }

    private func runLoop() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            let outcome = await attempt()
            if Task.isCancelled { break }
            switch outcome {
            case .fatal(let message):
                // Fail fast: reconnecting can't cure a protocol/permission
                // problem. The card's Retry button calls start() again.
                phase = .error(message)
                streamTask = nil
                watchdogTask?.cancel()
                watchdogTask = nil
                return
            case .retriable(let streamed):
                if streamed {
                    backoff = 1
                    failedAttempts = 0
                    lastFailureMessage = nil
                } else {
                    failedAttempts += 1
                }
                // First failure could be the device swapping pipelines; from the
                // second on, tell the user what's actually going wrong.
                diagnostic = failedAttempts >= 2 ? lastFailureMessage : nil
                phase = .connecting
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 10)
            }
        }
    }

    private func attempt() async -> AttemptOutcome {
        guard let preview = makeStream() else {
            return .fatal("Not connected to the camera — try re-pairing.")
        }
        // Fresh assembler per connection: every (re)connect starts at SPS/PPS+IDR.
        let assembler = H264SampleBufferAssembler()
        var streamed = false
        do {
            for try await nal in preview.nalUnits() {
                if Task.isCancelled { return .retriable(streamed: streamed) }
                lastDataAt = .now
                let frame: H264SampleBufferAssembler.Frame?
                do {
                    frame = try assembler.consume(nal)
                } catch {
                    // Mid-join slice or a torn parameter set: the device
                    // resends SPS/PPS before every IDR, so resync there.
                    assembler.resetToNextIDR()
                    continue
                }
                guard let frame else { continue }
                if frame.formatChanged {
                    videoView.flush(clearingImage: false)
                }
                switch videoView.enqueue(frame.sampleBuffer) {
                case .enqueued:
                    consecutiveDecodeFailures = 0
                    streamed = true
                    if phase != .streaming { phase = .streaming }
                case .needsKeyframe:
                    assembler.resetToNextIDR()
                case .failed:
                    consecutiveDecodeFailures += 1
                    videoView.flush(clearingImage: false)
                    assembler.resetToNextIDR()
                    if consecutiveDecodeFailures >= 3 {
                        return .fatal("Video decoding failed.")
                    }
                }
            }
            // Clean end (device shut the stream down) → reconnect.
            lastFailureMessage = "The camera keeps closing the stream."
            return .retriable(streamed: streamed)
        } catch let error as AbundanceError {
            switch error {
            case .device(let e):
                return .fatal(e.message) // e.g. camera_absent, capability_denied
            case .previewProtocolViolation:
                return .fatal("Preview protocol error — update the app or the device.")
            default:
                // Network drop / timeout / truncation: the reconnect loop owns it.
                lastFailureMessage = streamed
                    ? "The stream stopped: \(DeviceStore.describe(error))"
                    : DeviceStore.describe(error)
                return .retriable(streamed: streamed)
            }
        } catch {
            lastFailureMessage = streamed
                ? "The stream stopped: \(error.localizedDescription)"
                : error.localizedDescription
            return .retriable(streamed: streamed)
        }
    }

    private func watchdog() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            if phase == .streaming,
               let last = lastDataAt,
               ContinuousClock.now - last > .seconds(2) {
                phase = .stalled // next enqueued frame flips back to .streaming
            }
        }
    }
}
