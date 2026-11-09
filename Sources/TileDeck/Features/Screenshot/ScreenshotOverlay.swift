import AppKit
import Combine
import SwiftUI

/// One display's frozen picture, with the selection, drawings and toolbar on top.
@MainActor
final class ScreenshotOverlay: NSPanel {
    struct Actions {
        let mayStartSelection: (ScreenshotOverlay) -> Bool
        let selectionStarted: (ScreenshotOverlay) -> Void
        let copy: () -> Void
        let save: () -> Void
        let undo: () -> Void
        let redo: () -> Void
        let close: () -> Void
    }

    /// Above the menu bar and the Dock.
    static let level = NSWindow.Level.screenSaver

    private let canvas: ScreenshotCanvas

    init(screen: NSScreen, image: CGImage, palette: ScreenshotPalette, actions: Actions) {
        let bounds = CGRect(origin: .zero, size: screen.frame.size)
        canvas = ScreenshotCanvas(frame: bounds, image: image, scale: screen.backingScaleFactor, palette: palette)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        isOpaque = true
        hasShadow = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none

        let toolbar = FirstClickHostingView(rootView: ScreenshotToolbar(palette: palette, actions: actions))
        toolbar.frame.size = toolbar.fittingSize
        toolbar.isHidden = true
        toolbar.wantsLayer = true
        if let layer = toolbar.layer {
            layer.masksToBounds = false
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.5
            layer.shadowRadius = 14
            layer.shadowOffset = CGSize(width: 0, height: -4)
            layer.shadowPath = CGPath(roundedRect: toolbar.bounds, cornerWidth: ScreenshotToolbar.cornerRadius,
                                      cornerHeight: ScreenshotToolbar.cornerRadius, transform: nil)
        }

        let hint = PassThroughHostingView(rootView: ScreenshotHint())
        hint.frame.size = hint.fittingSize
        hint.setFrameOrigin(CGPoint(x: bounds.midX - hint.frame.width / 2, y: bounds.maxY - 96))

        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.addSubview(canvas)
        container.addSubview(hint)
        container.addSubview(toolbar)
        contentView = container
        setFrame(screen.frame, display: false)

        canvas.toolbar = toolbar
        canvas.hint = hint
        canvas.mayStartSelection = { [weak self] in
            guard let self else { return false }
            return actions.mayStartSelection(self)
        }
        canvas.selectionStarted = { [weak self] in
            guard let self else { return }
            actions.selectionStarted(self)
        }
    }

    override var canBecomeKey: Bool { true }

    /// Keeps the panel over the menu bar instead of being pushed below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    var hasSelection: Bool { canvas.hasSelection }
    var hasMarks: Bool { canvas.hasMarks }
    var isEditingText: Bool { canvas.isEditingText }
    var hasSelectedText: Bool { canvas.hasSelectedText }
    var isComposingText: Bool { canvas.isComposingText }

    func clearSelection() { canvas.clearSelection() }
    func commitText() { canvas.commitText() }
    func cancelText() { canvas.cancelText() }
    func undo() { canvas.undo() }
    func redo() { canvas.redo() }
    func selectedImage() -> (image: CGImage, scale: CGFloat)? { canvas.selectedImage() }
}

/// Hosts its own layers: the picture never redraws, and a change only updates
/// a few shapes, so dragging and drawing stay smooth on large displays.
@MainActor
private final class ScreenshotCanvas: NSView, NSTextFieldDelegate {
    private enum Drag {
        case creating(anchor: CGPoint)
        case moving(start: CGPoint, original: CGRect)
        case resizing(edges: ScreenshotGeometry.Edges, original: CGRect)
        case drawing
    }

    private static let grabTolerance: CGFloat = 7
    private static let handleSize: CGFloat = 9
    private static let textPadding: CGFloat = 2
    private static let minimumTextWidth: CGFloat = 60

    var toolbar: NSView?
    var hint: NSView?
    var mayStartSelection: (() -> Bool)?
    var selectionStarted: (() -> Void)?

    private let image: CGImage
    private let scale: CGFloat
    private let palette: ScreenshotPalette
    private var toolChange: AnyCancellable?

