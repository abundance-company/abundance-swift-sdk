import Foundation
import CoreMedia

/// Turns wire NAL units into displayable `CMSampleBuffer`s: caches SPS/PPS,
/// builds the `CMVideoFormatDescription`, converts slices to AVCC
/// (4-byte-length-prefixed) block buffers, and marks every sample
/// display-immediately (the wire carries no timestamps by design).
///
/// Single-consumer: confine to one actor. Not Sendable on purpose.
public final class H264SampleBufferAssembler {
    public enum ConsumeError: Error, Sendable, Equatable {
        case emptyNALUnit
        /// A slice arrived with no SPS/PPS cached — contract violation
        /// mid-stream, or a join before the first parameter sets.
        case sliceBeforeParameterSets
        case formatDescription(OSStatus)
        case blockBuffer(OSStatus)
        case sampleBuffer(OSStatus)
    }

    public struct Frame {
        public let sampleBuffer: CMSampleBuffer
        public let isIDR: Bool
        /// A new format description was installed — flush the renderer before
        /// enqueueing this frame.
        public let formatChanged: Bool
    }

    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?
    private var formatDirty = false
    // Trigger: fresh stream, resetToNextIDR(), or decoder flush.
    // Why: P slices without their reference frames macroblock-smear; the
    // device guarantees every gap resumes at SPS/PPS+IDR within one GOP.
    // Outcome: drop non-IDR slices until a keyframe restarts decode cleanly.
    private var waitingForIDR = true

    public init() {}

    /// Feed one wire NAL unit. Returns a displayable frame, or nil (parameter
    /// set cached / SEI dropped / awaiting keyframe).
    public func consume(_ nal: Data) throws -> Frame? {
        guard let first = nal.first else { throw ConsumeError.emptyNALUnit }
        switch first & 0x1F {
        case 7: // SPS
            if sps != nal {
                sps = nal
                formatDirty = true
            }
            return nil
        case 8: // PPS
            if pps != nal {
                pps = nal
                formatDirty = true
            }
            return nil
        case 5:
            return try makeFrame(nal, isIDR: true)
        case 1:
            return try makeFrame(nal, isIDR: false)
        default:
            // SEI (6), AUD (9), filler — nothing the display path needs.
            return nil
        }
    }

    /// After a decode failure / renderer flush: drop non-IDR slices until the
    /// next keyframe (which the device precedes with SPS/PPS).
    public func resetToNextIDR() {
        waitingForIDR = true
    }

    private func makeFrame(_ nal: Data, isIDR: Bool) throws -> Frame? {
        if waitingForIDR && !isIDR {
            return nil
        }
        var formatChanged = false
        if formatDescription == nil || formatDirty {
            guard let sps, let pps else { throw ConsumeError.sliceBeforeParameterSets }
            formatDescription = try makeFormatDescription(sps: sps, pps: pps)
            formatDirty = false
            formatChanged = true
        }
        guard let formatDescription else { throw ConsumeError.sliceBeforeParameterSets }

        let sampleBuffer = try makeSampleBuffer(nal, formatDescription: formatDescription)
        if isIDR {
            waitingForIDR = false
        }
        return Frame(sampleBuffer: sampleBuffer, isIDR: isIDR, formatChanged: formatChanged)
    }

    private func makeFormatDescription(sps: Data, pps: Data) throws -> CMVideoFormatDescription {
        try sps.withUnsafeBytes { (spsRaw: UnsafeRawBufferPointer) in
            try pps.withUnsafeBytes { (ppsRaw: UnsafeRawBufferPointer) in
                let spsPtr = spsRaw.bindMemory(to: UInt8.self).baseAddress!
                let ppsPtr = ppsRaw.bindMemory(to: UInt8.self).baseAddress!
                let pointers: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
                let sizes: [Int] = [sps.count, pps.count]
                var fd: CMFormatDescription?
                let status = pointers.withUnsafeBufferPointer { pp in
                    sizes.withUnsafeBufferPointer { sp in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pp.baseAddress!,
                            parameterSetSizes: sp.baseAddress!,
                            nalUnitHeaderLength: 4, // AVCC 4-byte lengths, matching makeSampleBuffer
                            formatDescriptionOut: &fd
                        )
                    }
                }
                guard status == noErr, let fd else {
                    throw ConsumeError.formatDescription(status)
                }
                return fd
            }
        }
    }

    private func makeSampleBuffer(
        _ nal: Data,
        formatDescription: CMVideoFormatDescription
    ) throws -> CMSampleBuffer {
        let totalLength = 4 + nal.count

        var blockOut: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLength,
            flags: 0,
            blockBufferOut: &blockOut
        )
        guard status == kCMBlockBufferNoErr, let block = blockOut else {
            throw ConsumeError.blockBuffer(status)
        }
        status = CMBlockBufferAssureBlockMemory(block)
        guard status == kCMBlockBufferNoErr else { throw ConsumeError.blockBuffer(status) }

        var lengthBE = UInt32(nal.count).bigEndian
        status = withUnsafeBytes(of: &lengthBE) {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: 4
            )
        }
        guard status == kCMBlockBufferNoErr else { throw ConsumeError.blockBuffer(status) }
        status = nal.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 4,
                dataLength: nal.count
            )
        }
        guard status == kCMBlockBufferNoErr else { throw ConsumeError.blockBuffer(status) }

        var sampleSize = totalLength
        var sampleOut: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleOut
        )
        guard status == noErr, let sample = sampleOut else {
            throw ConsumeError.sampleBuffer(status)
        }

        // No wire timestamps: render on arrival.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true
        ) as? [CFMutableDictionary],
            let dict = attachments.first {
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }
}
