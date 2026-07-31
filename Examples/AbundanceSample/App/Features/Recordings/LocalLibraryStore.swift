import Foundation
import UIKit

/// A downloaded recording session on this phone: one folder of `.ts` clips
/// (plus their IMU CSVs) under Documents/Recordings.
struct LocalRecording: Identifiable, Equatable, Sendable {
    let id: String
    let directory: URL
    let clipCount: Int
    let totalBytes: Int64
    /// Summed clip durations from their PCR clocks; nil when unreadable.
    let durationSeconds: Double?
    let startDate: Date?

    var title: String {
        guard let startDate else { return "Session \(id.prefix(12))" }
        return startDate.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The phone-side recordings library. Owns the Documents/Recordings tree the
/// offload flows write into: scans it into displayable models, maintains each
/// session's hidden HLS playlist (how AVPlayer plays bare `.ts` files), vends
/// loopback playback URLs, and generates poster thumbnails.
@MainActor
@Observable
final class LocalLibraryStore {
    private(set) var recordings: [LocalRecording] = []
    private(set) var thumbnails: [String: UIImage] = [:]

    static let playlistName = ".playlist.m3u8"

    private let root: URL
    private let server: LocalMediaServer
    private var durationCache: [String: (size: Int64, seconds: Double?)] = [:]
    private var refreshTask: Task<Void, Never>?
    private var thumbnailChain: Task<Void, Never>?
    private var thumbnailsRequested: Set<String> = []

    init(root: URL? = nil) {
        let dir = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        self.root = dir
        self.server = LocalMediaServer(root: dir)
    }

    /// Rescans the library. Coalesces: a refresh requested mid-scan restarts
    /// the scan rather than stacking.
    func refresh() {
        refreshTask?.cancel()
        let root = root
        let cache = durationCache
        refreshTask = Task {
            // Duration probing reads a few MB per clip — keep it off the main actor.
            let result = await Task.detached(priority: .utility) {
                Self.scan(root: root, durationCache: cache)
            }.value
            guard !Task.isCancelled else { return }
            durationCache = result.cache
            recordings = result.recordings
        }
    }

    func playbackURL(for recording: LocalRecording) async throws -> URL {
        try await server.url(for: "\(recording.id)/\(Self.playlistName)")
    }

    func delete(_ recording: LocalRecording) {
        try? FileManager.default.removeItem(at: recording.directory)
        try? FileManager.default.removeItem(at: Self.thumbnailURL(for: recording.id))
        thumbnails[recording.id] = nil
        thumbnailsRequested.remove(recording.id)
        recordings.removeAll { $0.id == recording.id }
    }

    // MARK: - thumbnails

    /// Loads or generates the poster for a session. Generation spins up a real
    /// (muted, invisible) playback pipeline — the only frame-capture path that
    /// works for HLS — so requests are chained one at a time.
    func requestThumbnail(for recording: LocalRecording) {
        let id = recording.id
        guard thumbnails[id] == nil, !thumbnailsRequested.contains(id) else { return }
        thumbnailsRequested.insert(id)

        if let cached = UIImage(contentsOfFile: Self.thumbnailURL(for: id).path) {
            thumbnails[id] = cached
            return
        }

        let previous = thumbnailChain
        thumbnailChain = Task {
            await previous?.value
            guard let url = try? await playbackURL(for: recording),
                  let image = await SessionThumbnailer.capture(from: url) else { return }
            thumbnails[id] = image
            if let data = image.jpegData(compressionQuality: 0.7) {
                try? FileManager.default.createDirectory(
                    at: Self.thumbnailURL(for: id).deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: Self.thumbnailURL(for: id), options: .atomic)
            }
        }
    }

    private static func thumbnailURL(for id: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecordingThumbnails", isDirectory: true)
            .appendingPathComponent("\(id).jpg")
    }

    // MARK: - scanning (nonisolated)

    private nonisolated static func scan(
        root: URL,
        durationCache: [String: (size: Int64, seconds: Double?)]
    ) -> (recordings: [LocalRecording], cache: [String: (size: Int64, seconds: Double?)]) {
        let fm = FileManager.default
        var cache = durationCache
        guard let sessionDirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey]
        ) else { return ([], cache) }

        var out: [LocalRecording] = []
        for dir in sessionDirs {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { continue }

            let clips = files.filter { $0.pathExtension == "ts" }
                .sorted { segmentIndex($0.lastPathComponent) < segmentIndex($1.lastPathComponent) }
            guard !clips.isEmpty else { continue }

            var totalBytes: Int64 = 0
            for f in files where ["ts", "csv"].contains(f.pathExtension) {
                totalBytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }

            var durations: [Double?] = []
            for clip in clips {
                let size = Int64((try? clip.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                if let hit = cache[clip.path], hit.size == size {
                    durations.append(hit.seconds)
                } else {
                    let seconds = TSDuration.seconds(of: clip)
                    cache[clip.path] = (size, seconds)
                    durations.append(seconds)
                }
            }
            let known = durations.compactMap { $0 }
            let total: Double? = known.count == clips.count ? known.reduce(0, +) : nil

            writePlaylistIfChanged(in: dir, clips: clips, durations: durations)

            let id = dir.lastPathComponent
            out.append(LocalRecording(
                id: id,
                directory: dir,
                clipCount: clips.count,
                totalBytes: totalBytes,
                durationSeconds: total,
                startDate: sessionDate(id: id, directory: dir)
            ))
        }
        out.sort { ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast) }
        return (out, cache)
    }

    /// Ids without a start time in the name fall back to the folder's creation
    /// date — when the first clip landed on the phone, the honest stand-in.
    private nonisolated static func sessionDate(id: String, directory: URL) -> Date? {
        SessionDisplay.startDate(fromID: id)
            ?? (try? directory.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    private nonisolated static func segmentIndex(_ name: String) -> Int {
        // `<session>_<index>.ts` — numeric sort; lexicographic breaks past 9
        // if indices ever ship unpadded.
        let stem = name.replacingOccurrences(of: ".ts", with: "")
        return Int(stem.split(separator: "_").last ?? "") ?? 0
    }

    private nonisolated static func writePlaylistIfChanged(in dir: URL, clips: [URL], durations: [Double?]) {
        // The device cuts segments at a nominal 120 s; clips whose PCR couldn't
        // be read still need a declared EXTINF, and a nominal value only skews
        // seek targets, never playback.
        let declared = durations.map { $0 ?? 120.0 }
        let target = Int((declared.max() ?? 120).rounded(.up))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        for (clip, seconds) in zip(clips, declared) {
            lines.append(String(format: "#EXTINF:%.3f,", seconds))
            lines.append(clip.lastPathComponent)
        }
        lines.append("#EXT-X-ENDLIST")
        let content = lines.joined(separator: "\n") + "\n"

        let url = dir.appendingPathComponent(playlistName)
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == content { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }
}
