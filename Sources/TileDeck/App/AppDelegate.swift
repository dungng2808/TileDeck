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
        MouseChord.shared.activateIfNeeded()
        MenuBarManager.shared.activateIfNeeded()
        FanController.shared.activateIfNeeded()
        AppVolume.shared.activateIfNeeded()
        PermissionsWindow.shared.showOnFirstLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the user with a disabled screen, dimmed gamma, a sleep assertion or a paused app.
        DisplayController.shared.restoreAll()
        Caffeinate.shared.stop()
        ProcessFreezer.shared.thawAll()
        WindowSwitcher.shared.restoreNativeSwitcher()
        FanController.shared.restoreAll()
        AppVolume.shared.stopAll()
    }
}
