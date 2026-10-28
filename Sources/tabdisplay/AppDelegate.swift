import AppKit
import ApplicationServices

/// Menu bar UI: shows status, starts/stops the session, and points the user at fixes.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let session = DisplaySession()
    private let adb = AdbBridge(ports: [DisplaySession.httpPort, DisplaySession.wsPort])
    private var statusItem: NSStatusItem!
    private var adbStatus: AdbBridge.Status = .noDevice
    private var viewers = 0
    private var lastError: String?
    private var starting = false

    private let helpURL = URL(string: "https://github.com/seppam/TabDisplay#readme")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "ipad.landscape", accessibilityDescription: "TabDisplay")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        session.onViewersChanged = { [weak self] n in self?.viewers = n; self?.refreshIcon() }
        session.onFailure = { [weak self] msg in self?.fail(msg) }
        adb.onStatus = { [weak self] status in self?.adbStatus = status }
        adb.start()

        // Ask once up front; without it video still works, touches just do nothing.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        startSession()
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop()
    }

    // MARK: - Session

    private func startSession() {
        guard !session.isRunning, !starting else { return }
        starting = true
        lastError = nil
        Task { @MainActor in
            do { try await session.start() } catch { fail(error.localizedDescription) }
            starting = false
            refreshIcon()
        }
    }

    private func fail(_ message: String) {
        print("error: \(message)")
        lastError = message
        session.stop()
        refreshIcon()
    }

    private func refreshIcon() {
        statusItem.button?.appearsDisabled = !session.isRunning
    }

    // MARK: - Menu (rebuilt every time it opens, so it is always current)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let state: String
        if session.isRunning {
            state = viewers == 0 ? "Running — waiting for tablet" : "Running — \(viewers) viewer\(viewers == 1 ? "" : "s")"
        } else {
            state = starting ? "Starting…" : "Stopped"
        }
        menu.addItem(info("TabDisplay: \(state)"))

        switch adbStatus {
        case .notInstalled:
            menu.addItem(info("adb not found — install with: brew install android-platform-tools"))
        case .noDevice:
            menu.addItem(info("No tablet — connect USB (or Wi-Fi) with debugging allowed"))
        case .connected(let devices):
            for d in devices { menu.addItem(info("Tablet: \(d.model) (\(d.isWireless ? "Wi-Fi" : "USB"))")) }
            menu.addItem(info("On the tablet, open Chrome: http://localhost:\(DisplaySession.httpPort)"))
        }
        if let lastError { menu.addItem(info("⚠︎ \(lastError)")) }

        menu.addItem(.separator())
        if session.isRunning {
            menu.addItem(action("Stop", #selector(stop)))
        } else {
            menu.addItem(action("Start", #selector(start)))
        }
        menu.addItem(action("Copy Tablet URL", #selector(copyURL)))
        menu.addItem(action("Arrange Displays…", #selector(openDisplays)))
        if !AXIsProcessTrusted() {
            menu.addItem(action("⚠︎ Allow Touch Input (Accessibility)…", #selector(openAccessibility)))
        }
        menu.addItem(.separator())
        menu.addItem(action("Help…", #selector(openHelp)))
        menu.addItem(action("Quit TabDisplay", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    @objc private func start() { startSession() }
    @objc private func stop() { session.stop(); lastError = nil; refreshIcon() }

    @objc private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://localhost:\(DisplaySession.httpPort)", forType: .string)
    }

    @objc private func openDisplays() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension")!)
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openHelp() { NSWorkspace.shared.open(helpURL) }
}