    private var selection: CGRect?
    private var drag: Drag?
    private var marks: [ScreenshotMark] = []
    private var undone: [ScreenshotMark] = []
    private var draft: ScreenshotMark?
    private var textField: NSTextField?
    private var textColor = NSColor.white
    /// Where the text box's top edge stays while it grows downwards.
    private var textTop: CGFloat = 0

    private let dim = CAShapeLayer()
    private let marksRoot = CALayer()
    private let marksMask = CAShapeLayer()
    private let committed = CALayer()
    private let draftRoot = CALayer()
    private let guides = CAShapeLayer()
    private let outlineShade = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let handles = CAShapeLayer()
    private let badge = CALayer()
    private let badgeText = CATextLayer()

    init(frame: CGRect, image: CGImage, scale: CGFloat, palette: ScreenshotPalette) {
        self.image = image
        self.scale = scale
        self.palette = palette
        super.init(frame: frame)

        let root = CALayer()
        root.frame = bounds
        layer = root
        wantsLayer = true

        let picture = CALayer()
        picture.frame = bounds
        picture.contents = image
        picture.contentsGravity = .resize
        root.addSublayer(picture)

        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.5).cgColor

        marksRoot.mask = marksMask
        marksRoot.addSublayer(committed)
        marksRoot.addSublayer(draftRoot)

        guides.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        guides.lineWidth = 1
        guides.lineDashPattern = [4, 4]

        outlineShade.fillColor = nil
        outlineShade.strokeColor = NSColor.black.withAlphaComponent(0.3).cgColor
        outlineShade.lineWidth = 3

        outline.fillColor = nil
        outline.strokeColor = NSColor.white.cgColor
        outline.lineWidth = 1.5

        handles.fillColor = NSColor.white.cgColor
        handles.strokeColor = NSColor.controlAccentColor.cgColor
        handles.lineWidth = 1.5

        for shape in [dim, marksRoot, marksMask, committed, draftRoot, guides, outlineShade, outline, handles] {
            shape.frame = bounds
        }
        for shape in [dim, marksRoot, guides, outlineShade, outline, handles] { root.addSublayer(shape) }

        badge.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        badge.cornerRadius = 6
        badgeText.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        badgeText.fontSize = 11
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.alignmentMode = .center
        badgeText.contentsScale = scale
        badge.addSublayer(badgeText)
        root.addSublayer(badge)

