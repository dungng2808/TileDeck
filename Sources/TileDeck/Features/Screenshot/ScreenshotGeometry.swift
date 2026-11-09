import AppKit

/// The selection maths, in the bottom-left-origin coordinates of an overlay.
enum ScreenshotGeometry {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4)
        static let top = Edges(rawValue: 8)
    }

    /// Shorter drags than this are stray clicks, not selections.
    static let minimumSide: CGFloat = 3

    private static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    private static func rect(minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) -> CGRect {
        CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    static func selection(from anchor: CGPoint, to point: CGPoint, in bounds: CGRect) -> CGRect {
        let end = clamp(point, to: bounds)
        return rect(minX: anchor.x, maxX: end.x, minY: anchor.y, maxY: end.y)
    }

    static func moved(_ selection: CGRect, by delta: CGVector, in bounds: CGRect) -> CGRect {
        CGRect(x: min(max(selection.minX + delta.dx, bounds.minX), bounds.maxX - selection.width),
               y: min(max(selection.minY + delta.dy, bounds.minY), bounds.maxY - selection.height),
               width: selection.width, height: selection.height)
    }

    /// Dragging an edge past the opposite one flips the selection instead of collapsing it.
    static func resized(_ selection: CGRect, edges: Edges, to point: CGPoint, in bounds: CGRect) -> CGRect {
        let end = clamp(point, to: bounds)
        return rect(minX: edges.contains(.left) ? end.x : selection.minX,
                    maxX: edges.contains(.right) ? end.x : selection.maxX,
                    minY: edges.contains(.bottom) ? end.y : selection.minY,
                    maxY: edges.contains(.top) ? end.y : selection.maxY)
    }

    /// Which edges a point grabs; empty when it isn't near the outline.
    static func edges(at point: CGPoint, of selection: CGRect, tolerance: CGFloat) -> Edges {
        guard selection.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return [] }
        var edges: Edges = []
        if abs(point.x - selection.minX) <= tolerance { edges.insert(.left) }
        else if abs(point.x - selection.maxX) <= tolerance { edges.insert(.right) }
        if abs(point.y - selection.minY) <= tolerance { edges.insert(.bottom) }
        else if abs(point.y - selection.maxY) <= tolerance { edges.insert(.top) }
        return edges
    }

    /// The selection in the image's pixels, whose origin is at the top left.
    static func pixelRect(of selection: CGRect, in viewSize: CGSize, imageWidth: Int, imageHeight: Int) -> CGRect {
        let scaleX = CGFloat(imageWidth) / viewSize.width
        let scaleY = CGFloat(imageHeight) / viewSize.height
        return CGRect(x: (selection.minX * scaleX).rounded(),
                      y: ((viewSize.height - selection.maxY) * scaleY).rounded(),
                      width: (selection.width * scaleX).rounded(),
                      height: (selection.height * scaleY).rounded())
    }

    /// Under the selection's right edge; above it when there's no room below; inside it as a last resort.
    static func toolbarOrigin(for selection: CGRect, toolbar: CGSize, in bounds: CGRect) -> CGPoint {
        let gap: CGFloat = 8
        let x = min(max(selection.maxX - toolbar.width, bounds.minX + gap), bounds.maxX - toolbar.width - gap)
        if selection.minY - toolbar.height - gap >= bounds.minY { return CGPoint(x: x, y: selection.minY - toolbar.height - gap) }
        if selection.maxY + toolbar.height + gap <= bounds.maxY { return CGPoint(x: x, y: selection.maxY + gap) }
        return CGPoint(x: x, y: selection.minY + gap)
    }

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Ảnh chụp \(formatter.string(from: date)).png"
    }
}
