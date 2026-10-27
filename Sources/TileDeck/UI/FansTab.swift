import SwiftUI

struct FansTab: View {
    @ObservedObject private var monitor = FanMonitor.shared
    @ObservedObject private var controller = FanController.shared

    var body: some View {
        VStack(spacing: 10) {
            if let other = monitor.otherController {
                Label("\(other) đang chạy. Đừng để hai app cùng điều khiển quạt.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if controller.helperState != .ready {
                helperCard
            }
            fansCard
            temperaturesCard
        }
        .onAppear {
            monitor.start()
            controller.refreshHelperState()
        }
        .onDisappear { monitor.stop() }
    }

    private var fansCard: some View {
        Card {
            HStack {
                Text("Quạt").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("vòng/phút").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            if monitor.fans.isEmpty {
                Text("Máy này không có quạt hoặc chưa đọc được.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(monitor.fans) { fan in
                FanRow(fan: fan, canControl: controller.helperState == .ready)
            }
            if let error = controller.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    private var helperCard: some View {
        Card {
            FeatureHeaderText(
                icon: "lock.shield",
                title: "Điều khiển quạt",
                subtitle: "Cần cài một trình trợ giúp chạy quyền quản trị (giống Macs Fan Control). Chỉ TileDeck của bạn gọi được nó, và quạt tự về Tự động khi TileDeck thoát."
            )
            Button {
                controller.helperState == .needsApproval ? controller.openApprovalSettings() : controller.installHelper()
            } label: {
                Label(controller.helperState == .needsApproval ? "Mở Cài đặt để cho phép TileDeck" : "Cài trình trợ giúp",
                      systemImage: controller.helperState == .needsApproval ? "gearshape" : "arrow.down.circle")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            if controller.helperState == .needsApproval {
                Text("Trong Cài đặt › Cài đặt chung › Mục đăng nhập, bật TileDeck ở phần \"Cho phép chạy nền\", rồi quay lại đây.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var temperaturesCard: some View {
        Card {
            HStack {
                Text("Nhiệt độ").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("trung bình · cao nhất").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(monitor.groups) { group in
                    TemperatureTile(group: group)
                }
            }
            Button {
                monitor.showsAllSensors.toggle()
            } label: {
                Label(monitor.showsAllSensors ? "Thu gọn danh sách cảm biến" : "Xem tất cả cảm biến",
                      systemImage: monitor.showsAllSensors ? "chevron.up" : "list.bullet")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            if monitor.showsAllSensors {
                if monitor.sections.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else {
                    SensorList(sections: monitor.sections)
                }
            }
        }
        .onDisappear { monitor.showsAllSensors = false }
    }
}

private struct FanRow: View {
    let fan: FanMonitor.Fan
    let canControl: Bool
    @ObservedObject private var controller = FanController.shared
    @State private var draftRPM: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.blue)
                Text(fan.name).font(.system(size: 11.5, weight: .semibold))
                Text(badge.text)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .foregroundStyle(badge.color)
                    .background(badge.color.opacity(0.12), in: Capsule())
                Spacer()
                Text(verbatim: "\(Int(fan.current.rounded()))")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(proxy.size.width * fan.load, 4))
                }
            }
            .frame(height: 5)
            HStack {
                Text(verbatim: "\(Int(fan.minimum))").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Text(verbatim: "\(Int(fan.maximum))").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            }
            if canControl {
                controls
            }
        }
        .padding(8)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension FanRow {
    enum Choice: String, CaseIterable {
        case automatic = "Tự động"
        case fixed = "Cố định"
        case temperature = "Theo nhiệt độ"
    }

    var choice: Choice {
        switch controller.mode(for: fan.id) {
        case .automatic: .automatic
        case .fixed: .fixed
        case .temperature: .temperature
        }
    }

    @ViewBuilder
    var controls: some View {
        Picker("", selection: Binding(get: { choice }, set: { select($0) })) {
            ForEach(Choice.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)

        switch controller.mode(for: fan.id) {
        case .automatic:
            EmptyView()
        case .fixed(let rpm):
            HStack(spacing: 8) {
                Slider(value: Binding(get: { draftRPM ?? rpm }, set: { draftRPM = $0 }),
                       in: fan.minimum...max(fan.maximum, fan.minimum + 1), step: 100) { editing in
                    // Send the speed once the knob is released, not on every pixel.
                    if !editing, let value = draftRPM {
                        controller.setMode(.fixed(rpm: value), for: fan.id)
                        draftRPM = nil
                    }
                }
                .controlSize(.small)
                Text(verbatim: "\(Int(draftRPM ?? rpm))")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }
        case .temperature(let low, let high, let chosen):
            let sensor = chosen ?? "cpu"
            HStack(spacing: 6) {
                Text("Theo").font(.system(size: 10)).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { sensor }, set: { controller.setMode(.temperature(low: low, high: high, sensor: $0), for: fan.id) })) {
                    ForEach(FanMonitor.sensorChoices, id: \.id) { choice in
                        Text(choice.name).tag(choice.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                if let reading = controller.sensorReadings[sensor] {
                    Text(String(format: "đang %.0f°", reading))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(reading >= high ? .red : (reading >= low ? .orange : .green))
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Stepper(value: Binding(get: { low }, set: { controller.setMode(.temperature(low: min($0, high - 5), high: high, sensor: sensor), for: fan.id) }),
                        in: 30...90, step: 5) {
                    Text(verbatim: "Tăng từ \(Int(low))°").font(.system(size: 10))
                }
                Stepper(value: Binding(get: { high }, set: { controller.setMode(.temperature(low: low, high: max($0, low + 5), sensor: sensor), for: fan.id) }),
                        in: 40...100, step: 5) {
                    Text(verbatim: "Tối đa ở \(Int(high))°").font(.system(size: 10))
                }
            }
            .controlSize(.mini)
            Text("Dưới \(Int(low))° quạt chạy chậm nhất, từ \(Int(high))° chạy nhanh nhất, ở giữa tăng dần.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    /// What TileDeck is doing with this fan, rather than the SMC's raw manual flag
    /// (a temperature curve is "manual" to the SMC too).
    var badge: (text: String, color: Color) {
        switch controller.mode(for: fan.id) {
        case .fixed: return ("Cố định", .orange)
        case .temperature: return ("Theo nhiệt độ", .blue)
        case .automatic: return fan.isManual ? ("Thủ công (app khác)", .red) : ("Tự động", .secondary)
        }
    }

    func select(_ choice: Choice) {
        switch choice {
        case .automatic: controller.setMode(.automatic, for: fan.id)
        case .fixed: controller.setMode(.fixed(rpm: (fan.current / 100).rounded() * 100), for: fan.id)
        case .temperature: controller.setMode(.temperature(low: 50, high: 85, sensor: "cpu"), for: fan.id)
        }
    }
}

/// Every sensor as one flat table, laid out like Macs Fan Control's sensor
/// pane: a header row, group titles inline, zebra rows, values on the right.
/// It scrolls inside a fixed height so the panel never grows past the screen.
private struct SensorList: View {
    let sections: [FanMonitor.SensorSection]
    @State private var showsUnnamed = false

    private static let height: CGFloat = 320

    private enum Row: Identifiable {
        case title(String)
        case sensor(FanMonitor.Sensor, icon: String, index: Int)

        var id: String {
            switch self {
            case .title(let name): "title-\(name)"
            case .sensor(let sensor, _, _): sensor.key
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var index = 0
        let named = sections.filter { !$0.id.hasPrefix("other-") }
        let unnamed = sections.filter { $0.id.hasPrefix("other-") }.flatMap(\.sensors).sorted { $0.key < $1.key }
        for section in named {
            rows.append(.title(section.name))
            for sensor in section.sensors {
                rows.append(.sensor(sensor, icon: Self.icon(for: sensor.key, section: section.id), index: index))
                index += 1
            }
        }
        if showsUnnamed && !unnamed.isEmpty {
            rows.append(.title("Chưa rõ tên"))
            for sensor in unnamed {
                rows.append(.sensor(sensor, icon: "thermometer.medium", index: index))
                index += 1
            }
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                HStack {
                    Text("Cảm biến")
                    Spacer()
                    Text("Giá trị °C")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.primary.opacity(0.06))

                Divider()

                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            switch row {
                            case .title(let name):
                                Text(name)
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.top, 7)
                                    .padding(.bottom, 2)
                            case .sensor(let sensor, let icon, let index):
                                HStack(spacing: 8) {
                                    Image(systemName: icon)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    Text(sensor.name).font(.system(size: 11)).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(sensor.value.map { String(format: "%.0f", $0) } ?? "nghỉ")
                                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(sensor.value.map(temperatureColor) ?? .secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.04))
                                .help(sensor.key)
                            }
                        }
                    }
                }
                .frame(height: Self.height)
            }
            .background(.background.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1)))

            let unnamedCount = sections.filter { $0.id.hasPrefix("other-") }.reduce(0) { $0 + $1.sensors.count }
            if unnamedCount > 0 {
                Toggle(isOn: $showsUnnamed) {
                    Text("Hiện thêm \(unnamedCount) cảm biến chưa rõ tên").font(.system(size: 10))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func icon(for key: String, section: String) -> String {
        switch section {
        case "pcore": return "cpu"
        case "ecore": return "cpu.fill"
        case "gpu": return "square.stack.3d.up.fill"
        case "memory": return "memorychip"
        case "pmu": return "bolt.circle"
        default: break
        }
        if key.hasPrefix("TB") { return "battery.75percent" }
        if key.hasPrefix("TH") { return "internaldrive" }
        switch key {
        case "TW0P": return "wifi"
        case "TPSP": return "powerplug"
        case "TaLT", "TaRT": return "bolt.horizontal"
        case "TaLP", "TaRF": return "wind"
        case "Ts0P", "Ts1P": return "rectangle.and.hand.point.up.left"
        default: return "thermometer.medium"
        }
    }
}

private func temperatureColor(_ value: Double) -> Color {
    switch value {
    case ..<55: .green
    case ..<80: .orange
    default: .red
    }
}

private struct TemperatureTile: View {
    let group: FanMonitor.SensorGroup

    private var color: Color {
        switch group.hottest {
        case ..<55: .green
        case ..<80: .orange
        default: .red
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: group.icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(String(format: "%.0f°", group.average))
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                    if group.hottest - group.average >= 1 {
                        Text(String(format: "· %.0f°", group.hottest))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(color)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
