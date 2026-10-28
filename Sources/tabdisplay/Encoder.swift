import CoreMedia
import Foundation
import VideoToolbox

/// Hardware H.264 encoder tuned for latency. Emits Annex B (start-code) frames, which is what
/// WebCodecs expects when no `description` is given.
final class H264Encoder {
    /// (annexB bytes, isKeyframe, timestamp in microseconds)
    var onFrame: ((Data, Bool, Int64) -> Void)?
    /// Called when the stream's codec string is known/changes, e.g. "avc1.640033".
    var onCodec: ((String) -> Void)?

    let width: Int, height: Int
    private let session: VTCompressionSession
    private var forceKeyframe = true
    private var codec: String?

    init(width: Int32, height: Int32, bitrate: Int, fps: Int) throws {
        self.width = Int(width)
        self.height = Int(height)
        // Low-latency rate control: no lookahead, frames come out as soon as they are encoded.
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: width, height: height, codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else {
            throw NSError(domain: "encoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate failed (\(status))"])
        }
        session = created

        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedHigh_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,  // no B-frames = no reorder delay
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 4,
        ]
        for (key, value) in props {
            let s = VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
            if s != noErr { print("encoder: property \(key) not applied (\(s))") }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func requestKeyframe() { forceKeyframe = true }

    /// Must be called from a single queue (the capture queue).
    func encode(_ pixelBuffer: CVPixelBuffer) {
        // Host clock instead of capture timestamps, so re-encoding the last frame stays monotonic.
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        var frameProps: CFDictionary?
        if forceKeyframe {
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKeyframe = false
        }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: frameProps, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.handle(sample)
        }
    }

    private func handle(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)

        var out = Data()
        let startCode: [UInt8] = [0, 0, 0, 1]
        var nalLengthSize: Int32 = 4

        // Keyframes carry SPS/PPS in-band so a decoder can start from any keyframe.
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLengthSize)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                         parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                      let ptr else { continue }
                if i == 0, size >= 4 {
                    // SPS bytes 1..3 = profile_idc, constraint flags, level_idc -> "avc1.PPCCLL"
                    let c = String(format: "avc1.%02x%02x%02x", ptr[1], ptr[2], ptr[3])
                    if c != codec { codec = c; onCodec?(c) }
                }
                out.append(contentsOf: startCode)
                out.append(ptr, count: size)
            }
        }

        // Encoder output is AVCC (length-prefixed NAL units); rewrite to start codes.
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let total = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: total)
        let copied = avcc.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: $0.baseAddress!) }
        guard copied == noErr else { return }

        let lenSize = Int(nalLengthSize)
        var offset = 0
        while offset + lenSize <= total {
            var nalLength = 0
            for i in 0..<lenSize { nalLength = (nalLength << 8) | Int(avcc[offset + i]) }
            offset += lenSize
            guard nalLength > 0, offset + nalLength <= total else { break }
            out.append(contentsOf: startCode)
            out.append(avcc[offset..<offset + nalLength])
            offset += nalLength
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        onFrame?(out, isKey, Int64(CMTimeGetSeconds(pts) * 1_000_000))
    }
}
