import AVFoundation
import AppKit
import SwiftUI

private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }

    /// A borderless, see-through panel that follows the user across Spaces.
    convenience init(frame: CGRect, level: NSWindow.Level) {
        self.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        animationBehavior = .none
    }
}

// MARK: Choosing what to capture

/// The bar at the top of the screen: take a picture or a video, and of what.
struct ScreenCaptureModeBar: View {
    @ObservedObject var options: ScreenCaptureOptions
    let isRecording: Bool
    let chooseAction: (Bool) -> Void
    let chooseMode: (ScreenCaptureMode) -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                segment(icon: "camera.fill", title: "Chụp", isOn: !isRecording, tint: .accentColor) { chooseAction(false) }
                segment(icon: "record.circle.fill", title: "Quay", isOn: isRecording, tint: .red) { chooseAction(true) }
            }
            ScreenshotToolbarSeparator()
            HStack(spacing: 2) {
                ForEach(ScreenCaptureMode.allCases) { mode in
                    segment(icon: mode.icon, title: mode.title, isOn: options.mode == mode, tint: .white.opacity(0.2)) { chooseMode(mode) }
                }
            }
        }
        .padding(6)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: ScreenshotToolbar.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: ScreenshotToolbar.cornerRadius).strokeBorder(.white.opacity(0.14)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private func segment(icon: String, title: String, isOn: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        ModeSegment(icon: icon, title: title, isOn: isOn, tint: tint, action: action)
    }
}

