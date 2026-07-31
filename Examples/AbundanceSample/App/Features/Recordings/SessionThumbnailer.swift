import AVFoundation
import CoreImage
import UIKit

/// Captures a poster frame from a local HLS session.
/// `AVAssetImageGenerator` does not support HLS assets (verified: it hangs
/// indefinitely), so this drives a muted off-screen AVPlayer and copies the
/// first rendered pixel buffer through `AVPlayerItemVideoOutput`.
enum SessionThumbnailer {
    /// Longest we let the pipeline warm up before giving up. Local loopback
    /// reads are fast; a session that can't produce a frame in this window is
    /// undecodable and the row keeps its placeholder.
    private static let deadline: Duration = .seconds(6)
    private static let maxWidth: CGFloat = 640

    @MainActor
    static func capture(from playbackURL: URL) async -> UIImage? {
        let asset = AVURLAsset(url: playbackURL)
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        defer { player.pause() }

        let clock = ContinuousClock()
        let start = clock.now
        while clock.now - start < deadline {
            let t = player.currentTime()
            if output.hasNewPixelBuffer(forItemTime: t),
               let buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) {
                return render(buffer)
            }
            if item.status == .failed { return nil }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func render(_ buffer: CVPixelBuffer) -> UIImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        // The frame is the side-by-side stereo pair — a poster wants one eye.
        let extent = image.extent
        if extent.width >= extent.height * 2 {
            image = image.cropped(to: CGRect(
                x: extent.minX, y: extent.minY, width: extent.width / 2, height: extent.height
            ))
        }
        let scale = min(1, maxWidth / image.extent.width)
        if scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let context = CIContext()
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
