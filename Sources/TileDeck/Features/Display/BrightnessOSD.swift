import AppKit

/// Brightness HUD for external displays. Asks macOS to draw its own HUD there,
/// so it looks exactly like the built-in one; if that private API ever goes
/// away, falls back to a look-alike drawn in plain AppKit.
@MainActor
final class BrightnessOSD {
    static let shared = BrightnessOSD()

    private static let brightnessImage: Int64 = 1
    private static let chiclets: UInt32 = 64
    private static let size = NSSize(width: 200, height: 160)
    private static let visibleDuration: TimeInterval = 1.2

    private lazy var panel = makePanel()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let bar = LevelBar()
    private var hideWork: DispatchWorkItem?

    func show(level: Double, displayName: String, on id: CGDirectDisplayID) {
        if let showNative = PrivateAPI.showOSD {
            let filled = UInt32((min(max(level, 0), 1) * Double(Self.chiclets)).rounded())
            showNative(Self.brightnessImage, id, filled, Self.chiclets)
            return
        }
        showFallback(level: level, displayName: displayName, on: id)
    }

    private func showFallback(level: Double, displayName: String, on id: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == id }) else { return }

        let symbol = level < 0.3 ? "sun.min.fill" : "sun.max.fill"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 46, weight: .regular))
        label.stringValue = displayName
        bar.level = level

        let frame = screen.frame
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 140))
        hideWork?.cancel()
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fadeOut() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.visibleDuration, execute: work)
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true

        icon.contentTintColor = .labelColor
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail

        for view in [icon, label, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            icon.topAnchor.constraint(equalTo: background.topAnchor, constant: 26),
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            bar.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 22),
            bar.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -22),
            bar.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -22),
            bar.heightAnchor.constraint(equalToConstant: 6),
        ])

        panel.contentView = background
        return panel
    }
}

/// Rounded track with a filled portion; two layers, no drawing code.
private final class LevelBar: NSView {
    private let track = CALayer()
    private let fill = CALayer()

    var level: Double = 0 {
        didSet { needsLayout = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = bounds.height / 2
        track.frame = bounds
        track.cornerRadius = radius
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * min(max(level, 0), 1), height: bounds.height)
        fill.cornerRadius = radius
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
            fill.backgroundColor = NSColor.labelColor.withAlphaComponent(0.85).cgColor
        }
        CATransaction.commit()
    }
}
