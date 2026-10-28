import Foundation
import Security

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

    /// What the helper demands of a client: TileDeck itself, signed by the same team as the helper.
    public static var clientRequirement: String { requirement(identifier: "com.dungng.tiledeck") }

    /// What TileDeck demands of the helper it talks to.
    public static var helperRequirement: String { requirement(identifier: "com.dungng.tiledeck.helper") }

    /// The team is read from the running code's own signature rather than
    /// written in, so development and Developer ID builds (which may belong to
    /// different teams) each trust only their own counterpart. Unsigned or
    /// ad-hoc builds have no team, and then nothing is trusted.
    private static func requirement(identifier: String) -> String {
        guard let team = ownTeamIdentifier else { return "never" }
        return "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
    }

    private static let ownTeamIdentifier: String? = {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess
        else { return nil }
        return (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()
}
