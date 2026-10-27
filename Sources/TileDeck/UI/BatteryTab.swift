import SwiftUI

struct BatteryTab: View {
    enum Section: String, CaseIterable, Identifiable {
        case power, sleep, freeze, calibration

        var id: String { rawValue }

        var title: String {
            switch self {
            case .power: "Nguồn SMC"
            case .sleep: "Sleep Guard"
            case .freeze: "Đóng băng"
            case .calibration: "Hiệu chuẩn"
            }
        }

        var icon: String {
            switch self {
            case .power: "shield.lefthalf.filled"
            case .sleep: "moon.zzz"
            case .freeze: "snowflake"
            case .calibration: "calendar.badge.clock"
            }
        }
    }

    @ObservedObject private var monitor = BatteryMonitor.shared
    @ObservedObject private var alerts = BatteryAlerts.shared
    @AppStorage("batterySection") private var section: Section = .power

    private var battery: BatteryMonitor.Snapshot { monitor.snapshot }

    var body: some View {
        VStack(spacing: 10) {
            if battery.hasBattery {
                overviewCard
                Card {
                    sectionBar
                    switch section {
                    case .power: powerSection
                    case .sleep: SleepGuardSection()
                    case .freeze: FreezeSection()
                    case .calibration: CalibrationSection()
                    }
                }
            } else {
                Card {
                    Label("Máy này không có pin", systemImage: "powerplug")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Overview

    private var overviewCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(battery.percent)").font(.system(size: 30, weight: .bold).monospacedDigit())
                    Text("%").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Label(powerStatus.text, systemImage: powerStatus.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(powerStatus.color)
                    if let watts = battery.systemWatts {
                        Text("Máy đang dùng \(String(format: "%.1f", watts))W")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            LevelBar(level: Double(battery.percent) / 100, colors: barColors)

            HStack(spacing: 6) {
                StatTile(icon: "heart.fill", tint: .pink, title: "Độ khỏe pin",
                         value: String(format: "%.1f%%", battery.health * 100),
                         caption: "\(battery.fullCapacity)/\(battery.designCapacity) mAh")
                StatTile(icon: "arrow.triangle.2.circlepath", tint: .purple, title: "Chu kỳ sạc",
                         value: "\(battery.cycleCount) lần",
                         caption: "Thiết kế: \(battery.designCycles)")
                StatTile(icon: "thermometer.medium", tint: temperatureStatus.color, title: "Nhiệt độ pin",
                         value: String(format: "%.1f°C", battery.temperature),
                         caption: temperatureStatus.text, valueColor: temperatureStatus.color)
                StatTile(icon: "bolt.fill", tint: .orange, title: "Củ sạc",
                         value: battery.adapterWatts.map { "\($0)W" } ?? "—",
                         caption: battery.adapterName ?? "Chưa cắm")
            }
        }
    }

    private var powerStatus: (text: String, icon: String, color: Color) {
        let watts = String(format: "%.1fW", abs(battery.batteryWatts))
        if !battery.onAC { return ("Đang xả \(watts)", "battery.50percent", .secondary) }
        if battery.isCharging { return ("Đang sạc \(watts)", "bolt.fill", .green) }
        return ("\(watts) (Đã cắm sạc)", "powerplug.fill", .orange)
    }

    private var barColors: [Color] {
        switch battery.percent {
        case ..<20: [.red, .orange]
        case ..<40: [.orange, .yellow]
        default: [.green, .mint]
        }
    }

    private var temperatureStatus: (text: String, color: Color) {
        switch battery.temperature {
        case ..<35: ("Mát mẻ", .green)
        case ..<BatteryAlerts.hotTemperature: ("Hơi ấm", .orange)
        default: ("Nóng", .red)
        }
    }

    // MARK: Sections

    private var sectionBar: some View {
        HStack(spacing: 3) {
            ForEach(Section.allCases) { item in
                Button {
                    section = item
                } label: {
                    Label(item.title, systemImage: item.icon)
                        .labelStyle(TightLabelStyle(tint: section == item ? .white : .secondary))
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(section == item ? Color.white : Color.primary.opacity(0.75))
                        .background(section == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var powerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureHeader(
                icon: "lock.shield",
                title: "Khóa sạc ở 80% (chạy điện trực tiếp)",
                subtitle: "Cắm sạc liên tục mà không chai pin (SMC Bypass)",
                isOn: .constant(false),
                tint: .blue
            )
            .disabled(!ChargeControl.canLimitCharge)

            if !ChargeControl.canLimitCharge {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Firmware của máy này đã bỏ khóa SMC dùng để ngắt sạc, nên chưa thể khóa sạc an toàn. Hãy bật \"Sạc pin được tối ưu hóa\" của macOS để thay thế.",
                          systemImage: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Mở Cài đặt Pin") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            AlertRow(icon: "flame.fill", tint: .orange,
                     title: "Thông báo khi pin nóng > \(Int(BatteryAlerts.hotTemperature))°C",
                     isOn: Binding(get: { alerts.heatAlert }, set: { alerts.setHeatAlert($0) }))
            AlertRow(icon: "bell.badge.fill", tint: .blue,
                     title: "Cảnh báo chống chai pin (Màn ngoài, pin < \(BatteryAlerts.lowPercent)%)",
                     isOn: Binding(get: { alerts.lowBatteryAlert }, set: { alerts.setLowBatteryAlert($0) }))
        }
    }
}

private struct StatTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let caption: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .labelStyle(TightLabelStyle(tint: tint))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(caption)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TightLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

private struct LevelBar: View {
    let level: Double
    let colors: [Color]

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * min(max(level, 0), 1))
            }
        }
        .frame(height: 8)
    }
}

struct AlertRow: View {
    let icon: String
    let tint: Color
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(title).font(.system(size: 11))
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }
}
