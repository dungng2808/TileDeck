import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        BrightnessKeys.shared.activateIfNeeded()
        BatteryAlerts.shared.activateIfNeeded()
        SleepGuard.shared.activateIfNeeded()
        Calibration.shared.activateIfNeeded()
        ProcessFreezer.shared.thawAll()
        WindowSwitcher.shared.activateIfNeeded()
        WindowTiler.shared.activateIfNeeded()
        ClipboardStore.shared.activateIfNeeded()
        ScreenshotTool.shared.activateIfNeeded()
        ScreenRecordTool.shared.activateIfNeeded()
        MouseChord.shared.activateIfNeeded()
        MenuBarManager.shared.activateIfNeeded()
        FanController.shared.activateIfNeeded()
        ChargeLimiter.shared.activateIfNeeded()
        AppVolume.shared.activateIfNeeded()
        PermissionsWindow.shared.showOnFirstLaunch()
    }

    /// A recording in progress gets saved before the app goes away.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard case .recording = ScreenRecordTool.shared.phase else { return .terminateNow }
        ScreenRecordTool.shared.stopForQuit { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the user with a disabled screen, dimmed gamma, a sleep assertion or a paused app.
        DisplayController.shared.restoreAll()
        Caffeinate.shared.stop()
        ProcessFreezer.shared.thawAll()
        WindowSwitcher.shared.restoreNativeSwitcher()
        FanController.shared.restoreAll()
        ChargeLimiter.shared.restoreOnQuit()
        AppVolume.shared.stopAll()
    }
}
