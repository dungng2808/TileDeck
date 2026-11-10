import AppKit

/// How the area to capture gets chosen.
enum ScreenCaptureMode: String, CaseIterable, Identifiable {
    case window, region, fullScreen

    var id: Self { self }

    var title: String {
        switch self {
        case .window: "Theo cửa sổ"
        case .region: "Tự kéo"
        case .fullScreen: "Toàn màn hình"
        }
    }

    var icon: String {
        switch self {
        case .window: "macwindow"
        case .region: "viewfinder"
        case .fullScreen: "display"
        }
    }
}

/// Shared by screenshots and recordings, and remembered between them.
@MainActor
final class ScreenCaptureOptions: ObservableObject {
    private static let modeKey = "screenCaptureMode"
    static let shared = ScreenCaptureOptions(
        mode: UserDefaults.standard.string(forKey: modeKey).flatMap(ScreenCaptureMode.init) ?? .region)

    @Published var mode: ScreenCaptureMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }

    init(mode: ScreenCaptureMode) {
        self.mode = mode
    }
}

/// A window that can be picked with one click, in overlay coordinates.
struct ScreenshotWindow: Equatable {
    let id: CGWindowID
    let frame: CGRect
}

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

    /// Window bounds count from the primary display's top left; overlays from their own bottom left.
    static func overlayFrame(ofWindowBounds bounds: CGRect, screenFrame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX - screenFrame.minX, y: primaryScreenHeight - bounds.maxY - screenFrame.minY,
               width: bounds.width, height: bounds.height)
    }

    /// The apps' windows showing on a display, frontmost first.
    @MainActor
    static func windows(on screen: NSScreen) -> [ScreenshotWindow] {
        guard let primary = NSScreen.screens.first else { return [] }
        let area = CGRect(origin: .zero, size: screen.frame.size)
        let me = getpid()
        let apps = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != me, apps.contains(pid),
                  let raw = entry[kCGWindowBounds as String], let bounds = CGRect(dictionaryRepresentation: raw as! CFDictionary) else { return nil }
            let frame = overlayFrame(ofWindowBounds: bounds, screenFrame: screen.frame, primaryScreenHeight: primary.frame.height).intersection(area)
            guard !frame.isNull, min(frame.width, frame.height) >= 60 else { return nil }
            return ScreenshotWindow(id: id, frame: frame)
        }
    }

    /// The selection as ScreenCaptureKit wants it: measured from the top left.
    static func topLeftRegion(of selection: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(x: selection.minX, y: screenHeight - selection.maxY, width: selection.width, height: selection.height)
    }

    /// Video pixels for a region: the encoder needs even sizes and tops out at 4096.
    static func recordingSize(of region: CGSize, scale: CGFloat) -> (width: Int, height: Int) {
        let shrink = min(1, 4096 / max(region.width * scale, region.height * scale, 1))
        return (max(Int(region.width * scale * shrink) & ~1, 2), max(Int(region.height * scale * shrink) & ~1, 2))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%02d:%02d", minutes, rest)
    }

    static func fileName(for date: Date, prefix: String = "Ảnh chụp", extension fileExtension: String = "png") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date)).\(fileExtension)"
    }
}
