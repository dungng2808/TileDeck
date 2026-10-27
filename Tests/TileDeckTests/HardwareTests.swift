import AppKit
import CoreAudio
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
        guard !devices.output.devices.isEmpty else { throw XCTSkip("no audio output") }
        XCTAssertTrue(devices.output.devices.contains { $0.id == devices.output.current }, "the default output is in the list")
        XCTAssertFalse(devices.output.devices.contains { $0.uid.hasPrefix(AppVolume.aggregatePrefix) }, "TileDeck's own devices stay hidden")

        let apps = AppVolume.shared
        apps.refresh()
        XCTAssertFalse(apps.apps.contains { $0.id.hasSuffix(".helper") }, "helper processes fold into their app")
        XCTAssertEqual(apps.apps.count, Set(apps.apps.map(\.id)).count)
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
