import SwiftUI

struct SoundTab: View {
    @ObservedObject private var devices = AudioDevices.shared
    @ObservedObject private var appVolume = AppVolume.shared

    var body: some View {
        VStack(spacing: 10) {
            systemCard
            appsCard
        }
        .onAppear {
            devices.start()
            appVolume.start()
        }
        .onDisappear {
            devices.stop()
            appVolume.stop()
        }
    }

    // MARK: System

    private var systemCard: some View {
        Card {
            Text("HỆ THỐNG").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            DeviceRow(title: "Đầu ra", side: devices.output, isOutput: true)
            Divider()
            DeviceRow(title: "Đầu vào", side: devices.input, isOutput: false)
        }
    }

    // MARK: Apps

    private var appsCard: some View {
        Card {
            HStack {
                Text("ỨNG DỤNG").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("Kéo về 100% để trả lại âm thanh gốc").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            if let other = appVolume.otherMixer {
                Label("\(other) đang chạy. Đừng để hai app cùng chỉnh âm thanh từng ứng dụng.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = appVolume.lastError {
                Button {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                } label: {
                    Label(error, systemImage: "lock.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
            }
            if appVolume.apps.isEmpty {
                Text("Chưa có ứng dụng nào dùng âm thanh.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            ForEach(appVolume.apps) { app in
                AppVolumeRow(app: app)
            }
        }
    }
}

private struct DeviceRow: View {
    let title: String
    let side: AudioDevices.Side
    let isOutput: Bool
    @ObservedObject private var devices = AudioDevices.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("", selection: Binding(get: { side.current }, set: { id in
                    if let device = side.devices.first(where: { $0.id == id }) { devices.select(device, output: isOutput) }
                })) {
                    ForEach(side.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            if let volume = side.volume {
                HStack(spacing: 8) {
                    Button {
                        devices.toggleMute(output: isOutput)
                    } label: {
                        Image(systemName: icon(volume: volume))
                            .font(.system(size: 12))
                            .foregroundStyle(side.muted ? Color.secondary : Color.accentColor)
                            .frame(width: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(!devices.canMute(output: isOutput))
                    Slider(value: Binding(get: { Double(side.muted ? 0 : volume) }, set: { devices.setVolume(Float($0), output: isOutput) }), in: 0...1)
                        .controlSize(.small)
                    Text(side.muted ? "Tắt tiếng" : "\(Int((volume * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(side.muted ? Color.red : Color.primary)
                        .frame(width: 52, alignment: .trailing)
                }
            } else {
                Text("Thiết bị này không cho chỉnh âm lượng từ máy (chỉnh bằng nút trên thiết bị).")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func icon(volume: Float) -> String {
        if !isOutput { return side.muted ? "mic.slash.fill" : "mic.fill" }
        if side.muted || volume == 0 { return "speaker.slash.fill" }
        return volume < 0.33 ? "speaker.wave.1.fill" : (volume < 0.66 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }
}

private struct AppVolumeRow: View {
    let app: AppVolume.App
    @ObservedObject private var appVolume = AppVolume.shared

    private var isMuted: Bool { appVolume.muted.contains(app.id) }
    private var level: Float { isMuted ? 0 : appVolume.level(for: app.id) }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSRunningApplication(processIdentifier: app.pid)?.icon ?? NSImage())
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(app.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    if app.isPlaying {
                        Image(systemName: "waveform")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.green)
                            .help("Đang phát")
                    }
                    Spacer()
                    Text(isMuted ? "Tắt tiếng" : "\(Int((level * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isMuted ? Color.red : (level < 1 ? Color.orange : Color.secondary))
                }
                Slider(value: Binding(get: { Double(level) }, set: { appVolume.setLevel(Float($0), for: app.id) }), in: 0...1)
                    .controlSize(.mini)
                    .tint(.green)
            }
            Button {
                appVolume.toggleMute(app.id)
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(isMuted ? Color.red : Color.secondary)
                    .frame(width: 24, height: 22)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(isMuted ? "Bật tiếng" : "Tắt tiếng")
        }
        .padding(.vertical, 2)
    }
}
