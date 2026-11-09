import AppKit
import Carbon.HIToolbox
import SwiftUI

enum ScreenshotDrawTool: CaseIterable, Identifiable {
    case pen, line, arrow, rectangle, ellipse, marker, text

    var id: Self { self }

    var icon: String {
        switch self {
        case .pen: "pencil.tip"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .marker: "highlighter"
        case .text: "textformat"
        }
    }

    var title: String {
        switch self {
        case .pen: "Bút (P)"
        case .line: "Đường thẳng (L)"
        case .arrow: "Mũi tên (A)"
        case .rectangle: "Hình chữ nhật (R)"
        case .ellipse: "Hình tròn (O)"
        case .marker: "Bút dạ (M)"
        case .text: "Chữ (T)"
        }
    }

    var keyCode: Int {
        switch self {
        case .pen: kVK_ANSI_P
        case .line: kVK_ANSI_L
        case .arrow: kVK_ANSI_A
        case .rectangle: kVK_ANSI_R
        case .ellipse: kVK_ANSI_O
        case .marker: kVK_ANSI_M
        case .text: kVK_ANSI_T
        }
    }
}

/// The toolbar's state. Colour and thickness are kept between screenshots.
@MainActor
final class ScreenshotPalette: ObservableObject {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1),
        NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1),
        NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1),
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
    ]
    static let widths: [CGFloat] = [2, 4, 8]

    /// nil is the move tool: drags adjust the selection instead of drawing.
    @Published var tool: ScreenshotDrawTool?
    @Published var colorIndex = 0
    @Published var widthIndex = 1
    @Published var canUndo = false
    @Published var canRedo = false

    var color: NSColor { Self.colors[colorIndex] }
    var width: CGFloat { Self.widths[widthIndex] }
}

/// One thing drawn on the screenshot, in overlay coordinates. The on-screen
/// layer and the exported image are both made from `path` and `text`, so what
/// is saved is exactly what was drawn.
struct ScreenshotMark {
    let tool: ScreenshotDrawTool
    let color: NSColor
    let width: CGFloat
    var points: [CGPoint]
    var text: NSAttributedString?
    var textBox = CGRect.zero

    init(tool: ScreenshotDrawTool, color: NSColor, width: CGFloat, start: CGPoint) {
        self.tool = tool
        self.color = color
        self.width = width
        points = [start, start]
    }

    /// `box` is as wide as the text may wrap to and as tall as the wrapped text.
    init(text: NSAttributedString, color: NSColor, box: CGRect) {
        tool = .text
        self.color = color
        width = 0
        points = [box.origin]
        self.text = text
        textBox = box
    }

    /// The size `text` takes when wrapped to `maxWidth`, rounded up to whole points.
    static func textSize(_ text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let measured = text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    static func font(forWidth width: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: 12 + width * 2.5, weight: .semibold)
    }

    private var isFreehand: Bool { tool == .pen || tool == .marker }
    private var isFilled: Bool { tool == .arrow }
    private var strokeWidth: CGFloat { tool == .marker ? width * 4 : width }
    private var paint: CGColor { (tool == .marker ? color.withAlphaComponent(0.45) : color).cgColor }

    mutating func extend(to point: CGPoint) {
        if isFreehand {
            if let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 1 { points.append(point) }
        } else {
            points[1] = point
        }
    }

    /// A click without a drag leaves nothing worth keeping.
    var isVisible: Bool {
        if isFreehand { return points.count > 2 }
        guard points.count == 2 else { return text != nil }
        return hypot(points[1].x - points[0].x, points[1].y - points[0].y) >= 2
    }

    var path: CGPath? {
        guard points.count >= 2 else { return nil }
        let start = points[0], end = points[points.count - 1]
        let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch tool {
        case .pen, .marker: return smoothPath
        case .line:
            let path = CGMutablePath()
            path.move(to: start)
            path.addLine(to: end)
            return path
        case .arrow: return arrowPath(from: start, to: end)
        case .rectangle: return CGPath(rect: box, transform: nil)
        case .ellipse: return CGPath(ellipseIn: box, transform: nil)
        case .text: return nil
        }
    }

    /// Curves through the midpoints, so a fast stroke doesn't look like a polygon.
    private var smoothPath: CGPath {
        let path = CGMutablePath()
        path.move(to: points[0])
        for index in 1..<points.count {
            let previous = points[index - 1], point = points[index]
            path.addQuadCurve(to: CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2), control: previous)
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// One filled outline: a shaft that narrows towards the tail, and a swept-back head.
    private func arrowPath(from start: CGPoint, to end: CGPoint) -> CGPath {
        let length = max(hypot(end.x - start.x, end.y - start.y), 0.001)
        let ux = (end.x - start.x) / length, uy = (end.y - start.y) / length
        let head = min(length, max(width * 4.5, 14))
        let spread = head * 0.42, shaft = max(width / 2, 1)
        func at(along: CGFloat, across: CGFloat) -> CGPoint {
            CGPoint(x: start.x + ux * along - uy * across, y: start.y + uy * along + ux * across)
        }
        let neck = length - head * 0.72
        let path = CGMutablePath()
        path.addLines(between: [
            at(along: 0, across: shaft * 0.6), at(along: neck, across: shaft),
            at(along: length - head, across: spread), at(along: length, across: 0),
            at(along: length - head, across: -spread), at(along: neck, across: -shaft),
            at(along: 0, across: -shaft * 0.6),
        ])
        path.closeSubpath()
        return path
    }

    func draw(in context: CGContext) {
        if let text {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(in: textBox)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        guard let path else { return }
        context.saveGState()
        context.addPath(path)
        if isFilled {
            context.setFillColor(paint)
            context.fillPath()
        } else {
            context.setStrokeColor(paint)
            context.setLineWidth(strokeWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
        context.restoreGState()
    }

    func makeLayer(scale: CGFloat) -> CALayer {
        if let text {
            let image = NSImage(size: textBox.size, flipped: false) { [textBox] _ in
                text.draw(in: CGRect(origin: .zero, size: textBox.size))
                return true
            }
            let layer = CALayer()
            layer.frame = textBox
            layer.contentsScale = scale
            layer.contents = image.layerContents(forContentsScale: scale)
            return layer
        }
        let layer = CAShapeLayer()
        layer.path = path
        if isFilled {
            layer.fillColor = paint
        } else {
            layer.fillColor = nil
            layer.strokeColor = paint
            layer.lineWidth = strokeWidth
            layer.lineCap = .round
            layer.lineJoin = .round
        }
        return layer
    }
}
