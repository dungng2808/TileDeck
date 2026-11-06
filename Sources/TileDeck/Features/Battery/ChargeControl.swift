/// Which charge-limit mechanism this Mac's SMC firmware exposes. The macOS
/// 15.8 / 26.7 firmware dropped the charge-inhibit keys (CHTE, CH0B) and kept
/// a charge range (bfD0, bfE0, bfF0) instead, which ChargeLimiter uses. CHIE,
/// which cuts the adapter entirely, is never used: that isn't a charge limit.
enum ChargeControl {
    static let canLimitCharge = ["bfD0", "bfE0", "bfF0"].allSatisfy(SMC.hasKey)
}
