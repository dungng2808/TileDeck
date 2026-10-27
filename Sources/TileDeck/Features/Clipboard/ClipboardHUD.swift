import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Floating clipboard picker (⌘⇧C). A non-activating panel: it takes the
/// keyboard for search while the app you're pasting into stays frontmost.
/// Built on open and released on close.
@MainActor
final class ClipboardHUD: NSObject, NSWindowDelegate {
    static let shared = ClipboardHUD()

    private var panel: HUDPanel?
    private var model: ClipboardHUDModel?
    private var keyMonitor: Any?

    var isOpen: Bool { panel != nil }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard panel == nil else { return }
        let model = ClipboardHUDModel()
        let size = NSSize(width: 440, height: 540)
        let panel = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self

        let host = NSHostingView(rootView: ClipboardHUDView(model: model, close: { [weak self] in self?.close() }))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let area = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + 60))
        }
        panel.makeKeyAndOrderFront(nil)

        self.panel = panel
        self.model = model
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
        panel?.delegate = nil
        panel = nil
        model = nil
    }

    /// Clicking anywhere else dismisses it, like Spotlight.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let model else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(event.keyCode) {
        case kVK_Escape:
            close()
        case kVK_DownArrow:
            model.move(1)
        case kVK_UpArrow:
            model.move(-1)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            pasteSelected()
        case kVK_ANSI_P where flags == .option:
            model.togglePinSelected()
        case kVK_Delete where flags == .option, kVK_ForwardDelete where flags == .option:
            model.deleteSelected()
        default:
            // 1–9 paste instantly, but only while the search box is empty so digits can still be searched.
            if flags.isDisjoint(with: [.command, .control, .option]), model.query.isEmpty,
               let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit),
               digit <= model.visible.count {
                paste(model.visible[digit - 1])
                return true
            }
            return false
        }
        return true
    }

    private func pasteSelected() {
        guard let item = model?.selectedItem else { return }
        paste(item)
    }

    func paste(_ item: ClipboardItem) {
        close()
        ClipboardStore.shared.paste(item)
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ClipboardHUDModel: ObservableObject {
    enum Filter: String, CaseIterable, Identifiable {
        case all, text, image, link, file, color

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "Tất cả"
            case .text: "Văn bản"
            case .image: "Hình ảnh"
            case .link: "Liên kết"
            case .file: "Tệp tin"
            case .color: "Màu sắc"
            }
        }

        var icon: String {
            switch self {
            case .all: "square.grid.2x2"
            case .text: "text.alignleft"
            case .image: "photo"
            case .link: "link"
            case .file: "doc"
            case .color: "paintpalette"
            }
        }

        var kind: ClipboardItem.Kind? {
            switch self {
            case .all: nil
            case .text: .text
            case .image: .image
            case .link: .link
            case .file: .file
            case .color: .color
            }
        }
    }

    @Published var query = "" { didSet { selection = 0 } }
    @Published var filter: Filter = .all { didSet { selection = 0 } }
    @Published var selection = 0

    let store = ClipboardStore.shared
    let thumbnails = NSCache<NSString, NSImage>()

    var visible: [ClipboardItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return store.orderedItems.filter { item in
            if let kind = filter.kind, item.kind != kind { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [item.text, item.filePaths?.joined(separator: " "), item.sourceApp].compactMap { $0 }.joined(separator: " ")
            return haystack.lowercased().contains(needle)
        }
    }

    var selectedItem: ClipboardItem? {
        let items = visible
        return items.indices.contains(selection) ? items[selection] : nil
    }

    func move(_ delta: Int) {
        let count = visible.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }

    func togglePinSelected() {
        guard let item = selectedItem else { return }
        store.togglePin(item.id)
        objectWillChange.send()
    }

    func deleteSelected() {
        guard let item = selectedItem else { return }
        store.delete(item.id)
        selection = min(selection, max(visible.count - 1, 0))
        objectWillChange.send()
    }

    /// Downsampled once per HUD session; the full image is never decoded for the list.
    func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard let url = store.imageURL(item) else { return nil }
        if let cached = thumbnails.object(forKey: url.path as NSString) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 360,
              ] as CFDictionary) else { return nil }
        let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnails.setObject(thumbnail, forKey: url.path as NSString)
        return thumbnail
    }
}
