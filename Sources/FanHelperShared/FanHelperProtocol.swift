import Foundation

/// The XPC contract between TileDeck and its privileged fan helper.
/// Every reply carries an error message, or nil on success.
@objc public protocol FanHelperProtocol {
    func version(reply: @escaping (String) -> Void)
    /// Pins the fan to `rpm`; the helper clamps it to the fan's own min…max.
    func setFanSpeed(_ index: Int, rpm: Double, reply: @escaping (String?) -> Void)
    func setFanAutomatic(_ index: Int, reply: @escaping (String?) -> Void)
    func resetAllFans(reply: @escaping (String?) -> Void)
}

public enum FanHelper {
    public static let machService = "com.dungng.tiledeck.helper"
    public static let plistName = "com.dungng.tiledeck.helper.plist"
    public static let version = "2"
    /// Only TileDeck signed by this team may talk to the helper.
    public static let clientRequirement =
        "anchor apple generic and identifier \"com.dungng.tiledeck\" and certificate leaf[subject.OU] = \"83K669D2N5\""
}
