/// Which charge-limit mechanism this Mac's SMC firmware still exposes.
/// Apple removed the charge-inhibit keys in the macOS 15.8 / 26.7 firmware;
/// what's left (CHIE) cuts the adapter entirely, which isn't a safe charge limit.
enum ChargeControl {
    enum Support {
        /// Charging can be paused while the Mac keeps running on the adapter.
        case inhibit(key: String)
        /// Only the adapter can be cut (the Mac then drains its battery).
        case adapterOnly
        case none
    }

    static let support: Support = {
        if SMC.hasKey("CHTE") { return .inhibit(key: "CHTE") }
        if SMC.hasKey("CH0B") && SMC.hasKey("CH0C") { return .inhibit(key: "CH0B") }
        if SMC.hasKey("CHIE") { return .adapterOnly }
        return .none
    }()

    static var canLimitCharge: Bool {
        if case .inhibit = support { return true }
        return false
    }
}
