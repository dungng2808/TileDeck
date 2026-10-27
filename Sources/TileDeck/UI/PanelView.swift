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

    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

    var body: some View {
        VStack(spacing: 12) {
            header
            tabBar
            content
            footer
        }
        .padding(14)
        .frame(width: 400)
        .onAppear { battery.observe("panel") }
        .onDisappear { battery.stopObserving("panel") }
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
        case .fans, .sound:
            Card {
                Label("\(tab.title) — đang làm", systemImage: "hammer")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
    }

    private var footer: some View {
        HStack {
            Label("Open Source • Miễn phí", systemImage: "checkmark.seal.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
            Spacer()
            Button("Kiểm tra cập nhật") {}
                .controlSize(.small)
                .disabled(true)
                .help("Sắp có")
            Button("Thoát") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
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
