import AppKit
import Combine

/// Periodic battery calibration: drain to ≤ 20 %, charge to 100 %, hold on
/// the charger 15 minutes so the cells balance and the gauge re-learns its
/// capacity. TileDeck guides each step with notifications and follows
/// progress through BatteryMonitor's pushed updates; the schedule itself is
/// one far-off timer, re-checked at launch and wake.
@MainActor
final class Calibration: ObservableObject {
    enum Phase: String {
        case idle, draining, charging, holding
    }

    static let shared = Calibration()

    static let intervals = [30, 45, 60]
    static let drainTarget = 20
    static let holdMinutes = 15

    private enum Key {
        static let enabled = "calibrationEnabled"
        static let interval = "calibrationInterval"
        static let last = "calibrationLast"
        static let anchor = "calibrationAnchor"
        static let phase = "calibrationPhase"
        static let holdUntil = "calibrationHoldUntil"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var intervalDays: Int
    @Published private(set) var lastDate: Date?
    @Published private(set) var phase: Phase

    private let defaults = UserDefaults.standard
    private var scheduleTimer: Timer?
    private var holdTimer: Timer?
    private var subscription: AnyCancellable?
    private var wakeObserver: NSObjectProtocol?

    private init() {
        isEnabled = defaults.bool(forKey: Key.enabled)
        intervalDays = defaults.integer(forKey: Key.interval).nonZero ?? 30
        lastDate = defaults.object(forKey: Key.last) as? Date
        phase = Phase(rawValue: defaults.string(forKey: Key.phase) ?? "") ?? .idle
        if defaults.object(forKey: Key.anchor) == nil { defaults.set(Date(), forKey: Key.anchor) }
    }

    var nextDate: Date {
        let base = lastDate ?? (defaults.object(forKey: Key.anchor) as? Date) ?? Date()
        return Calendar.current.date(byAdding: .day, value: intervalDays, to: base) ?? base
    }

    var daysLeft: Int {
        max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: nextDate)).day ?? 0)
    }

    func activateIfNeeded() {
        wakeObserver = wakeObserver ?? NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedule() }
        }
        if phase != .idle { follow() }
        checkSchedule()
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        if enabled { Notifier.shared.requestPermission() }
        checkSchedule()
    }

    func setInterval(_ days: Int) {
        intervalDays = days
        defaults.set(days, forKey: Key.interval)
        checkSchedule()
    }

    func startNow() {
        Notifier.shared.requestPermission()
        begin()
    }

    func cancel() {
        setPhase(.idle)
        stopFollowing()
    }

    // MARK: Schedule

    private func checkSchedule() {
        scheduleTimer?.invalidate()
        scheduleTimer = nil
        guard isEnabled, phase == .idle else { return }
        if Date() >= nextDate {
            begin()
            return
        }
        let timer = Timer(fire: nextDate, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSchedule() }
        }
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
        scheduleTimer = timer
    }

    // MARK: Guided cycle

    private func begin() {
        setPhase(.draining)
        follow()
        Notifier.shared.post("Đến lịch hiệu chuẩn pin",
                             "Rút sạc và dùng máy bình thường đến khi pin còn \(Self.drainTarget)% hoặc thấp hơn.")
    }

    private func follow() {
        BatteryMonitor.shared.observe("calibration")
        subscription = BatteryMonitor.shared.$snapshot.sink { [weak self] battery in
            MainActor.assumeIsolated { self?.advance(battery) }
        }
        if phase == .holding { scheduleHoldEnd() }
    }

    private func stopFollowing() {
        subscription = nil
        holdTimer?.invalidate()
        holdTimer = nil
        BatteryMonitor.shared.stopObserving("calibration")
    }

    private func advance(_ battery: BatteryMonitor.Snapshot) {
        guard battery.hasBattery else { return }
        switch phase {
        case .idle:
            break
        case .draining:
            guard battery.percent <= Self.drainTarget else { return }
            setPhase(.charging)
            Notifier.shared.post("Pin đã xuống \(battery.percent)%",
                                 "Cắm sạc và để máy sạc đầy 100%. Đừng rút sạc cho tới khi TileDeck báo xong.")
        case .charging:
            guard battery.onAC, battery.percent >= 100, battery.isFull || !battery.isCharging else { return }
            setPhase(.holding)
            defaults.set(Date().addingTimeInterval(TimeInterval(Self.holdMinutes * 60)), forKey: Key.holdUntil)
            scheduleHoldEnd()
        case .holding:
            if !battery.onAC {
                // Unplugged too early: wait for 100 % again.
                setPhase(.charging)
                holdTimer?.invalidate()
            }
        }
    }

    private func scheduleHoldEnd() {
        holdTimer?.invalidate()
        let end = defaults.object(forKey: Key.holdUntil) as? Date ?? Date()
        let timer = Timer(fire: max(end, Date()), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func finish() {
        guard phase == .holding else { return }
        lastDate = Date()
        defaults.set(lastDate, forKey: Key.last)
        setPhase(.idle)
        stopFollowing()
        Notifier.shared.post("Hiệu chuẩn pin hoàn tất", "Đồng hồ đo pin đã được cân bằng lại. Bạn có thể rút sạc.")
        checkSchedule()
    }

    private func setPhase(_ phase: Phase) {
        self.phase = phase
        defaults.set(phase.rawValue, forKey: Key.phase)
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
