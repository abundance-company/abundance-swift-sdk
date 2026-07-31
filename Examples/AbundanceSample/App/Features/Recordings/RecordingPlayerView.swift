import SwiftUI
import AVKit

/// Full-screen playback of a downloaded session. The session's clips play as
/// one continuous video via its local HLS playlist.
struct RecordingPlayerView: View {
    @Environment(LocalLibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let recording: LocalRecording

    @State private var player: AVPlayer?
    @State private var loadError = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else if loadError {
                    ContentUnavailableView(
                        "Can't play this recording",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The clips are still in Files ▸ Abundance Sample.")
                    )
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(recording.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            do {
                // Playback category so clips are audible even with the silent
                // switch on — this is a review tool, sound is the point.
                try? AVAudioSession.sharedInstance().setCategory(.playback)
                let url = try await library.playbackURL(for: recording)
                let player = AVPlayer(url: url)
                self.player = player
                player.play()
            } catch {
                loadError = true
            }
        }
        .onDisappear {
            player?.pause()
        }
    }
}
