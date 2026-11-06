import Combine
import Foundation

/// Stops charging at a chosen percentage while the Mac keeps running on the
/// adapter, through the privileged helper and the firmware's charge range.
/// It holds only while TileDeck runs: the helper puts normal charging back as
/// soon as TileDeck quits or crashes.
@MainActor
final class ChargeLimiter: ObservableObject {
    static let shared = ChargeLimiter()
    static let choices = [60, 70, 75, 80, 85, 90]
    private static let enabledKey = "chargeLimitEnabled"
    private static let limitKey = "chargeLimit"
    /// How far the battery may drop below the hold point before charging resumes.
    private static let slack = 2

    @Published private(set) var isEnabled: Bool
    @Published private(set) var limit: Int
    @Published private(set) var lastError: String?
    /// The upper bound last written: the limit, or the current charge while the
    /// battery is still above the limit.
    @Published private(set) var holdingAt: Int?

    private lazy var helper = HelperConnection { [weak self] error in
        self?.lastError = error
        // Whatever failed, the next change in charge tries again.
        if error != nil { self?.holdingAt = nil }
    }
    private var percentWatch: AnyCancellable?

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        let saved = defaults.integer(forKey: Self.limitKey)
        limit = Self.choices.contains(saved) ? saved : 80
    }

    func activateIfNeeded() {
        guard isEnabled, ChargeControl.canLimitCharge else { return }
        FanController.shared.refreshHelperState()
        guard FanController.shared.helperState == .ready else { return }
        start()
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        if enabled {
            FanController.shared.refreshHelperState()
            guard FanController.shared.helperState == .ready else {
                lastError = "Cần cài trình trợ giúp trước (một lần, dùng chung với phần Quạt)."
                return
            }
        }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        enabled ? start() : stop()
    }

    func setLimit(_ value: Int) {
        limit = value
        UserDefaults.standard.set(value, forKey: Self.limitKey)
        holdingAt = nil
        if isEnabled { apply() }
    }

    /// Called at quit. Dropping the connection is enough: the helper puts normal charging back.
    func restoreOnQuit() {
        helper.invalidate()
    }

    private func start() {
        guard percentWatch == nil else { return }
        BatteryMonitor.shared.observe("chargeLimit")
        // Fires right away with the current charge, then on every change.
        percentWatch = BatteryMonitor.shared.$snapshot
            .map(\.rawPercent)
            .removeDuplicates()
            .sink { [weak self] _ in self?.apply() }
    }

    private func stop() {
        percentWatch = nil
        BatteryMonitor.shared.stopObserving("chargeLimit")
        holdingAt = nil
        helper.send { helper, done in
            helper.resetCharging { error in
                done(error)
                // Nothing held any more: let the helper go once it has answered.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let limiter = ChargeLimiter.shared
                        if !limiter.isEnabled { limiter.helper.invalidate() }
                    }
                }
            }
        }
    }

    /// The firmware compares its range with the raw charge, not the figure macOS shows.
    private func apply() {
        let percent = BatteryMonitor.shared.snapshot.rawPercent
        guard percent > 0 else { return }
        // Never below the current charge (hence rounded up): the firmware would
        // then drain the battery down to it while plugged in. Above the limit, hold where the battery is
        // and follow it down as it gets used, never back up.
        let upper = max(limit, min(percent, 100))
        if let holdingAt, upper >= holdingAt { return }
        let lower = max(upper - Self.slack, 10)
        holdingAt = upper
        helper.send { helper, done in
            helper.setChargeLimit(upper: upper, lower: lower) { error in
                done(error)
                guard error != nil else { return }
                // The firmware refused: this Mac can't hold a limit, so don't keep trying.
                DispatchQueue.main.async { MainActor.assumeIsolated { ChargeLimiter.shared.refused() } }
            }
        }
    }

    private func refused() {
        isEnabled = false
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        percentWatch = nil
        BatteryMonitor.shared.stopObserving("chargeLimit")
        holdingAt = nil
        helper.invalidate()
    }
}
