import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only: no Dock icon, no ⌘Tab entry (LSUIElement covers the .app bundle,
    // this covers `swift run`).
    app.setActivationPolicy(.accessory)
    app.run()
}
