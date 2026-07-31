import Foundation

/// Reads the duration of an MPEG-TS segment from its PCR timestamps.
/// AVFoundation cannot open bare `.ts` files (they only play inside an HLS
/// playlist, and playlist EXTINF values must come from somewhere), so the
/// duration is computed directly: first PCR near the start of the file, last
/// PCR near the end, difference on the 27 MHz PCR clock.
enum TSDuration {
    private static let packetSize = 188
    private static let syncByte: UInt8 = 0x47
    /// 4 MiB ≈ 2 s of stream at the recorder's 16 Mbps — plenty of packets to
    /// find a PCR (the muxer emits one at least every 100 ms).
    private static let windowBytes = 4 * 1024 * 1024

    static func seconds(of url: URL) -> Double? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > UInt64(packetSize) else { return nil }

        guard let head = read(handle, from: 0, count: min(Int(size), windowBytes)),
              let first = firstPCR(in: head, fromStart: true) else { return nil }

        let tailStart = size > UInt64(windowBytes) ? size - UInt64(windowBytes) : 0
        guard let tail = read(handle, from: tailStart, count: min(Int(size), windowBytes)),
              let last = firstPCR(in: tail, fromStart: false) else { return nil }

        // A wrapped or discontinuous PCR (last < first) means the value can't be
        // trusted; report unknown rather than a bogus duration.
        guard last > first else { return nil }
        let seconds = Double(last - first) / 27_000_000
        guard seconds < 24 * 3600 else { return nil }
        return seconds
    }

    private static func read(_ handle: FileHandle, from offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }

    /// Scans packets for the first (or last) PCR in `data`. Packet alignment is
    /// recovered by requiring three consecutive sync bytes — a card-pull can
    /// truncate the file mid-packet, so blind 188-stride from offset 0 of a tail
    /// window would misalign.
    private static func firstPCR(in data: Data, fromStart: Bool) -> UInt64? {
        let bytes = [UInt8](data)
        guard bytes.count >= packetSize * 3 else { return nil }
        var base: Int? = nil
        for i in 0..<packetSize {
            if bytes[i] == syncByte, bytes[i + packetSize] == syncByte, bytes[i + 2 * packetSize] == syncByte {
                base = i
                break
            }
        }
        guard let start = base else { return nil }

        var offsets = stride(from: start, to: bytes.count - packetSize + 1, by: packetSize).map { $0 }
        if !fromStart { offsets.reverse() }
        for o in offsets {
            guard bytes[o] == syncByte else { continue }
            // adaptation_field_control (header byte 3, bits 5-4) must include
            // an adaptation field (0b10 or 0b11) for a PCR to be present.
            guard bytes[o + 3] & 0x20 != 0 else { continue }
            let adaptationLength = Int(bytes[o + 4])
            guard adaptationLength >= 7, o + 5 + 6 < bytes.count else { continue }
            guard bytes[o + 5] & 0x10 != 0 else { continue } // PCR_flag
            let b = Array(bytes[(o + 6)...(o + 11)])
            let pcrBase = (UInt64(b[0]) << 25) | (UInt64(b[1]) << 17) | (UInt64(b[2]) << 9)
                | (UInt64(b[3]) << 1) | (UInt64(b[4]) >> 7)
            let pcrExt = (UInt64(b[4] & 0x01) << 8) | UInt64(b[5])
            return pcrBase * 300 + pcrExt
        }
        return nil
    }
}
