import ApplicationServices
import CoreGraphics
import Foundation

/// Turns tablet touches into Mac mouse events on the virtual display.
/// Needs Accessibility permission for whichever app launched this process.
final class InputInjector {
    private let displayID: CGDirectDisplayID
    private var downButton: CGMouseButton?

    init(displayID: CGDirectDisplayID) { self.displayID = displayID }

    /// Messages: {"t":"down"|"move"|"up","x":0..1,"y":0..1,"b":"left"|"right"},
    /// {"t":"scroll","dx":px,"dy":px}, {"t":"dock"}
    func handle(_ msg: [String: Any]) {
        guard let type = msg["t"] as? String else { return }
        switch type {
        case "scroll":
            let dx = Int32((msg["dx"] as? Double ?? 0).rounded())
            let dy = Int32((msg["dy"] as? Double ?? 0).rounded())
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?.post(tap: .cghidEventTap)
            return
        case "dock":
            revealDock()
            return
        default: break
        }
        guard let x = msg["x"] as? Double, let y = msg["y"] as? Double else { return }
        let point = globalPoint(x: x, y: y)
        let button: CGMouseButton = msg["b"] as? String == "right" ? .right : .left

        let eventType: CGEventType
        switch type {
        case "down":
            eventType = button == .right ? .rightMouseDown : .leftMouseDown
            downButton = button
        case "up":
            eventType = button == .right ? .rightMouseUp : .leftMouseUp
            downButton = nil
        case "move":
            switch downButton {
            case .left: eventType = .leftMouseDragged
            case .right: eventType = .rightMouseDragged
            default: eventType = .mouseMoved
            }
        default: return
        }
        post(eventType, at: point, button: downButton ?? button)
    }

    /// An auto-hidden Dock appears when the cursor rests against the bottom edge of a
    /// display. One event is not enough, so nudge it there a few times.
    private func revealDock() {
        let edge = globalPoint(x: 0.5, y: 1)
        for i in 0..<6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60 * i)) {
                self.post(.mouseMoved, at: CGPoint(x: edge.x, y: edge.y - 1), button: .left)
            }
        }
    }

    /// The virtual display's place in the global desktop, in points. Read every time,
    /// because rotating or rearranging displays moves it.
    private func globalPoint(x: Double, y: Double) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        return CGPoint(x: b.minX + x * b.width, y: b.minY + y * b.height)
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }
}
