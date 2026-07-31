import SwiftUI
import AbundanceDeviceKit

/// The viewfinder. Starts the live stream by itself whenever the screen is
/// visible and the device can serve it, and recovers on its own after
/// backgrounding, Wi-Fi drops, and record start/stop pipeline swaps.
/// Defaults to the left eye of the stereo pair (a camera-shaped 1.6:1 frame);
/// a toggle shows the full 3.2:1 pair.
struct LivePreviewView: View {
    @Environment(\.abundanceTheme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    let model: PreviewModel
    let store: DeviceStore

    @State private var cropped = true
    @State private var isVisible = false

    var body: some View {
        ZStack {
            SampleBufferHost(view: model.videoView)
            overlay
        }
        .aspectRatio(cropped ? 1920.0 / 1200.0 : 3840.0 / 1200.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: AbundanceRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AbundanceRadius.xl, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.25), value: cropped)
        .onAppear {
            isVisible = true
            model.videoView.cropsToLeftEye = cropped
            drive()
        }
        .onDisappear {
            isVisible = false
            drive()
        }
        .onChange(of: scenePhase) { drive() }
        .onChange(of: shouldStream) { drive() }
    }

    /// The device serves preview whenever the camera is usable — directly when
    /// idle, tapped off the recorder while a take runs.
    private var shouldStream: Bool {
        guard store.isConnected, store.snapshot?.stream?.available == true else { return false }
        switch store.recordPhase {
        case .recording, .starting, .stopping: return true
        default: return store.snapshot?.cameraState == .ready
        }
    }

    private func drive() {
        if isVisible && scenePhase == .active && shouldStream {
            model.start()
        } else {
            model.stop()
        }
    }

    @ViewBuilder private var overlay: some View {
        if !shouldStream {
            placeholder
        } else {
            switch model.phase {
            case .idle, .connecting:
                VStack(spacing: AbundanceSpacing.xs) {
                    ProgressView().tint(.white)
                    if let diagnostic = model.diagnostic {
                        Text(diagnostic)
                            .font(AbundanceFont.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, AbundanceSpacing.md)
                    }
                }
            case .streaming:
                streamingChrome
            case .stalled:
                streamingChrome
                Text("Resuming…")
                    .font(AbundanceFont.caption)
                    .foregroundStyle(.white)
                    .padding(AbundanceSpacing.xs)
                    .background(.black.opacity(0.5), in: Capsule())
            case .error(let message):
                VStack(spacing: AbundanceSpacing.xs) {
                    Text(message)
                        .font(AbundanceFont.caption)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button("Retry") { model.start() }
                        .font(AbundanceFont.label)
                        .foregroundStyle(theme.textAccentOcean)
                }
                .padding(AbundanceSpacing.md)
            }
        }
    }

    /// Wordless — the camera screen's issue banner explains what's wrong.
    @ViewBuilder private var placeholder: some View {
        if !store.isConnected {
            ProgressView().tint(.white.opacity(0.6))
        } else {
            Image(systemName: "video.slash")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// In-frame controls while live: REC badge + timer, and the crop toggle.
    @ViewBuilder private var streamingChrome: some View {
        VStack {
            HStack(alignment: .top) {
                if store.recordPhase == .recording || store.recordPhase == .starting {
                    recBadge
                }
                Spacer()
                Button {
                    cropped.toggle()
                    model.videoView.cropsToLeftEye = cropped
                } label: {
                    Image(systemName: cropped ? "square.split.2x1" : "rectangle.center.inset.filled")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(AbundanceSpacing.xs)
                        .background(.black.opacity(0.5), in: Circle())
                }
                .accessibilityLabel(cropped ? "Show both lenses" : "Show one lens")
            }
            Spacer()
        }
        .padding(AbundanceSpacing.sm)
    }

    /// Dot + REC only — the big elapsed-time readout lives above the frame.
    private var recBadge: some View {
        HStack(spacing: AbundanceSpacing.xxs) {
            Circle().fill(theme.bgRecord).frame(width: 8, height: 8)
            Text("REC")
                .font(AbundanceFont.label)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, AbundanceSpacing.xs)
        .padding(.vertical, AbundanceSpacing.xxs)
        .background(.black.opacity(0.5), in: Capsule())
    }
}

/// Hosts the SDK's `SampleBufferVideoView` (an AVSampleBufferDisplayLayer
/// wrapper) in SwiftUI so the model can enqueue frames imperatively.
private struct SampleBufferHost: UIViewRepresentable {
    let view: SampleBufferVideoView

    func makeUIView(context: Context) -> SampleBufferVideoView { view }
    func updateUIView(_ uiView: SampleBufferVideoView, context: Context) {}
}
