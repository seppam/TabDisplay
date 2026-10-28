import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

// Menu bar only: no Dock icon, no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