        // The screen darkens softly, so the freeze reads as a mode and not a glitch.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.12
        dim.add(fade, forKey: "fade")

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        toolChange = palette.$tool.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.commitText()
            self?.render()
        }
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var hasSelection: Bool { selection != nil }
    var hasMarks: Bool { !marks.isEmpty }
    var isEditingText: Bool { textField != nil }
    var hasSelectedText: Bool { (textField?.currentEditor()?.selectedRange.length ?? 0) > 0 }
    var isComposingText: Bool { (textField?.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    // MARK: Output

    func clearSelection() {
        cancelText()
        selection = nil
        drag = nil
        marks = []
        undone = []
        marksChanged()
        render()
    }

    func selectedImage() -> (image: CGImage, scale: CGFloat)? {
        guard let selection else { return nil }
        let pixels = ScreenshotGeometry.pixelRect(of: selection, in: bounds.size, imageWidth: image.width, imageHeight: image.height)
        guard let cropped = image.cropping(to: pixels) else { return nil }
        guard !marks.isEmpty else { return (cropped, scale) }

        let space = cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else { return (cropped, scale) }
        let size = CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height)
        context.draw(cropped, in: size)
        context.scaleBy(x: size.width / selection.width, y: size.height / selection.height)
        context.translateBy(x: -selection.minX, y: -selection.minY)
        marks.forEach { $0.draw(in: context) }
        return (context.makeImage() ?? cropped, scale)
    }

    // MARK: Undo

    func undo() {
        guard let mark = marks.popLast() else { return }
        undone.append(mark)
        marksChanged()
    }

    func redo() {
        guard let mark = undone.popLast() else { return }
        marks.append(mark)
        marksChanged()
    }

    private func add(_ mark: ScreenshotMark) {
        marks.append(mark)
        undone = []
        marksChanged()
    }

    private func marksChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        committed.sublayers = marks.map { $0.makeLayer(scale: scale) }
        CATransaction.commit()
        palette.canUndo = !marks.isEmpty
        palette.canRedo = !undone.isEmpty
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        let font = ScreenshotMark.font(forWidth: palette.width)
        textColor = palette.color
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = textColor
        field.delegate = self
        field.usesSingleLineMode = false
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.wantsLayer = true
        field.layer?.borderColor = NSColor.white.withAlphaComponent(0.7).cgColor
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 3
        let height = ceil(font.ascender - font.descender + font.leading) + 4
        // A click near the right edge starts further left, so there's room to type.
        let x = selection.map { max($0.minX, min(point.x - Self.textPadding, $0.maxX - Self.minimumTextWidth)) } ?? point.x
        textTop = point.y + height / 2
        field.frame = CGRect(x: x, y: point.y - height / 2, width: Self.minimumTextWidth, height: height)
        superview?.addSubview(field, positioned: .below, relativeTo: toolbar)
        window?.makeKey()
        window?.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.insertionPointColor = textColor
        textField = field
    }

    /// How wide text starting at this box may get before it has to wrap.
    private func textWidthLimit(for field: NSTextField) -> CGFloat {
        guard let selection else { return bounds.maxX - field.frame.minX }
        return max(selection.maxX - field.frame.minX - Self.textPadding * 2, 20)
    }

    private func attributed(_ string: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: textColor])
    }

    /// Grows with what's typed, wraps at the selection's right edge and stays inside it.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = textField, let font = field.font else { return }
        // The field editor's text includes what an input method is still composing.
        let string = (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
        let limit = textWidthLimit(for: field)
        let size = ScreenshotMark.textSize(attributed(string.isEmpty ? " " : string, font: font), maxWidth: limit)
        let padded = Self.textPadding * 2
        let width = min(max(Self.minimumTextWidth, size.width + padded + 8), limit + padded)
        let height = max(size.height + 4, field.frame.height > 0 ? ceil(font.ascender - font.descender + font.leading) + 4 : 0)
        let bottom = max(textTop - height, selection?.minY ?? bounds.minY)
        field.frame = CGRect(x: field.frame.minX, y: bottom, width: width, height: height)
    }

    func commitText() {
        guard let field = textField else { return }
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let frame = field.frame
        let font = field.font ?? ScreenshotMark.font(forWidth: palette.width)
        endText(field)
        guard !string.isEmpty else { return }
        let text = attributed(string, font: font)
        let limit = selection.map { max($0.maxX - frame.minX - Self.textPadding * 2, 20) } ?? bounds.maxX - frame.minX
        let height = ScreenshotMark.textSize(text, maxWidth: limit).height + 1
        add(ScreenshotMark(text: text, color: textColor,
                           box: CGRect(x: frame.minX + Self.textPadding, y: frame.midY - height / 2, width: limit, height: height)))
    }

    func cancelText() {
        if let field = textField { endText(field) }
    }

    private func endText(_ field: NSTextField) {
        textField = nil
        field.delegate = nil
        field.abortEditing()
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
    }

    // MARK: Mouse

    private func location(of event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        let point = location(of: event)
        if isEditingText {
            commitText()
            return
        }
        window?.makeKey()
        if let tool = palette.tool, let selection {
            guard selection.contains(point) else { return }
            if tool == .text {
                beginText(at: point)
            } else {
                draft = ScreenshotMark(tool: tool, color: palette.color, width: palette.width, start: point)
                drag = .drawing
            }
            return
        }
        if let selection {
            let edges = ScreenshotGeometry.edges(at: point, of: selection, tolerance: Self.grabTolerance)
            if !edges.isEmpty {
                drag = .resizing(edges: edges, original: selection)
            } else if selection.contains(point) {
                drag = .moving(start: point, original: selection)
                NSCursor.closedHand.set()
            } else {
                begin(at: point)
            }
        } else {
            begin(at: point)
        }
        render()
    }

    /// Drawings would lose their place, so a selection that has any stays put.
    private func begin(at point: CGPoint) {
        guard marks.isEmpty, mayStartSelection?() ?? true else { return }
        selectionStarted?()
        selection = nil
        drag = .creating(anchor: point)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = location(of: event)
        switch drag {
        case .creating(let anchor):
            selection = ScreenshotGeometry.selection(from: anchor, to: point, in: bounds)
        case .moving(let start, let original):
            selection = ScreenshotGeometry.moved(original, by: CGVector(dx: point.x - start.x, dy: point.y - start.y), in: bounds)
        case .resizing(let edges, let original):
            selection = ScreenshotGeometry.resized(original, edges: edges, to: point, in: bounds)
        case .drawing:
            draft?.extend(to: point)
            showDraft()
            return
        case nil:
            return
        }
        render()
    }

    private func showDraft() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        draftRoot.sublayers = draft.map { [$0.makeLayer(scale: scale)] }
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        if case .drawing = drag, let finished = draft, finished.isVisible { add(finished) }
        draft = nil
        showDraft()
        drag = nil
        if let selection, min(selection.width, selection.height) < ScreenshotGeometry.minimumSide { self.selection = nil }
        render()
        updateCursor(at: location(of: event))
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(at: location(of: event)) }
    override func mouseEntered(with event: NSEvent) { updateCursor(at: location(of: event)) }

    override func mouseExited(with event: NSEvent) {
        guides.path = nil
    }

    private func updateCursor(at point: CGPoint) {
        showGuides(at: point)
        guard drag == nil else { return }
        if let toolbar, !toolbar.isHidden, toolbar.frame.contains(point) {
            NSCursor.arrow.set()
            return
        }
        guard let selection else {
            NSCursor.crosshair.set()
            return
        }
        if let tool = palette.tool {
            (selection.contains(point) ? (tool == .text ? NSCursor.iBeam : NSCursor.crosshair) : NSCursor.arrow).set()
            return
        }
        switch ScreenshotGeometry.edges(at: point, of: selection, tolerance: Self.grabTolerance) {
        case [.left], [.right]: NSCursor.resizeLeftRight.set()
        case [.top], [.bottom]: NSCursor.resizeUpDown.set()
        case []: (selection.contains(point) ? NSCursor.openHand : NSCursor.crosshair).set()
        default: NSCursor.crosshair.set()
        }
    }

    /// Thin lines through the cursor help line up the first corner.
    private func showGuides(at point: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard selection == nil else {
            guides.path = nil
            return
        }
        let lines = CGMutablePath()
        lines.addLines(between: [CGPoint(x: point.x, y: bounds.minY), CGPoint(x: point.x, y: bounds.maxY)])
        lines.addLines(between: [CGPoint(x: bounds.minX, y: point.y), CGPoint(x: bounds.maxX, y: point.y)])
        guides.path = lines
    }

    // MARK: Drawing

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let shade = CGMutablePath()
        shade.addRect(bounds)
        if let selection { shade.addRect(selection) }
        dim.path = shade
        hint?.isHidden = selection != nil

        guard let selection else {
            marksMask.path = nil
            outline.path = nil
            outlineShade.path = nil
            handles.path = nil
            badge.isHidden = true
            toolbar?.isHidden = true
            return
        }

        guides.path = nil
        marksMask.path = CGPath(rect: selection, transform: nil)
        let frame = CGPath(rect: selection.insetBy(dx: -0.75, dy: -0.75), transform: nil)
        outline.path = frame
        outlineShade.path = frame

        if palette.tool == nil {
            let dots = CGMutablePath()
            for x in [selection.minX, selection.midX, selection.maxX] {
                for y in [selection.minY, selection.midY, selection.maxY] where x != selection.midX || y != selection.midY {
                    dots.addEllipse(in: CGRect(x: x - Self.handleSize / 2, y: y - Self.handleSize / 2, width: Self.handleSize, height: Self.handleSize))
                }
            }
            handles.path = dots
        } else {
            handles.path = nil
        }

        let pixels = ScreenshotGeometry.pixelRect(of: selection, in: bounds.size, imageWidth: image.width, imageHeight: image.height)
        placeBadge("\(Int(pixels.width)) × \(Int(pixels.height))", over: selection)

        if let toolbar {
            var adjusting = drag != nil
            if case .drawing = drag { adjusting = false }
            toolbar.isHidden = adjusting
            toolbar.setFrameOrigin(ScreenshotGeometry.toolbarOrigin(for: selection, toolbar: toolbar.frame.size, in: bounds))
        }
    }

    /// Above the selection's top-left corner, or just inside it when there's no room.
    private func placeBadge(_ text: String, over selection: CGRect) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let size = CGSize(width: ceil((text as NSString).size(withAttributes: [.font: font]).width) + 16, height: 20)
        let above = selection.maxY + 8
        let y = above + size.height <= bounds.maxY ? above : selection.maxY - size.height - 8
        badge.isHidden = false
        badge.frame = CGRect(x: min(selection.minX, bounds.maxX - size.width), y: y, width: size.width, height: size.height)
        badgeText.frame = CGRect(x: 0, y: 0, width: size.width, height: 17)
        badgeText.string = text
    }
}

