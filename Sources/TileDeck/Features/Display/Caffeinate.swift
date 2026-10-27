import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake like `caffeinate -d`, using a power assertion
/// instead of spawning a process. The timed mode is a single one-shot timer.
@MainActor
final class Caffeinate: ObservableObject {
    enum Duration: Int, CaseIterable, Identifiable {
        case infinite = 0, minutes15 = 15, minutes30 = 30, hour1 = 60, hours2 = 120

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .infinite: "Vô hạn"
            case .minutes15: "15m"
            case .minutes30: "30m"
            case .hour1: "1h"
            case .hours2: "2h"
            }
        }
    }

    static let shared = Caffeinate()

    @Published private(set) var isOn = false
    @Published private(set) var duration: Duration = .infinite
    @Published private(set) var endsAt: Date?

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    func setOn(_ on: Bool) {
        on ? start() : stop()
    }

    /// Picking a duration also switches it on.
    func select(_ duration: Duration) {
        self.duration = duration
        start()
    }

    func stop() {
        release()
        isOn = false
        endsAt = nil
    }

    private func start() {
        release()
        let created = IOPMAssertionCreateWithName(
            "PreventUserIdleDisplaySleep" as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "TileDeck Caffeinate" as CFString,
            &assertion
        )
        guard created == kIOReturnSuccess else {
            stop()
            return
        }
        isOn = true

        guard duration != .infinite else {
            endsAt = nil
            return
        }
        let end = Date().addingTimeInterval(TimeInterval(duration.rawValue * 60))
        endsAt = end
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func release() {
        timer?.invalidate()
        timer = nil
        if assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }
}
