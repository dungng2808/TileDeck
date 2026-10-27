import SwiftUI

struct ShortcutsTab: View {
    @ObservedObject private var switcher = WindowSwitcher.shared
    @ObservedObject private var tiler = WindowTiler.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var chord = MouseChord.shared
    @State private var trusted = AXWindow.isTrusted

    var body: some View {
        VStack(spacing: 10) {
            if !trusted && (switcher.isEnabled || tiler.isEnabled || clipboard.isEnabled || chord.isEnabled) {
                permissionNotice
            }
            switcherCard
            tilingCard
            clipboardCard
            chordCard
        }
        .onAppear { trusted = AXWindow.isTrusted }
    }

    private var permissionNotice: some View {
        Button {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } label: {
            Label("Cần quyền Trợ năng (Accessibility) để điều khiển cửa sổ — bấm để mở Cài đặt", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var switcherCard: some View {
        Card {
            FeatureHeader(
                icon: "rectangle.on.rectangle",
                title: "Chuyển đổi cửa sổ (Command + Tab)",
                subtitle: "Thay thế AltTab với live preview độc lập & chuẩn MRU",
                isOn: Binding(get: { switcher.isEnabled }, set: { switcher.setEnabled($0) }),
                tint: .blue
            )
            if switcher.isEnabled {
                ShortcutRow([("⌘ + Tab", "Chuyển tiếp"), ("⌘ + `", "Lùi lại"), ("W", "Đóng cửa sổ"), ("Q", "Thoát App")])
            }
            if switcher.isEnabled && !switcher.hasScreenRecording {
                Button {
                    switcher.requestScreenRecording()
                } label: {
                    Label("Cấp quyền Ghi màn hình để xem preview cửa sổ", systemImage: "rectangle.dashed.badge.record")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tilingCard: some View {
        Card {
            FeatureHeader(
                icon: "rectangle.split.2x1",
                title: "Chia cửa sổ & Đa màn hình (Rectangle)",
                subtitle: "Bố trí cửa sổ nhanh với độ trễ 0ms",
                isOn: Binding(get: { tiler.isEnabled }, set: { tiler.setEnabled($0) }),
                tint: .blue
            )
            if tiler.isEnabled {
                ShortcutRow([("⌃⌥←", "Nửa trái"), ("⌃⌥→", "Nửa phải"), ("⌃⌥↑", "Toàn màn hình"), ("⌃⌥↓", "Căn giữa"),
                             ("⌃⌥⌘→", "Sang màn phải"), ("⌃⌥⌘←", "Sang màn trái")])
            }
        }
    }

    private var clipboardCard: some View {
        Card {
            FeatureHeader(
                icon: "doc.on.clipboard",
                title: "Quản lý Clipboard (Thay thế Maccy)",
                subtitle: "Lịch sử sao chép thông minh, tìm kiếm & dán tức thì",
                isOn: Binding(get: { clipboard.isEnabled }, set: { clipboard.setEnabled($0) }),
                tint: .blue
            )
            if clipboard.isEnabled {
                ShortcutRow([("⌘⇧C", "Mở bảng HUD"), ("1..9", "Dán tức thì"), ("⌥P", "Ghim"), ("⌥⌫", "Xóa")])

                HStack(spacing: 6) {
                    Text("Giới hạn:").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    ForEach(ClipboardStore.limits, id: \.self) { limit in
                        Chip(title: "\(limit) mục", isSelected: clipboard.limit == limit) { clipboard.setLimit(limit) }
                    }
                    Spacer()
                    Text("\(clipboard.items.count) mục lưu").font(.system(size: 10)).foregroundStyle(.secondary)
                }

                HStack {
                    Label("Bỏ qua mật khẩu (1Password, Bitwarden, Keychain)", systemImage: "lock.shield.fill")
                        .labelStyle(TightLabelStyle(tint: .green))
                        .font(.system(size: 10.5))
                    Spacer()
                    Toggle("", isOn: Binding(get: { clipboard.skipConcealed }, set: { clipboard.setSkipConcealed($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }

                Button {
                    ClipboardHUD.shared.open()
                } label: {
                    Label("Mở bảng Clipboard HUD (⌘⇧C)", systemImage: "macwindow")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var chordCard: some View {
        Card {
            FeatureHeader(
                icon: "computermouse",
                title: "Bấm đồng thời Chuột Trái + Phải mở F3",
                subtitle: "Mở Mission Control ngay trên chuột mà không cần chạm bàn phím",
                isOn: Binding(get: { chord.isEnabled }, set: { chord.setEnabled($0) }),
                tint: .blue
            )
        }
    }
}

private struct ShortcutRow: View {
    let shortcuts: [(key: String, label: String)]

    init(_ shortcuts: [(String, String)]) {
        self.shortcuts = shortcuts.map { (key: $0.0, label: $0.1) }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(shortcuts, id: \.key) { shortcut in
                KeyHint(key: shortcut.key, label: shortcut.label)
            }
        }
    }
}