private struct ModeSegment: View {
    let icon: String
    let title: String
    let isOn: Bool
    let tint: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11.5, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(isOn ? tint : .white.opacity(isHovered ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct ScreenRecordToolbar: View {
    @ObservedObject var tool: ScreenRecordTool
    let start: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                sourceToggle(on: "speaker.wave.2.fill", off: "speaker.slash.fill", title: "Tiếng máy", isOn: tool.recordsSystemAudio) {
                    tool.setSystemAudio(!tool.recordsSystemAudio)
                }
                sourceToggle(on: "mic.fill", off: "mic.slash.fill", title: "Micro", isOn: tool.recordsMicrophone) {
                    tool.setMicrophone(!tool.recordsMicrophone)
                }
            }
            ScreenshotToolbarSeparator()
            HStack(spacing: 1) {
                ForEach([30, 60], id: \.self) { rate in
                    Button {
                        tool.setFramesPerSecond(rate)
                    } label: {
                        Text("\(rate) fps")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(.white.opacity(tool.framesPerSecond == rate ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            ScreenshotToolbarSeparator()
            HStack(spacing: 4) {
                TextAction(icon: "record.circle.fill", title: "Bắt đầu quay", help: "Bắt đầu quay (Return)", isPrimary: true, tint: .red, action: start)
                    .disabled(!tool.hasSelection)
                    .opacity(tool.hasSelection ? 1 : 0.4)
                ToolbarIcon(icon: "xmark", help: "Hủy (Esc)", action: close)
            }
        }
        .padding(6)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: ScreenshotToolbar.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: ScreenshotToolbar.cornerRadius).strokeBorder(.white.opacity(0.14)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private func sourceToggle(on: String, off: String, title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? on : off).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(isOn ? Color.accentColor : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .opacity(isOn ? 1 : 0.65)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Đang bật, bấm để tắt" : "Đang tắt, bấm để bật")
    }
}

// MARK: While recording

/// The stop button and the outline of what's being recorded. Both belong to
/// TileDeck, so ScreenCaptureKit keeps them out of the video.
@MainActor
final class ScreenRecordHUD {
    private var controls: NSPanel?
    private var outline: NSPanel?

    func show(on screen: NSScreen, region: CGRect?, tool: ScreenRecordTool) {
        close()
        let host = DraggableHostingView(rootView: ScreenRecordControls(tool: tool))
        host.frame.size = host.fittingSize
        let area = screen.visibleFrame
        let panel = FloatingPanel(frame: CGRect(x: area.midX - host.frame.width / 2, y: area.minY + 24,
                                                width: host.frame.width, height: host.frame.height), level: .statusBar)
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentView = host
        panel.orderFrontRegardless()
        controls = panel

        guard let region else { return }
        let inset: CGFloat = 3
        let frame = FloatingPanel(frame: region.insetBy(dx: -inset, dy: -inset), level: .statusBar)
        frame.ignoresMouseEvents = true
        frame.hasShadow = false
        let border = NSView(frame: CGRect(origin: .zero, size: frame.frame.size))
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.systemRed.cgColor
        border.layer?.borderWidth = 2
        border.layer?.cornerRadius = 3
        frame.contentView = border
        frame.orderFrontRegardless()
        outline = frame
    }

    func close() {
        controls?.orderOut(nil)
        controls = nil
        outline?.orderOut(nil)
        outline = nil
    }
}

private struct ScreenRecordControls: View {
    @ObservedObject var tool: ScreenRecordTool

    var body: some View {
        HStack(spacing: 10) {
            content
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .frame(height: 42)
        .background(Color(white: 0.11), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        if case .recording(let since) = tool.phase {
            Circle().fill(.red).frame(width: 9, height: 9)
            Text(timerInterval: since...Date.distantFuture, countsDown: false, showsHours: false)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .frame(width: 48, alignment: .leading)
            HStack(spacing: 6) {
                if tool.recordsSystemAudio { Image(systemName: "speaker.wave.2.fill") }
                if tool.recordsMicrophone { Image(systemName: "mic.fill") }
            }
            .font(.system(size: 11))
            .opacity(0.65)
            Button(action: tool.stop) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                    Text("Dừng").font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 13)
                .frame(height: 28)
                .background(.red, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Dừng quay (⌘⇧2)")
        } else {
            ProgressView().controlSize(.small)
            Text("Đang lưu video…")
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.trailing, 8)
        }
    }
}

// MARK: When it's done

@MainActor
final class ScreenRecordToast {
    static let shared = ScreenRecordToast()
    private static let visibleTime: TimeInterval = 12

    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?

    func showSaved(_ url: URL, duration: TimeInterval, note: String?) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let details = "\(ScreenshotGeometry.clock(duration))  ·  \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
        show(ScreenRecordSavedView(url: url, details: note ?? details, close: { [weak self] in self?.close() }))
    }

    func showFailure(_ message: String) {
        show(ScreenRecordFailureView(message: message, close: { [weak self] in self?.close() }))
    }

    private func show<Content: View>(_ view: Content) {
        close()
        let host = DraggableHostingView(rootView: view)
        host.frame.size = host.fittingSize
        let area = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let panel = FloatingPanel(frame: CGRect(x: area.maxX - host.frame.width - 16, y: area.minY + 16,
                                                width: host.frame.width, height: host.frame.height), level: .statusBar)
        panel.hasShadow = true
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel

        let dismissal = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }
        self.dismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleTime, execute: dismissal)
    }

    func close() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ScreenRecordSavedView: View {
    let url: URL
    let details: String
    let close: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.1))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                }
                Image(systemName: "play.fill").font(.system(size: 13)).shadow(radius: 3)
            }
            .frame(width: 92, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { open() }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Đã lưu video").font(.system(size: 12.5, weight: .semibold))
                    Text(details).font(.system(size: 10.5).monospacedDigit()).opacity(0.65).lineLimit(2)
                }
                HStack(spacing: 5) {
                    button("Mở", primary: true, action: open)
                    button("Hiện trong Finder", primary: false) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                        close()
                    }
                }
            }
            .frame(width: 186, alignment: .leading)

            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).opacity(0.6)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(10)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.14)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .task { await loadThumbnail() }
    }

    private func open() {
        NSWorkspace.shared.open(url)
        close()
    }

    private func button(_ title: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(primary ? Color.accentColor : .white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadThumbnail() async {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 368, height: 232)
        guard let image = try? await generator.image(at: .zero).image else { return }
        thumbnail = NSImage(cgImage: image, size: .zero)
    }
}

private struct ScreenRecordFailureView: View {
    let message: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 11.5, weight: .medium)).frame(maxWidth: 280, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).opacity(0.6)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }
}