/// Shown over the picture, but never in the way of the first drag.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct ScreenshotHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "viewfinder").font(.system(size: 13, weight: .semibold))
            Text("Kéo để chọn vùng cần chụp").font(.system(size: 12.5, weight: .semibold))
            Text("Esc").font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.78), in: Capsule())
        .fixedSize()
    }
}

struct ScreenshotToolbar: View {
    static let cornerRadius: CGFloat = 13

    @ObservedObject var palette: ScreenshotPalette
    let actions: ScreenshotOverlay.Actions

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ToolbarIcon(icon: "cursorarrow", help: "Di chuyển vùng chọn (V)", isSelected: palette.tool == nil) { palette.tool = nil }
                ForEach(ScreenshotDrawTool.allCases) { tool in
                    ToolbarIcon(icon: tool.icon, help: tool.title, isSelected: palette.tool == tool) {
                        palette.tool = palette.tool == tool ? nil : tool
                    }
                }
            }
            separator
            HStack(spacing: 3) {
                ForEach(ScreenshotPalette.colors.indices, id: \.self) { index in
                    swatch(index)
                }
            }
            separator
            HStack(spacing: 1) {
                ForEach(ScreenshotPalette.widths.indices, id: \.self) { index in
                    thickness(index)
                }
            }
            separator
            HStack(spacing: 2) {
                ToolbarIcon(icon: "arrow.uturn.backward", help: "Hoàn tác (⌘Z)", isEnabled: palette.canUndo, action: actions.undo)
                ToolbarIcon(icon: "arrow.uturn.forward", help: "Làm lại (⇧⌘Z)", isEnabled: palette.canRedo, action: actions.redo)
            }
            separator
            HStack(spacing: 4) {
                TextAction(icon: "doc.on.doc", title: "Sao chép", help: "Sao chép vào clipboard (⌘C)", isPrimary: true, action: actions.copy)
                TextAction(icon: "square.and.arrow.down", title: "Lưu", help: "Lưu thành file PNG (⌘S)", isPrimary: false, action: actions.save)
                ToolbarIcon(icon: "xmark", help: "Thoát (Esc)", action: actions.close)
            }
        }
        .padding(6)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(.white.opacity(0.14)))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 18)
    }

    private func swatch(_ index: Int) -> some View {
        Button {
            palette.colorIndex = index
        } label: {
            Circle()
                .fill(Color(nsColor: ScreenshotPalette.colors[index]))
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.5))
                .frame(width: 14, height: 14)
                .padding(3)
                .overlay(Circle().strokeBorder(.white, lineWidth: palette.colorIndex == index ? 1.5 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func thickness(_ index: Int) -> some View {
        Button {
            palette.widthIndex = index
        } label: {
            Circle()
                .fill(.white)
                .frame(width: [4, 7, 11][index], height: [4, 7, 11][index])
                .frame(width: 24, height: 28)
                .background(.white.opacity(palette.widthIndex == index ? 0.18 : 0), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(["Mảnh", "Vừa", "Dày"][index])
    }
}

private struct ToolbarIcon: View {
    let icon: String
    let help: String
    var isSelected = false
    var isEnabled = true
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(background, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .help(help)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected { return .accentColor }
        return isHovered && isEnabled ? .white.opacity(0.14) : .clear
    }
}

private struct TextAction: View {
    let icon: String
    let title: String
    let help: String
    let isPrimary: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isPrimary { return Color.accentColor.opacity(isHovered ? 0.85 : 1) }
        return .white.opacity(isHovered ? 0.2 : 0.12)
    }
}
