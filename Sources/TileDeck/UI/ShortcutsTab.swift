import SwiftUI

struct ShortcutsTab: View {
    @ObservedObject private var switcher = WindowSwitcher.shared
    @ObservedObject private var tiler = WindowTiler.shared
    @ObservedObject private var clipboard = ClipboardStore.shared
    @ObservedObject private var screenshot = ScreenshotTool.shared
    @ObservedObject private var recording = ScreenRecordTool.shared
    @ObservedObject private var chord = MouseChord.shared
    @ObservedObject private var scroll = MouseScroll.shared
    @State private var trusted = AXWindow.isTrusted

    var body: some View {
        VStack(spacing: 10) {
            if !trusted && (switcher.isEnabled || tiler.isEnabled || clipboard.isEnabled || chord.isEnabled || scroll.isEnabled) {
                permissionNotice
            }
            switcherCard
            tilingCard
            clipboardCard
            screenshotCard
            recordingCard
            chordCard
            scrollCard
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

    private var screenshotCard: some View {
        Card {
            FeatureHeader(
                icon: "camera.viewfinder",
                title: "Chụp vùng màn hình (⌘⇧1)",
                subtitle: "Kéo chọn vùng hoặc bấm vào cửa sổ, vẽ, rồi sao chép hoặc lưu",
                isOn: Binding(get: { screenshot.isEnabled }, set: { screenshot.setEnabled($0) }),
                tint: .blue
            )
            if screenshot.isEnabled {
                ShortcutRow([("⌘⇧1", "Bắt đầu chụp"), ("⌘C", "Sao chép"), ("⌘S", "Lưu ảnh"), ("Esc", "Thoát")])
            }
            if screenshot.isEnabled && !switcher.hasScreenRecording {
                Button {
                    switcher.requestScreenRecording()
                } label: {
                    Label("Cấp quyền Ghi màn hình để chụp ảnh", systemImage: "rectangle.dashed.badge.record")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var recordingCard: some View {
        Card {
            FeatureHeader(
                icon: "record.circle",
                title: "Quay màn hình có tiếng (⌘⇧2)",
                subtitle: "Quay một vùng, một cửa sổ hoặc cả màn hình, lưu thành MP4",
                isOn: Binding(get: { recording.isEnabled }, set: { recording.setEnabled($0) }),
                tint: .blue
            )
            if recording.isEnabled {
                ShortcutRow([("⌘⇧2", "Mở / Dừng quay"), ("↩", "Bắt đầu quay"), ("Esc", "Hủy")])

                HStack(spacing: 6) {
                    Text("Tiếng:").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Chip(title: "Tiếng máy", isSelected: recording.recordsSystemAudio) { recording.setSystemAudio(!recording.recordsSystemAudio) }
                    Chip(title: "Micro", isSelected: recording.recordsMicrophone) { recording.setMicrophone(!recording.recordsMicrophone) }
                    Spacer()
                }

                HStack(spacing: 6) {
                    Text("Lưu vào:").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Text(recording.folder.lastPathComponent)
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Đổi…") { recording.chooseFolder() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                if recording.microphoneDenied {
                    Text("Micro đang bị từ chối. Bấm Micro để mở Cài đặt và cho phép TileDeck.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if recording.isEnabled && !switcher.hasScreenRecording {
                Button {
                    switcher.requestScreenRecording()
                } label: {
                    Label("Cấp quyền Ghi màn hình để quay video", systemImage: "rectangle.dashed.badge.record")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
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

extension ShortcutsTab {
    private var scrollCard: some View {
        Card {
            FeatureHeader(
                icon: "scroll",
                title: "Cuộn chuột mượt (thay thế Mos)",
                subtitle: "Cuộn mượt và đảo chiều riêng cho chuột, trackpad giữ nguyên",
                isOn: Binding(get: { scroll.isEnabled }, set: { scroll.setEnabled($0) }),
                tint: .blue
            )
            if scroll.isEnabled {
                switchRow("Cuộn mượt", icon: "wind", isOn: scroll.smooth, set: scroll.setSmooth)
                switchRow("Đảo chiều cuộn của chuột", icon: "arrow.up.arrow.down", isOn: scroll.reverse, set: scroll.setReverse)

                if scroll.smooth {
                    choiceRow("Tốc độ:", titles: MouseScroll.speeds.map(\.title), selected: scroll.speedIndex, set: scroll.setSpeed)
                    choiceRow("Độ trôi:", titles: MouseScroll.glides.map(\.title), selected: scroll.glideIndex, set: scroll.setGlide)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Bỏ qua trong:").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                        Menu("Thêm app") {
                            ForEach(scroll.exceptionCandidates, id: \.id) { app in
                                Button(app.name) { scroll.addException(app.id) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .font(.system(size: 10.5, weight: .semibold))
                    }
                    if scroll.exceptions.isEmpty {
                        Text("Chưa có app nào. Thêm game hoặc app điều khiển máy từ xa nếu cuộn bị lạ.")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        FlowChips(items: scroll.exceptions) { id in
                            HStack(spacing: 4) {
                                Text(MouseScroll.appName(id)).font(.system(size: 10, weight: .medium))
                                Button { scroll.removeException(id) } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain)
                                .help("Bỏ khỏi danh sách")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
        }
    }

    private func switchRow(_ title: String, icon: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .labelStyle(TightLabelStyle(tint: .blue))
                .font(.system(size: 10.5))
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private func choiceRow(_ label: String, titles: [String], selected: Int, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            ForEach(titles.indices, id: \.self) { index in
                Chip(title: titles[index], isSelected: selected == index) { set(index) }
            }
            Spacer()
        }
    }
}

/// Chips that wrap onto new lines.
private struct FlowChips<Content: View>: View {
    let items: [String]
    let content: (String) -> Content

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(items, id: \.self) { content($0) }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, point) in arrange(width: bounds.width, subviews: subviews).points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, CGSize(width: widest, height: y + lineHeight))
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
