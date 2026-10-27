import SwiftUI

struct DisplayTab: View {
    @ObservedObject private var displays = DisplayController.shared
    @ObservedObject private var caffeinate = Caffeinate.shared
    @ObservedObject private var keys = BrightnessKeys.shared

    var body: some View {
        VStack(spacing: 10) {
            caffeinateCard
            keysCard
            ForEach(displays.displays) { item in
                DisplayCard(item: item)
            }
            bottomActions
        }
        .onAppear {
            displays.refresh()
            displays.startObservingBrightness()
            keys.activateIfNeeded()
        }
        .onDisappear {
            displays.stopObservingBrightness()
        }
    }

    private var caffeinateCard: some View {
        Card {
            FeatureHeader(
                icon: "cup.and.saucer.fill",
                title: "Chống sleep màn (Caffeinate)",
                subtitle: caffeinate.endsAt.map { "Giữ màn hình sáng đến \($0.formatted(date: .omitted, time: .shortened))" }
                    ?? "Giữ màn hình luôn sáng như 'caffeinate -d' trong Terminal",
                isOn: Binding(get: { caffeinate.isOn }, set: { caffeinate.setOn($0) })
            )
            HStack(spacing: 6) {
                ForEach(Caffeinate.Duration.allCases) { duration in
                    Chip(title: duration.label, isSelected: caffeinate.duration == duration, isProminent: true) {
                        caffeinate.select(duration)
                    }
                }
            }
        }
    }

    private var keysCard: some View {
        Card {
            FeatureHeader(
                icon: "sun.max",
                title: "F1 / F2 chỉnh màn hình theo con trỏ chuột",
                subtitle: "Tự nhận diện màn hình trong hoặc ngoài để tăng giảm độ sáng",
                isOn: Binding(get: { keys.isEnabled }, set: { keys.setEnabled($0) })
            )
            if keys.needsPermission {
                Button {
                    keys.openAccessibilitySettings()
                } label: {
                    Label("Cần quyền Trợ năng (Accessibility) — bấm để mở Cài đặt", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var bottomActions: some View {
        let hasDisabled = displays.displays.contains(where: \.isDisabled)
        let canDisconnectExternals = displays.canSoftDisconnect
            && displays.displays.contains { $0.isBuiltin && !$0.isDisabled }
            && displays.displays.contains { !$0.isBuiltin && !$0.isDisabled }
        if hasDisabled || canDisconnectExternals {
            HStack {
                if canDisconnectExternals {
                    Button("Ngắt màn ngoài") { displays.disableExternals() }
                        .controlSize(.small)
                }
                if hasDisabled {
                    Button("Bật lại tất cả") { displays.enableAll() }
                        .controlSize(.small)
                }
                Spacer()
            }
        }
    }
}

private struct DisplayCard: View {
    let item: DisplayItem
    @ObservedObject private var displays = DisplayController.shared

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.isBuiltin ? "laptopcomputer" : "display")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if item.isDisabled {
                    Text("Đã ngắt").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                } else {
                    Text("\(Int((item.brightness * 100).rounded()))%")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                }
            }

            if !item.isDisabled {
                Slider(
                    value: Binding(get: { item.brightness }, set: { displays.setBrightness($0, for: item.id) }),
                    in: 0...1
                )
                .controlSize(.small)
            }

            HStack(spacing: 6) {
                if !item.isDisabled {
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { level in
                        Chip(title: "\(Int(level * 100))%") {
                            displays.setBrightness(level, for: item.id)
                        }
                    }
                }
                Spacer()
                disconnectButton
            }
        }
        .opacity(item.isDisabled ? 0.6 : 1)
    }

    private var subtitle: String {
        var parts = [item.size]
        parts.append(item.isMain ? "Màn hình chính" : (item.isBuiltin ? "Màn hình tích hợp" : "Màn hình ngoài"))
        if item.control == .software && !item.isDisabled { parts.append("Làm mờ phần mềm") }
        return parts.joined(separator: " • ")
    }

    @ViewBuilder
    private var disconnectButton: some View {
        if item.isDisabled {
            Button("Bật lại") { displays.setEnabled(true, for: item.id) }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        } else if displays.canSoftDisconnect && displays.activeCount > 1 {
            Button(item.isBuiltin ? "Tắt màn" : "Ngắt mềm") { displays.setEnabled(false, for: item.id) }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.red)
                .help(item.isBuiltin ? "Tắt màn hình tích hợp, các cửa sổ chuyển sang màn ngoài" : "Ngắt màn hình này mà không cần rút cáp")
        }
    }
}
