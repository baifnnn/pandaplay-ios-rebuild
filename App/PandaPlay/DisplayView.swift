import AVFoundation
import CoreMedia
import UIKit

/// Shows the controller's H.264 frames.
///
/// Nothing here decodes. The system does that, which is why the accessory can claim
/// `no_audio` and no I-frame handling in its capability profile: it forwards access units and
/// lets VideoToolbox do the work.
final class DisplayView: UIView {

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // Safe: `layerClass` above makes the backing layer this exact type.
        layer as! AVSampleBufferDisplayLayer
    }

    /// The decoder configuration in force. Rebuilt whenever the controller sends new
    /// parameter sets, because a stale format description rejects every following frame.
    private var formatDescription: CMVideoFormatDescription?
    private var configuredSize = CGSize.zero

    /// The controller always length-prefixes with four bytes; the sample buffer has to agree.
    private let nalLengthSize: Int32 = 4

    private(set) var droppedFrames = 0
    private(set) var displayedFrames = 0
    private(set) var reconfigureCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
    }

    var surfaceSize: CGSize { configuredSize }

    /// Builds a format description from SPS/PPS. Returns false when the parameter sets do not
    /// form a usable description, in which case the caller asks for a keyframe instead of
    /// silently dropping every following picture.
    @discardableResult
    func configure(sps: [Data], pps: [Data]) -> Bool {
        guard !sps.isEmpty, !pps.isEmpty else { return false }
        let sets = sps + pps
        guard sets.allSatisfy({ !$0.isEmpty }) else { return false }

        // The call wants parallel arrays of pointers and lengths that outlive it, so the
        // buffers are allocated by hand. Nesting `withUnsafeBufferPointer` over a variadic
        // number of sets would overlap exclusive access.
        let pointers = UnsafeMutablePointer<UnsafePointer<UInt8>>.allocate(capacity: sets.count)
        let sizes = UnsafeMutablePointer<Int>.allocate(capacity: sets.count)
        let copies = sets.map { UnsafeMutablePointer<UInt8>.allocate(capacity: $0.count) }
        defer {
            for (index, buffer) in copies.enumerated() {
                buffer.deallocate()
                _ = index
            }
            pointers.deallocate()
            sizes.deallocate()
        }

        for (index, set) in sets.enumerated() {
            set.copyBytes(to: copies[index], count: set.count)
            pointers[index] = UnsafePointer(copies[index])
            sizes[index] = set.count
        }

        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: nalLengthSize,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else { return false }

        formatDescription = description
        configuredSize = CGSize(
            width: CGFloat(CMVideoFormatDescriptionGetDimensions(description).width),
            height: CGFloat(CMVideoFormatDescriptionGetDimensions(description).height)
        )
        reconfigureCount += 1
        // A new description invalidates whatever is queued; those frames are undecodable.
        displayLayer.flush()
        return true
    }

    /// Hands one access unit to the decoder.
    func enqueue(_ accessUnit: Data, presentationTime: CMTime) {
        guard let formatDescription else {
            droppedFrames += 1
            return
        }
        guard let sampleBuffer = makeSampleBuffer(accessUnit, formatDescription, presentationTime) else {
            droppedFrames += 1
            return
        }
        if displayLayer.status == .failed {
            // The decoder latched a failure; the only way out is to drop the queue and wait
            // for fresh parameter sets, which the controller sends with the next keyframe.
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
        displayedFrames += 1
    }

    private func makeSampleBuffer(
        _ accessUnit: Data,
        _ formatDescription: CMVideoFormatDescription,
        _ presentationTime: CMTime
    ) -> CMSampleBuffer? {
        // The block buffer must own its memory: the sample buffer outlives this call, so a
        // non-copying reference to `accessUnit`'s storage could dangle by display time.
        let length = accessUnit.count
        guard length > 0 else { return nil }
        var blockBuffer: CMBlockBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard created == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copied = accessUnit.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        let made = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard made == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0,
           let first = CFArrayGetValueAtIndex(attachments, 0) {
            let dictionary = unsafeBitCast(first, to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }

    func reset() {
        displayLayer.flush()
        formatDescription = nil
        configuredSize = .zero
    }
}
