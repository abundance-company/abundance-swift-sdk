import Foundation

/// The `/v1/preview` wire: an 8-byte stream header, then repeating frames of
/// `[uint32 big-endian length][H.264 NAL unit]` — Annex-B start codes
/// stripped, SPS/PPS re-sent before every IDR, no timestamps (display
/// immediately). Any gap the device introduces (backpressure drop, pipeline
/// restart) resumes at SPS/PPS+IDR, so keep parsing after a stall.
public enum PreviewWireFormat {
    public static let magic: [UInt8] = [0x41, 0x42, 0x50, 0x56] // "ABPV"
    public static let version: UInt8 = 1
    public static let codecH264: UInt8 = 1
    public static let headerLength = 8 // magic + version + codec + 2 reserved

    /// A worst-case IDR at this bitrate/GOP is well under 1 MiB; anything
    /// larger means the stream is not what we think it is.
    public static let maxNALUnitSize = 4 << 20
}

/// Preview stream failures. Protocol violations mean reconnecting cannot
/// help; the rest are transport conditions a reconnect loop owns.
public enum PreviewStreamError: Error, Sendable, Equatable {
    case badStatus(Int)
    case badMagic
    case unsupportedVersion(UInt8)
    case unsupportedCodec(UInt8)
    case zeroLengthFrame
    case oversizeFrame(Int)
    /// EOF mid-header or mid-frame.
    case truncatedStream
    case network(String)

    /// True when the failure is a wire-contract violation — do not retry.
    public var isProtocolViolation: Bool {
        switch self {
        case .badMagic, .unsupportedVersion, .unsupportedCodec, .zeroLengthFrame, .oversizeFrame:
            true
        case .badStatus, .truncatedStream, .network:
            false
        }
    }
}

/// Pull-parser for the preview wire over any byte stream — generic so
/// production plugs in `URLSession.AsyncBytes` and tests plug in synthetic
/// sequences.
struct NALUnitReader<Bytes: AsyncSequence> where Bytes.Element == UInt8 {
    private var iterator: Bytes.AsyncIterator

    init(_ bytes: Bytes) {
        iterator = bytes.makeAsyncIterator()
    }

    /// Validates the 8-byte stream header. Call once, first.
    mutating func readHeader() async throws {
        guard let header = try await read(count: PreviewWireFormat.headerLength) else {
            throw PreviewStreamError.truncatedStream
        }
        guard header.prefix(4).elementsEqual(PreviewWireFormat.magic) else {
            throw PreviewStreamError.badMagic
        }
        guard header[4] == PreviewWireFormat.version else {
            throw PreviewStreamError.unsupportedVersion(header[4])
        }
        guard header[5] == PreviewWireFormat.codecH264 else {
            throw PreviewStreamError.unsupportedCodec(header[5])
        }
    }

    /// The next NAL unit payload, or nil on a clean EOF at a frame boundary
    /// (device ended the stream). EOF anywhere else is `truncatedStream`.
    mutating func nextNALUnit() async throws -> Data? {
        guard let lengthBytes = try await read(count: 4, cleanEOFAllowed: true) else {
            return nil
        }
        let length = Int(lengthBytes[0]) << 24
            | Int(lengthBytes[1]) << 16
            | Int(lengthBytes[2]) << 8
            | Int(lengthBytes[3])
        guard length > 0 else { throw PreviewStreamError.zeroLengthFrame }
        guard length <= PreviewWireFormat.maxNALUnitSize else {
            throw PreviewStreamError.oversizeFrame(length)
        }
        guard let payload = try await read(count: length) else {
            throw PreviewStreamError.truncatedStream
        }
        return payload
    }

    /// Reads exactly `count` bytes. Nil only when EOF lands before the first
    /// byte AND `cleanEOFAllowed`; EOF mid-read always throws.
    private mutating func read(count: Int, cleanEOFAllowed: Bool = false) async throws -> Data? {
        var data = Data(capacity: count)
        while data.count < count {
            guard let byte = try await iterator.next() else {
                if data.isEmpty && cleanEOFAllowed { return nil }
                throw PreviewStreamError.truncatedStream
            }
            data.append(byte)
        }
        return data
    }
}
