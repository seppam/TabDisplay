import AppKit
import CoreGraphics

/// One running "tablet as a monitor" session: virtual display -> capture -> encode -> server,
/// plus input coming back. Start/stop from the main thread.
final class DisplaySession {
    static let httpPort: UInt16 = 8080
    static let wsPort: UInt16 = 8081

    // Tab S8 panel is 2560x1600; HiDPI 1280x800 points gives crisp text at a usable size.
    private let longSide: UInt32 = 1280, shortSide: UInt32 = 800
    private let fps = 60
    private let bitrate = 20_000_000

    var onViewersChanged: ((Int) -> Void)?
    var onFailure: ((String) -> Void)?

    private var display: VirtualDisplay?
    private var server: StreamServer?
    private var capture: DisplayCapture?
    private var injector: InputInjector?
    /// Only touched on the capture queue.
    private var encoder: H264Encoder?
    private var isPortrait = false

    var isRunning: Bool { display != nil }

    @MainActor
    func start() async throws {
        guard display == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw Self.error("Screen Recording not allowed. Allow (or remove and re-add) TabDisplay in Privacy & Security, then reopen.")
        }

        guard let display = VirtualDisplay(name: "TabDisplay", width: longSide, height: shortSide, hiDPI: true) else {
            throw Self.error("macOS refused to create the virtual display.")
        }
        let html = try Self.viewerPage()
        let server = try StreamServer(httpPort: Self.httpPort, wsPort: Self.wsPort, html: html)
        let capture = DisplayCapture()
        let injector = InputInjector(displayID: display.displayID)
        let width = Int(longSide * 2), height = Int(shortSide * 2)
        encoder = try makeEncoder(server: server, width: width, height: height)

        // capture -> encode -> broadcast. Frames still in the old size right after a rotation are skipped.
        capture.onFrame = { [weak self] frame in
            guard let encoder = self?.encoder,
                  CVPixelBufferGetWidth(frame) == encoder.width, CVPixelBufferGetHeight(frame) == encoder.height
            else { return }
            encoder.encode(frame)
        }
        // A viewer joined or fell behind: send a keyframe now, even if the screen is not changing.
        server.onKeyframeNeeded = { [weak self, weak capture] in
            capture?.queue.async {
                guard let encoder = self?.encoder else { return }
                encoder.requestKeyframe()
                if let last = capture?.lastFrame { encoder.encode(last) }
            }
        }
        server.onInput = { [weak self] msg in
            DispatchQueue.main.async {
                if msg["t"] as? String == "orient" {
                    self?.setOrientation(portrait: msg["portrait"] as? Bool ?? false)
                } else {
                    self?.injector?.handle(msg)
                }
            }
        }
        server.onViewersChanged = { [weak self] n in DispatchQueue.main.async { self?.onViewersChanged?(n) } }
        server.onFailure = { [weak self] msg in DispatchQueue.main.async { self?.onFailure?(msg) } }

        self.display = display
        self.server = server
        self.capture = capture
        self.injector = injector
        isPortrait = false
        server.start()

        do {
            try await capture.start(displayID: display.displayID, width: width, height: height, fps: fps)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let capture = self.capture
        Task { await capture?.stop() }
        server?.stop()
        capture?.queue.async { [weak self] in self?.encoder = nil }
        server = nil
        self.capture = nil
        injector = nil
        display = nil  // releasing the CGVirtualDisplay removes the monitor
        onViewersChanged?(0)
    }

    /// A VideoToolbox session has a fixed size, so rotating means building a new encoder.
    private func makeEncoder(server: StreamServer, width: Int, height: Int) throws -> H264Encoder {
        let e = try H264Encoder(width: Int32(width), height: Int32(height), bitrate: bitrate, fps: fps)
        e.onCodec = { [weak server] in server?.setConfig(codec: $0, width: width, height: height) }
        e.onFrame = { [weak server] data, isKey, ts in server?.broadcast(data, isKey: isKey, timestamp: ts) }
        return e
    }

    private func setOrientation(portrait: Bool) {
        guard portrait != isPortrait, let display, let server, let capture else { return }
        let (w, h) = portrait ? (shortSide, longSide) : (longSide, shortSide)
        guard display.setSize(width: w, height: h) else {
            print("could not switch virtual display to \(w)x\(h)")
            return
        }
        isPortrait = portrait
        let pw = Int(w * 2), ph = Int(h * 2)
        print("orientation: \(portrait ? "portrait" : "landscape") \(pw)x\(ph)")
        capture.queue.async { [weak self] in
            guard let self else { return }
            do { self.encoder = try self.makeEncoder(server: server, width: pw, height: ph) } catch { print("encoder: \(error.localizedDescription)") }
        }
        Task {
            do { try await capture.resize(width: pw, height: ph) } catch { print("capture resize: \(error.localizedDescription)") }
        }
    }

    /// Inside TabDisplay.app the page sits in Contents/Resources; with `swift run` it is in the SwiftPM bundle.
    private static func viewerPage() throws -> Data {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html")
                ?? Bundle.module.url(forResource: "index", withExtension: "html") else {
            throw error("Viewer page is missing from the app bundle.")
        }
        return try Data(contentsOf: url)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "TabDisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// Thread confinement is manual: session state lives on the main thread, `encoder` only on the
// capture queue, and the capture object hands frames out on its own queue.
extension DisplaySession: @unchecked Sendable {}
extension DisplayCapture: @unchecked Sendable {}
