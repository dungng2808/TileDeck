import AppKit
import CoreAudio
import SwiftUI
import XCTest
@testable import TileDeck

/// Reads real hardware (SMC, displays, audio, battery) without changing
/// anything. Each test skips itself on a Mac that lacks the hardware.
final class HardwareTests: XCTestCase {
    func testSMCFansReadSensibleSpeeds() throws {
        let smc = try XCTUnwrap(SMC.Connection(), "AppleSMC should open without root")
        let fans = Int(smc.uint8("FNum") ?? 0)
        guard fans > 0 else { throw XCTSkip("this Mac has no fans") }
        for fan in 0..<fans {
            let minimum = try XCTUnwrap(smc.float("F\(fan)Mn"))
            let maximum = try XCTUnwrap(smc.float("F\(fan)Mx"))
            let current = try XCTUnwrap(smc.float("F\(fan)Ac"))
            XCTAssertGreaterThan(minimum, 300)
            XCTAssertGreaterThan(maximum, minimum)
            XCTAssertTrue((0...maximum * 1.2).contains(current), "fan \(fan) at \(current) rpm")
        }
    }

    func testSMCKeyTableHasTemperatures() throws {
        let smc = try XCTUnwrap(SMC.Connection())
        let keys = smc.allKeys()
        guard !keys.isEmpty else { throw XCTSkip("SMC key table unavailable") }
        let temperatures = keys.filter { $0.hasPrefix("T") }.compactMap { smc.float($0) }.filter { $0 > 10 && $0 < 130 }
        XCTAssertGreaterThan(temperatures.count, 10, "a Mac exposes dozens of temperature sensors")
    }

    @MainActor
    func testFanMonitorGroupsAndFullListAgree() async throws {
        let monitor = FanMonitor.shared
        monitor.start()
        defer { monitor.stop() }
        try await waitUntil { !monitor.groups.isEmpty }
        monitor.showsAllSensors = true
        defer { monitor.showsAllSensors = false }
        try await waitUntil { !monitor.sections.isEmpty }
        XCTAssertTrue(monitor.groups.allSatisfy { $0.average > 10 && $0.hottest >= $0.average - 0.01 })
        let keys = monitor.sections.flatMap(\.sensors).map(\.key)
        XCTAssertEqual(keys.count, Set(keys).count, "every sensor is listed once")
    }

    @MainActor
    func testDisplaysAreListed() {
        let displays = DisplayController.shared
        displays.refresh()
        XCTAssertEqual(displays.displays.filter { !$0.isDisabled }.count, NSScreen.screens.count)
        XCTAssertTrue(displays.displays.allSatisfy { (0...1).contains($0.brightness) })
    }

    @MainActor
    func testAudioDevicesAndApps() throws {
        let devices = AudioDevices.shared
        devices.start()
        defer { devices.stop() }
        spinRunLoop(until: { !devices.output.devices.isEmpty })
        guard !devices.output.devices.isEmpty else { throw XCTSkip("no audio output") }
        XCTAssertTrue(devices.output.devices.contains { $0.id == devices.output.current }, "the default output is in the list")
        XCTAssertFalse(devices.output.devices.contains { $0.uid.hasPrefix(AppVolume.aggregatePrefix) }, "TileDeck's own devices stay hidden")

        let apps = AppVolume.shared
        apps.refresh()
        spinRunLoop(for: 1)
        XCTAssertFalse(apps.apps.contains { $0.id.hasSuffix(".helper") }, "helper processes fold into their app")
        XCTAssertEqual(apps.apps.count, Set(apps.apps.map(\.id)).count)
    }

