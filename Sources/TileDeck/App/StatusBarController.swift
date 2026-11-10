import AppKit
import Combine
import SwiftUI

/// The menu bar icon. The panel's view hierarchy is built when it opens and
/// released when it closes, so nothing UI-related stays in memory while idle.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var normalIcon: NSImage?
    private var recordingWatch: AnyCancellable?
    private var recordingClock: Timer?

    override init() {
        super.init()
        popover.behavior = .transient
        popover.delegate = self

        guard let button = item.button else { return }
        let image = NSImage(systemSymbolName: "command", accessibilityDescription: "TileDeck")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        image?.isTemplate = true
        button.image = image
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        normalIcon = image
        recordingWatch = ScreenRecordTool.shared.$phase.sink { [weak self] phase in self?.showRecording(phase) }
    }

    /// While recording, the menu bar icon turns into a red timer that stops it when clicked.
    private func showRecording(_ phase: ScreenRecordTool.Phase) {
        recordingClock?.invalidate()
        recordingClock = nil
        guard let button = item.button else { return }
        guard case .recording(let since) = phase else {
            button.image = normalIcon
            button.title = ""
            button.imagePosition = .imageOnly
            item.length = NSStatusItem.squareLength
            return
        }
        item.length = NSStatusItem.variableLength
        let symbol = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Đang quay màn hình")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold).applying(.init(hierarchicalColor: .systemRed)))
        symbol?.isTemplate = false
        button.image = symbol
        button.imagePosition = .imageLeading
        let update = { [weak button] in
            button?.title = " " + ScreenshotGeometry.clock(Date().timeIntervalSince(since))
        }
        update()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in update() }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        recordingClock = timer
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if case .recording = ScreenRecordTool.shared.phase {
            ScreenRecordTool.shared.stop()
            return
        }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePanel(from: sender)
        }
    }

    private func togglePanel(from button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        let host = NSHostingController(rootView: PanelView())
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Thoát TileDeck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
