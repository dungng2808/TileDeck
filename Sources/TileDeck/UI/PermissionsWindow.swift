import AppKit
import SwiftUI
import UserNotifications

/// A small window listing every permission TileDeck can use, what it is for,
/// and a button to grant it. Shown on first launch and from the panel footer.
@MainActor
final class PermissionsWindow: NSObject, NSWindowDelegate {
    static let shared = PermissionsWindow()
    private static let shownKey = "permissionsGuideShown"

    private var window: NSWindow?

    func showOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.shownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Quyền truy cập · TileDeck"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: PermissionsView { [weak self] in self?.window?.close() })
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }

    /// Released on close: nothing of it stays in memory.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

@MainActor
private final class PermissionStatus: ObservableObject {
    @Published var accessibility = false
    @Published var screenRecording = false
    @Published var notifications: Bool?
    @Published var audioCapture: AppVolume.CapturePermission = .notDetermined
    @Published var fanHelper: FanController.HelperState = .notInstalled

    private var timer: Timer?

    /// Settings changes happen in another app, so re-read while the window is open (cheap local checks).
    func start() {
        refresh()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        screenRecording = CGPreflightScreenCaptureAccess()
        audioCapture = AppVolume.capturePermission
        FanController.shared.refreshHelperState()
        fanHelper = FanController.shared.helperState
        // `swift run` has no bundle, and UNUserNotificationCenter needs one.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { MainActor.assumeIsolated { self.notifications = granted } }
        }
    }
}

private struct PermissionsView: View {
    let close: () -> Void
    @StateObject private var status = PermissionStatus()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chào mừng đến với TileDeck").font(.system(size: 16, weight: .bold))
                    Text("Mỗi quyền chỉ cần cho tính năng dùng đến nó. Bỏ qua quyền nào cũng được, cấp sau cũng được.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 8) {
                PermissionRow(icon: "hand.raised.fill", title: "Trợ năng (Accessibility)",
                              purpose: "F1/F2 màn ngoài, ⌘Tab, chia cửa sổ, dán clipboard, cử chỉ chuột, sắp xếp thanh menu",
                              granted: status.accessibility) {
                    AXWindow.requestTrust()
                    Self.openSettings("Privacy_Accessibility")
                }
                PermissionRow(icon: "rectangle.dashed.badge.record", title: "Ghi màn hình",
                              purpose: "Ảnh xem trước cửa sổ trong ⌘Tab",
                              granted: status.screenRecording) {
                    if !CGRequestScreenCaptureAccess() { Self.openSettings("Privacy_ScreenCapture") }
                }
                PermissionRow(icon: "waveform", title: "Ghi âm thanh hệ thống",
                              purpose: "Âm lượng từng app",
                              granted: status.audioCapture == .granted) {
                    // Once refused, macOS won't ask again: only System Settings can change it.
                    if status.audioCapture == .denied {
                        Self.openSettings("Privacy_AudioCapture")
                    } else {
                        AppVolume.requestCapturePermission()
                    }
                    status.refresh()
                }
                PermissionRow(icon: "bell.badge.fill", title: "Thông báo",
                              purpose: "Cảnh báo pin nóng, pin yếu và các bước hiệu chuẩn pin",
                              granted: status.notifications) {
                    if status.notifications == false {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    } else {
                        Notifier.shared.requestPermission()
                    }
                }
                PermissionRow(icon: "fan.fill", title: "Chạy nền (trình trợ giúp quạt)",
                              purpose: "Điều khiển quạt. Cài một lần, rồi bật TileDeck trong Mục đăng nhập.",
                              granted: status.fanHelper == .ready) {
                    status.fanHelper == .needsApproval ? FanController.shared.openApprovalSettings() : FanController.shared.installHelper()
                }
            }

            HStack {
                Text("Mở lại bảng này bằng nút 🔒 ở cuối bảng TileDeck.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Xong", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 480)
        .onAppear { status.start() }
        .onDisappear { status.stop() }
    }

    private static func openSettings(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let purpose: String
    /// nil when macOS offers no way to check it in advance.
    let granted: Bool?
    let grant: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(.blue)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(purpose).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted == true {
                Label("Đã cấp", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Button(granted == nil ? "Mở cài đặt" : "Cấp quyền", action: grant)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }
}