    /// Drives the real overlay with mouse events and checks the exported pixels.
    @MainActor
    func testScreenshotDrawingEndsUpInTheExportedImage() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("no screen") }
        let width = Int(screen.frame.width), height = Int(screen.frame.height)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let palette = ScreenshotPalette()
        let actions = ScreenshotOverlay.Actions(mayStartSelection: { _ in true }, selectionStarted: { _ in }, copy: {}, save: {},
                                                undo: {}, redo: {}, close: {})
        let overlay = ScreenshotOverlay(screen: screen, image: image, palette: palette, actions: actions)
        let canvas = try XCTUnwrap(overlay.contentView?.subviews.first)

        func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                               windowNumber: overlay.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(from: CGPoint, to: CGPoint) {
            canvas.mouseDown(with: mouse(.leftMouseDown, from.x, from.y))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, to.x, to.y))
            canvas.mouseUp(with: mouse(.leftMouseUp, to.x, to.y))
        }

        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        XCTAssertTrue(overlay.hasSelection)
        palette.tool = .rectangle
        drag(from: CGPoint(x: 120, y: 120), to: CGPoint(x: 280, y: 180))
        XCTAssertTrue(overlay.hasMarks)

        func pixel(_ cgImage: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            var data = [UInt8](repeating: 0, count: 4)
            let probe = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            probe.draw(cgImage, in: CGRect(x: -x, y: y - cgImage.height + 1, width: cgImage.width, height: cgImage.height))
            return (data[0], data[1], data[2])
        }
        let drawn = try XCTUnwrap(overlay.selectedImage()).image
        XCTAssertEqual(drawn.width, Int(200 * CGFloat(width) / screen.frame.width))
        // The rectangle's bottom edge: 20 points above the selection's bottom, in a top-origin image.
        let onLine = pixel(drawn, 100, 100 - 20)
        XCTAssertGreaterThan(onLine.0, 200)
        XCTAssertLessThan(onLine.1, 120, "the red stroke is in the export")
        XCTAssertEqual(pixel(drawn, 100, 50).1, 255, "and the rest of the picture is untouched")

        overlay.undo()
        XCTAssertFalse(overlay.hasMarks)
        XCTAssertEqual(pixel(try XCTUnwrap(overlay.selectedImage()).image, 100, 80).1, 255, "undo removes it")
        overlay.orderOut(nil)
    }

    /// Each way of choosing does its own thing with the same clicks and drags.
    @MainActor
    func testCaptureModes() throws {
        guard let screen = NSScreen.screens.first else { throw XCTSkip("no screen") }
        let front = ScreenshotWindow(id: 7, frame: CGRect(x: 200, y: 200, width: 300, height: 200))
        let behind = ScreenshotWindow(id: 8, frame: CGRect(x: 100, y: 100, width: 600, height: 500))
        func overlay(_ mode: ScreenCaptureMode) -> ScreenshotOverlay {
            ScreenshotOverlay(screen: screen, image: nil, palette: ScreenshotPalette(), verb: "chụp", placement: .followsSelection,
                              options: ScreenCaptureOptions(mode: mode), windows: [front, behind],
                              mayStartSelection: { _ in true }, selectionStarted: { _ in }, toolbar: EmptyView())
        }
        func click(_ target: ScreenshotOverlay, _ x: CGFloat, _ y: CGFloat, to end: CGPoint? = nil) throws {
            let canvas = try XCTUnwrap(target.contentView?.subviews.first)
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                   windowNumber: target.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            let start = CGPoint(x: x, y: y)
            canvas.mouseDown(with: mouse(.leftMouseDown, start))
            if let end { canvas.mouseDragged(with: mouse(.leftMouseDragged, end)) }
            canvas.mouseUp(with: mouse(.leftMouseUp, end ?? start))
        }

        let windows = overlay(.window)
        try click(windows, 300, 300)
        XCTAssertEqual(windows.selectionRect, front.frame, "the frontmost window wins")
        XCTAssertEqual(windows.selectedWindowID, 7)
        try click(windows, 150, 150)
        XCTAssertEqual(windows.selectedWindowID, 8, "another click picks another window")

        let region = overlay(.region)
        try click(region, 300, 300)
        XCTAssertFalse(region.hasSelection, "a click selects nothing when dragging is the mode")
        try click(region, 150, 150, to: CGPoint(x: 250, y: 250))
        XCTAssertEqual(region.selectionRect, CGRect(x: 150, y: 150, width: 100, height: 100))
        XCTAssertNil(region.selectedWindowID)

        let whole = overlay(.fullScreen)
        try click(whole, 300, 300)
        XCTAssertEqual(whole.selectionRect?.size, screen.frame.size)
        XCTAssertNil(whole.selectedWindowID)
    }

    @MainActor
    func testBatteryReading() throws {
        let battery = BatteryMonitor.shared
        battery.observe("test")
        defer { battery.stopObserving("test") }
        guard battery.snapshot.hasBattery else { throw XCTSkip("no battery") }
        XCTAssertTrue((0...100).contains(battery.snapshot.percent))
        XCTAssertGreaterThan(battery.snapshot.designCapacity, 0)
        XCTAssertTrue((0.3...1.3).contains(battery.snapshot.health))
    }

    @MainActor
    func testWindowListIsFastEnoughForCommandTab() throws {
        guard AXWindow.isTrusted else { throw XCTSkip("needs Accessibility for the test runner") }
        let start = Date()
        let windows = WindowSwitcher.collectWindows()
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.3, "⌘Tab must open without a visible delay")
        XCTAssertEqual(windows.count, Set(windows.map(\.id)).count, "no window listed twice")
    }

    // MARK: Helpers

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw XCTSkip("timed out waiting for hardware readings") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Audio state is read away from the main thread and published back to it.
private func spinRunLoop(for seconds: TimeInterval = 2, until done: () -> Bool = { false }) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}
