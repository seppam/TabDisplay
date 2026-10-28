import CGVirtualDisplayPrivate
import CoreGraphics
import Foundation

/// A fake monitor that macOS treats as real. It exists only while this object is alive.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    private let hiDPI: Bool
    private let refreshRate: Double
    var displayID: CGDirectDisplayID { display.displayID }

    /// `width`/`height` are the logical (point) size; with `hiDPI` the backing pixels are 2x.
    init?(name: String, width: UInt32, height: UInt32, hiDPI: Bool, refreshRate: Double = 60) {
        let scale: UInt32 = hiDPI ? 2 : 1
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = name
        // Square max so the same display can later switch between landscape and portrait.
        let longSide = max(width, height) * scale
        descriptor.maxPixelsWide = longSide
        descriptor.maxPixelsHigh = longSide
        // Tab S8: 11" 16:10 panel, roughly 237 x 148 mm. Used by macOS to pick UI scale.
        descriptor.sizeInMillimeters = CGSize(width: 237, height: 148)
        descriptor.vendorID = 0x5354  // arbitrary, just has to be stable
        descriptor.productID = 0x5338
        descriptor.serialNum = 1
        descriptor.terminationHandler = { _, _ in
            print("virtual display terminated by system")
        }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        self.display = display
        self.hiDPI = hiDPI
        self.refreshRate = refreshRate
        guard setSize(width: width, height: height) else { return nil }
    }

    /// Switches the display to a new logical size, e.g. 1280x800 -> 800x1280 for portrait.
    @discardableResult
    func setSize(width: UInt32, height: UInt32) -> Bool {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        // In HiDPI mode the mode is given in points; macOS renders at 2x behind it.
        settings.modes = [CGVirtualDisplayMode(width: width, height: height, refreshRate: refreshRate)]
        return display.apply(settings)
    }
}
