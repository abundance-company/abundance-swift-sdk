#if canImport(UIKit)
import UIKit
import SwiftUI
import AVFoundation
import CoreMedia

/// UIView hosting an `AVSampleBufferDisplayLayer`, driven through its
/// `sampleBufferRenderer` (the non-deprecated path on iOS 17+). Enqueue
/// imperatively from the main actor; SwiftUI users get `PreviewVideoView`.
@MainActor
public final class SampleBufferVideoView: UIView {
    public enum EnqueueResult {
        case enqueued
        /// Frame not displayable right now (decoder needs a flush, or the
        /// render queue is saturated) — resync the assembler to the next IDR.
        case needsKeyframe
        case failed(Error?)
    }

    /// The device streams the recorder's side-by-side stereo pair. A
    /// viewfinder usually wants just the left eye, so the display layer is
    /// laid out at twice the view's width (left half visible, right eye
    /// clipped) instead of letterboxing the full ~3.2:1 strip.
    public var cropsToLeftEye = false {
        didSet { if cropsToLeftEye != oldValue { setNeedsLayout() } }
    }

    private let displayLayer = AVSampleBufferDisplayLayer()

    private var renderer: AVSampleBufferVideoRenderer {
        displayLayer.sampleBufferRenderer
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        // Sublayer frame changes implicitly animate; a viewfinder resize must
        // track the view exactly or frames smear during rotation/crop toggles.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if cropsToLeftEye {
            displayLayer.frame = CGRect(x: 0, y: 0, width: bounds.width * 2, height: bounds.height)
        } else {
            displayLayer.frame = bounds
        }
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SampleBufferVideoView is code-constructed only")
    }

    public func enqueue(_ sample: CMSampleBuffer) -> EnqueueResult {
        // Set after backgrounding invalidates the decode session; enqueueing
        // before flushing would fail.
        if renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            return .needsKeyframe
        }
        // DisplayImmediately keeps the queue drained; a saturated queue means
        // the renderer stalled — drop P frames until the next IDR instead of
        // queueing latency.
        guard renderer.isReadyForMoreMediaData else {
            return .needsKeyframe
        }
        renderer.enqueue(sample)
        if renderer.status == .failed {
            let error = renderer.error
            renderer.flush()
            return .failed(error)
        }
        return .enqueued
    }

    public func flush(clearingImage: Bool) {
        if clearingImage {
            renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        } else {
            renderer.flush()
        }
    }
}

/// Drop-in SwiftUI viewfinder: connects on appear, disconnects on disappear,
/// reconnects after transport gaps (recording start/stop stalls, camera
/// replug), and stops for good on a protocol violation.
public struct PreviewVideoView: View {
    private let preview: PreviewStream
    private let cropsToLeftEye: Bool

    public init(preview: PreviewStream, cropsToLeftEye: Bool = true) {
        self.preview = preview
        self.cropsToLeftEye = cropsToLeftEye
    }

    public var body: some View {
        PreviewMount(preview: preview, cropsToLeftEye: cropsToLeftEye)
    }
}

private struct PreviewMount: UIViewRepresentable {
    let preview: PreviewStream
    let cropsToLeftEye: Bool

    func makeUIView(context: Context) -> SampleBufferVideoView {
        let view = SampleBufferVideoView()
        view.cropsToLeftEye = cropsToLeftEye
        context.coordinator.start(preview: preview, view: view)
        return view
    }

    func updateUIView(_ view: SampleBufferVideoView, context: Context) {
        view.cropsToLeftEye = cropsToLeftEye
    }

    static func dismantleUIView(_ view: SampleBufferVideoView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var task: Task<Void, Never>?

        func start(preview: PreviewStream, view: SampleBufferVideoView) {
            guard task == nil else { return }
            task = Task { [weak view] in
                let assembler = H264SampleBufferAssembler()
                while !Task.isCancelled {
                    do {
                        for try await nal in preview.nalUnits() {
                            guard let view else { return }
                            let frame: H264SampleBufferAssembler.Frame?
                            do {
                                frame = try assembler.consume(nal)
                            } catch {
                                // Mid-join slice or a torn parameter set: the
                                // device resends SPS/PPS before every IDR, so
                                // resync there instead of tearing down.
                                assembler.resetToNextIDR()
                                continue
                            }
                            guard let frame else { continue }
                            if frame.formatChanged {
                                view.flush(clearingImage: false)
                            }
                            switch view.enqueue(frame.sampleBuffer) {
                            case .enqueued:
                                break
                            case .needsKeyframe:
                                assembler.resetToNextIDR()
                            case .failed:
                                assembler.resetToNextIDR()
                                view.flush(clearingImage: false)
                            }
                        }
                    } catch let error as AbundanceError {
                        if case .previewProtocolViolation = error {
                            return // reconnecting cannot fix a protocol mismatch
                        }
                    } catch {}
                    if Task.isCancelled { return }
                    // Recording start/stop stalls the pipeline 1–2 s; camera
                    // or card absence clears when the operator fixes it.
                    try? await Task.sleep(for: .seconds(1))
                    assembler.resetToNextIDR()
                }
            }
        }

        func stop() {
            task?.cancel()
            task = nil
        }
    }
}
#endif
