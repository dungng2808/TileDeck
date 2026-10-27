import SwiftUI

// MARK: Sleep Guard

struct SleepGuardSection: View {
    @ObservedObject private var guardian = SleepGuard.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureHeader(
                icon: "moon.fill",
                title: "Chặn Dark Wake khi gập máy",
                subtitle: "Tắt Power Nap và TCP keep-alive khi dùng pin để máy không thức ngầm, nóng trong balo",
                isOn: Binding(get: { guardian.darkWakeBlocked }, set: { guardian.setDarkWakeBlocked($0) }),
                tint: .purple
            )
            .disabled(guardian.isApplying)

            FeatureHeader(
                icon: "dot.radiowaves.left.and.right",
                title: "Tự ngắt Bluetooth khi gập máy",
                subtitle: "AirPods, chuột không đánh thức máy ngầm qua đêm. Tự bật lại ngay khi mở máy",
                isOn: Binding(get: { guardian.bluetoothOffOnLid }, set: { guardian.setBluetoothOffOnLid($0) }),
                tint: .blue
            )
            .disabled(!guardian.bluetoothAvailable)

            if let error = guardian.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            Label("Đổi Dark Wake cần mật khẩu quản trị. Khi bật, Find My và nhận thư khi đang ngủ cũng tạm dừng lúc dùng pin.",
                  systemImage: "info.circle.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { guardian.refresh() }
    }
}

// MARK: Freeze

struct FreezeSection: View {
    @ObservedObject private var freezer = ProcessFreezer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tiến trình ngốn CPU & tỏa nhiệt")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Button {
                    freezer.scan()
                } label: {
                    Label(freezer.isScanning ? "Đang quét…" : "Quét lại", systemImage: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                }
                .controlSize(.small)
                .disabled(freezer.isScanning)
            }

            if freezer.processes.isEmpty {
                Text(freezer.isScanning ? "Đang đo CPU trong 1 giây…" : "Không có tiến trình nào đang ngốn CPU.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 4) {
                    ForEach(freezer.processes) { process in
                        ProcessRow(process: process)
                    }
                }
            }

            Label("Đóng băng (SIGSTOP) giữ nguyên cửa sổ và dữ liệu trong RAM nhưng dừng 100% việc dùng CPU. Thoát TileDeck sẽ tự rã đông tất cả.",
                  systemImage: "lightbulb.fill")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { freezer.scan() }
    }
}

private struct ProcessRow: View {
    let process: ProcessUsage
    @ObservedObject private var freezer = ProcessFreezer.shared

    private var color: Color {
        if process.isFrozen { return .blue }
        return process.cpu >= 50 ? .red : (process.cpu >= 10 ? .orange : .yellow)
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(process.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(verbatim: "PID: \(process.id)").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(process.isFrozen ? "Đã đóng băng" : String(format: "%.1f%% CPU", process.cpu))
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
            Button {
                process.isFrozen ? freezer.thaw(process.id) : freezer.freeze(process.id)
            } label: {
                Label(process.isFrozen ? "Rã đông" : "Đóng băng", systemImage: process.isFrozen ? "sun.max" : "snowflake")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .foregroundStyle(process.isFrozen ? Color.white : Color.blue)
                    .background(process.isFrozen ? Color.blue : Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .disabled(!process.canFreeze)
            .opacity(process.canFreeze ? 1 : 0.4)
            .help(process.canFreeze ? "" : "Tiến trình hệ thống, đóng băng sẽ treo giao diện")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: Calibration

struct CalibrationSection: View {
    @ObservedObject private var calibration = Calibration.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FeatureHeader(
                icon: "calendar.badge.clock",
                title: "Tự động đặt lịch hiệu chuẩn pin định kỳ",
                subtitle: "Cân bằng điện áp cell và giúp macOS đo dung lượng pin chính xác",
                isOn: Binding(get: { calibration.isEnabled }, set: { calibration.setEnabled($0) }),
                tint: .blue
            )

            HStack(spacing: 6) {
                Text("Chu kỳ:").font(.system(size: 10.5)).foregroundStyle(.secondary)
                ForEach(Calibration.intervals, id: \.self) { days in
                    Chip(title: days == 30 ? "Mỗi 30 ngày (Chuẩn)" : "Mỗi \(days) ngày",
                         isSelected: calibration.intervalDays == days) {
                        calibration.setInterval(days)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label("Lịch tiếp theo: \(calibration.nextDate.formatted(date: .numeric, time: .omitted))", systemImage: "clock")
                    Spacer()
                    Text("Còn \(calibration.daysLeft) ngày")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
                Label("Lần gần nhất: \(calibration.lastDate?.formatted(date: .numeric, time: .omitted) ?? "chưa có")", systemImage: "checkmark.circle")
                Label("Quy trình: rút sạc, dùng máy đến ≤ \(Calibration.drainTarget)%, cắm sạc đầy 100% rồi giữ thêm \(Calibration.holdMinutes) phút. TileDeck báo từng bước.",
                      systemImage: "lightbulb.fill")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10))
            .padding(8)
            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))

            if calibration.phase == .idle {
                Button {
                    calibration.startNow()
                } label: {
                    Label("Hiệu chuẩn ngay bây giờ (chạy trước lịch)", systemImage: "play.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            } else {
                HStack {
                    Label(progressText, systemImage: "hourglass")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Hủy") { calibration.cancel() }
                        .controlSize(.small)
                }
            }
        }
    }

    private var progressText: String {
        switch calibration.phase {
        case .idle: ""
        case .draining: "Bước 1/3: rút sạc, dùng đến ≤ \(Calibration.drainTarget)%"
        case .charging: "Bước 2/3: cắm sạc tới 100%"
        case .holding: "Bước 3/3: giữ sạc thêm \(Calibration.holdMinutes) phút"
        }
    }
}
