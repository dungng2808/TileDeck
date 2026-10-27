import SwiftUI
import XCTest
@testable import TileDeck

/// Pure logic: no hardware, no system state touched.
final class LogicTests: XCTestCase {
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
}
