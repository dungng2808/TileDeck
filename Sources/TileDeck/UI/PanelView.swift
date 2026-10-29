import SwiftUI

struct PanelView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case display, hardware, shortcuts, menuBar, fans, sound

        var id: String { rawValue }

        var title: String {
            switch self {
            case .display: "Màn hình"
            case .hardware: "Pin"
            case .shortcuts: "Phím tắt"
            case .menuBar: "Menu bar"
            case .fans: "Quạt"
            case .sound: "Âm thanh"
            }
        }

        var icon: String {
            switch self {
            case .display: "display"
            case .hardware: "battery.75percent"
            case .shortcuts: "keyboard"
            case .menuBar: "menubar.rectangle"
            case .fans: "fan"
            case .sound: "speaker.wave.2"
            }
        }
    }

    @AppStorage("panelTab") private var tab: Tab = .display
    @ObservedObject private var battery = BatteryMonitor.shared
    @State private var showsDonate = false

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    var body: some View {
        VStack(spacing: 12) {
            header
            if showsDonate {
                DonateView { showsDonate = false }
            } else {
                tabBar
                content
            }
            footer
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { battery.observe("panel") }
        .onDisappear {
            battery.stopObserving("panel")
            showsDonate = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
            Text("TileDeck").font(.system(size: 14, weight: .bold))
            Text("v\(version)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
            Spacer()
            if battery.snapshot.onAC {
                Pill(icon: "powerplug.fill", text: "Đã cắm điện", tint: .orange)
            } else {
                Pill(icon: "battery.75percent", text: "Pin \(battery.snapshot.percent)%", tint: .green)
            }
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Thoát TileDeck")
        }
    }

    /// Six tabs fit one row as icon-over-label buttons, like a macOS toolbar.
    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(Tab.allCases) { item in
                Button {
                    tab = item
                } label: {
                    Label(item.title, systemImage: item.icon)
                        .labelStyle(TabLabelStyle())
                        .font(.system(size: 9.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(tab == item ? Color.white : Color.primary.opacity(0.75))
                        .background(tab == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .display:
            DisplayTab()
        case .hardware:
            BatteryTab()
        case .shortcuts:
            ShortcutsTab()
        case .menuBar:
            MenuBarTab()
        case .fans:
            FansTab()
        case .sound:
            SoundTab()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateChecker.repository)")!)
            } label: {
                Label("Mã nguồn mở", systemImage: "checkmark.seal.fill")
                    .symbolRenderingMode(.multicolor)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .help("Mở trang GitHub của TileDeck")
            Button {
                showsDonate.toggle()
            } label: {
                Label("Ủng hộ", systemImage: showsDonate ? "heart.fill" : "heart")
            }
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.pink)
            .help("Ủng hộ TileDeck qua VietQR")
            Spacer()
            Button {
                PermissionsWindow.shared.show()
            } label: {
                Image(systemName: "lock.shield")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Quyền truy cập")
            UpdateButton()
            Button("Thoát") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
        .onAppear { UpdateChecker.shared.checkIfDue() }
    }
}

private struct UpdateButton: View {
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        switch checker.state {
        case .available(let version, _):
            Button("Tải bản \(version)") { checker.openDownload() }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Đang kiểm tra…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        default:
            Button(label) { checker.check() }
                .controlSize(.small)
                .help("Phiên bản hiện tại: \(checker.currentVersion)")
        }
    }

    private var label: String {
        switch checker.state {
        case .upToDate: "Đã mới nhất ✓"
        case .noReleases: "Chưa có bản phát hành"
        case .failed: "Lỗi mạng · thử lại"
        default: "Kiểm tra cập nhật"
        }
    }
}

private struct TabLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon.font(.system(size: 13))
            configuration.title
        }
    }
}
