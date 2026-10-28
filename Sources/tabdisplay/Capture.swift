import CoreMedia
import ScreenCaptureKit

/// Grabs frames from one display. ScreenCaptureKit only delivers a frame when pixels change.
final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "capture", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Last frame, kept so a keyframe can be produced for a new viewer while the screen is static.
    private(set) var lastFrame: CVPixelBuffer?
    private var stream: SCStream?
    private var config: SCStreamConfiguration?

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        // A freshly created virtual display can take a moment to show up in the shareable list.
        var display: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            display = content.displays.first { $0.displayID == displayID }
            if display != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let display else { throw NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "virtual display not found by ScreenCaptureKit"]) }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // what the H.264 encoder wants, no conversion
        config.showsCursor = true
        config.queueDepth = 4

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.config = config
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        lastFrame = nil
    }

    /// Changes the output size without restarting the stream (used when the display rotates).
    func resize(width: Int, height: Int) async throws {
        guard let stream, let config else { return }
        config.width = width
        config.height = height
        try await stream.updateConfiguration(config)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        lastFrame = pixelBuffer
        onFrame?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("capture stopped: \(error.localizedDescription)")
    }
}
