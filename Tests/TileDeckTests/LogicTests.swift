import SwiftUI
import Vision
import XCTest
@testable import TileDeck

/// Pure logic: no hardware, no system state touched.
final class LogicTests: XCTestCase {
    // MARK: Screenshots

    func testScreenshotSelectionStaysOnScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let dragged = ScreenshotGeometry.selection(from: CGPoint(x: 900, y: 500), to: CGPoint(x: 1200, y: 100), in: bounds)
        XCTAssertEqual(dragged, CGRect(x: 900, y: 100, width: 100, height: 400))

        let selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(ScreenshotGeometry.moved(selection, by: CGVector(dx: -500, dy: 900), in: bounds), CGRect(x: 0, y: 500, width: 200, height: 100))
        XCTAssertEqual(ScreenshotGeometry.resized(selection, edges: .right, to: CGPoint(x: 50, y: 0), in: bounds),
                       CGRect(x: 50, y: 100, width: 50, height: 100), "dragging past the opposite edge flips")
    }

    func testScreenshotGrabbingEdges() {
        let selection = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(ScreenshotGeometry.edges(at: CGPoint(x: 100, y: 200), of: selection, tolerance: 6), [.left, .top])
        XCTAssertEqual(ScreenshotGeometry.edges(at: CGPoint(x: 200, y: 96), of: selection, tolerance: 6), [.bottom])
        XCTAssertEqual(ScreenshotGeometry.edges(at: CGPoint(x: 200, y: 150), of: selection, tolerance: 6), [])
        XCTAssertEqual(ScreenshotGeometry.edges(at: CGPoint(x: 50, y: 50), of: selection, tolerance: 6), [])
    }

    func testScreenshotCropsTheRightPixels() {
        let size = CGSize(width: 1000, height: 600)
        let selection = CGRect(x: 100, y: 400, width: 200, height: 150)
        XCTAssertEqual(ScreenshotGeometry.pixelRect(of: selection, in: size, imageWidth: 2000, imageHeight: 1200),
                       CGRect(x: 200, y: 100, width: 400, height: 300), "image pixels count from the top left at 2x")
    }

    func testScreenshotToolbarAvoidsScreenEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let toolbar = CGSize(width: 200, height: 30)
        XCTAssertEqual(ScreenshotGeometry.toolbarOrigin(for: CGRect(x: 100, y: 200, width: 400, height: 100), toolbar: toolbar, in: bounds),
                       CGPoint(x: 300, y: 162))
        XCTAssertEqual(ScreenshotGeometry.toolbarOrigin(for: CGRect(x: 100, y: 0, width: 400, height: 100), toolbar: toolbar, in: bounds),
                       CGPoint(x: 300, y: 108), "no room below, so it goes above")
        XCTAssertEqual(ScreenshotGeometry.toolbarOrigin(for: bounds, toolbar: toolbar, in: bounds),
                       CGPoint(x: 792, y: 8), "a full-screen selection keeps it inside")
    }

    func testScreenshotClickWithoutDragDrawsNothing() {
        var line = ScreenshotMark(tool: .line, color: .red, width: 4, start: CGPoint(x: 10, y: 10))
        XCTAssertFalse(line.isVisible)
        line.extend(to: CGPoint(x: 40, y: 10))
        XCTAssertTrue(line.isVisible)
        XCTAssertEqual(line.points.count, 2, "straight tools only keep their two ends")

        var pen = ScreenshotMark(tool: .pen, color: .red, width: 4, start: CGPoint(x: 10, y: 10))
        pen.extend(to: CGPoint(x: 20, y: 10))
        pen.extend(to: CGPoint(x: 20, y: 20))
        XCTAssertGreaterThan(pen.points.count, 2, "freehand tools keep the whole stroke")
        XCTAssertNotNil(pen.path)
    }

    func testScreenshotLongTextWrapsToTheBox() {
        let font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        let text = NSAttributedString(string: String(repeating: "chữ dài quá ", count: 12), attributes: [.font: font])
        let oneLine = ScreenshotMark.textSize(NSAttributedString(string: "chữ", attributes: [.font: font]), maxWidth: 300)
        let wrapped = ScreenshotMark.textSize(text, maxWidth: 300)
        XCTAssertLessThanOrEqual(wrapped.width, 300)
        XCTAssertGreaterThan(wrapped.height, oneLine.height * 2, "long text takes several lines")
    }

    // MARK: Updates

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.3"), "parts compare as numbers, not text")
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.99.99"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.1", than: "0.1"), "a missing part counts as 0")
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.1", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "0.10.0"))
        XCTAssertEqual(UpdateChecker.clean(" v1.2.3"), "1.2.3")
    }

    func testOnlyThisRepositorysReleasesAreDownloaded() {
        let trusted = URL(string: "https://github.com/dungng2808/TileDeck/releases/download/v0.1.3/TileDeck-0.1.3.zip")!
        XCTAssertTrue(AppInstaller.isTrustedPackage(trusted))
        for untrusted in [
            "http://github.com/dungng2808/TileDeck/releases/download/v0.1.3/TileDeck-0.1.3.zip",
            "https://github.com/someone/TileDeck/releases/download/v0.1.3/TileDeck-0.1.3.zip",
            "https://example.com/dungng2808/TileDeck/releases/download/v0.1.3/TileDeck-0.1.3.zip",
            "https://github.com.example.com/dungng2808/TileDeck/releases/download/v0.1.3/TileDeck-0.1.3.zip",
        ] {
            XCTAssertFalse(AppInstaller.isTrustedPackage(URL(string: untrusted)!), untrusted)
        }
    }

    // MARK: Clipboard

    func testClipboardKinds() {
        XCTAssertEqual(ClipboardStore.kind(of: "#3B82F6"), .color)
        XCTAssertEqual(ClipboardStore.kind(of: "#fff"), .color)
        XCTAssertEqual(ClipboardStore.kind(of: "#11223344"), .color)
        XCTAssertEqual(ClipboardStore.kind(of: "https://github.com/dungng2808/TileDeck"), .link)
        XCTAssertEqual(ClipboardStore.kind(of: "  http://example.com/a?b=c  "), .link)
        XCTAssertEqual(ClipboardStore.kind(of: "Xin chào TileDeck"), .text)
        XCTAssertEqual(ClipboardStore.kind(of: "#12345"), .text, "five hex digits is not a colour")
        XCTAssertEqual(ClipboardStore.kind(of: "https://a.com\nhttps://b.com"), .text, "several lines are text")
        XCTAssertEqual(ClipboardStore.kind(of: "ftp://example.com"), .text)
    }

    func testHexColours() {
        XCTAssertNotNil(Color(hex: "#3B82F6"))
        XCTAssertNotNil(Color(hex: "#fff"))
        XCTAssertNotNil(Color(hex: "#11223344"))
        XCTAssertNil(Color(hex: "3B82F6"), "needs the leading #")
        XCTAssertNil(Color(hex: "#GGHHII"))
    }

    // MARK: DDC

    func testDDCChecksumMatchesARealMonitorReply() {
        // The brightness-read request TileDeck sends (Get VCP 0x10).
        XCTAssertEqual(DDCService.checksum(0x6E, [0x82, 0x01, 0x10][...]), 0xFD)
        // A reply captured from an MSI MP251: current 60, maximum 100, last byte is the checksum.
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x3C, 0xFC]
        XCTAssertEqual(DDCService.checksum(0x50, reply.dropLast()), reply.last)
    }

    // MARK: Fans

    func testSensorChoicesAndKeyGroups() {
        XCTAssertEqual(FanMonitor.sensorChoices.first?.id, "cpu")
        let keys = ["Tp01", "Tp1i", "Te05", "Tg1U", "TPD0", "TB0T", "TW0P", "Ts0P", "TZ01"]
        XCTAssertEqual(Set(FanMonitor.keys(for: "cpu", in: keys)), ["Tp01", "Tp1i", "Te05"], "hottest CPU covers both core types")
        XCTAssertEqual(FanMonitor.keys(for: "gpu", in: keys), ["Tg1U"])
        XCTAssertEqual(FanMonitor.keys(for: "pmu", in: keys), ["TPD0"])
        XCTAssertEqual(FanMonitor.keys(for: "battery", in: keys), ["TB0T"])
        XCTAssertEqual(FanMonitor.keys(for: "trackpad", in: keys), ["Ts0P"])
        XCTAssertTrue(FanMonitor.keys(for: "nonexistent", in: keys).isEmpty)
    }

    // MARK: Window tiling

    @MainActor
    func testTilingTargetsStayInsideTheScreen() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("no screen") }
        let area = screen.visibleFrame
        let window = CGRect(x: area.midX - 300, y: area.midY - 200, width: 600, height: 400)

        let left = try XCTUnwrap(WindowTiler.target(for: .leftHalf, windowFrame: window))
        XCTAssertEqual(left.minX, area.minX, accuracy: 1)
        XCTAssertEqual(left.width, area.width / 2, accuracy: 1)
        XCTAssertEqual(left.height, area.height, accuracy: 1)

        let right = try XCTUnwrap(WindowTiler.target(for: .rightHalf, windowFrame: window))
        XCTAssertEqual(right.maxX, area.maxX, accuracy: 1)

        XCTAssertEqual(WindowTiler.target(for: .maximize, windowFrame: window), area)

        let centred = try XCTUnwrap(WindowTiler.target(for: .center, windowFrame: window))
        XCTAssertEqual(centred.size, window.size, "centring keeps the size")
        XCTAssertEqual(centred.midX, area.midX, accuracy: 1)

        if NSScreen.screens.count > 1 {
            let moved = try XCTUnwrap(WindowTiler.target(for: .nextDisplay, windowFrame: window))
            XCTAssertFalse(area.contains(CGPoint(x: moved.midX, y: moved.midY)), "next display leaves this screen")
            XCTAssertTrue(NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(moved) })
        } else {
            XCTAssertNil(WindowTiler.target(for: .nextDisplay, windowFrame: window))
        }
    }

    // MARK: Donate

    /// The bundled VietQR must pay TileDeck's account at TPBank (NAPAS BIN 970423).
    func testDonateQRPaysTheRightAccount() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Donate.png")
        let image = try XCTUnwrap(NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let payload = try XCTUnwrap(request.results?.first?.payloadStringValue)
        XCTAssertTrue(payload.hasPrefix("000201"), "an EMVCo payment code")
        XCTAssertTrue(payload.contains("A000000727"), "NAPAS VietQR")
        XCTAssertTrue(payload.contains("0006970423"), "TPBank")
        XCTAssertTrue(payload.contains("01\(String(format: "%02d", DonateView.accountNumber.count))\(DonateView.accountNumber)"))
    }
}
