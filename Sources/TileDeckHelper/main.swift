import CSMC
import FanHelperShared
import Foundation

/// TileDeck's privileged fan helper. launchd starts it on demand when TileDeck
/// connects; it only writes fan mode and target-speed keys, only for a
/// TileDeck signed by our team, and hands every fan back to macOS's automatic
/// control as soon as no TileDeck is connected.

final class FanService: NSObject, FanHelperProtocol {
    private let lock = NSLock()

    func version(reply: @escaping (String) -> Void) {
        reply(FanHelper.version)
    }

    func setFanSpeed(_ index: Int, rpm: Double, reply: @escaping (String?) -> Void) {
        reply(withSMC { smc in
            guard let range = smc.range(of: index) else { return "Không có quạt số \(index)" }
            let target = Float(min(max(rpm, range.lowerBound), range.upperBound))
            if smc.uint8("F\(index)Md") != 1 {
                // Apple Silicon only accepts a manual fan mode while "Ftst" (fan test) is set,
                // and the SMC can take a moment to honour it, so confirm by reading back.
                guard smc.write("Ftst", [1]) else { return "Không mở được quyền điều khiển quạt" }
                // Fan test mode stays on after a failure so the next attempt doesn't restart
                // the SMC's warm-up; releasing the fans (or TileDeck leaving) turns it off.
                guard smc.writeConfirmed("F\(index)Md", 1) else { return "Không chuyển được quạt sang thủ công" }
            }
            guard smc.write("F\(index)Tg", withUnsafeBytes(of: target) { Array($0) }) else { return "Không đặt được tốc độ quạt" }
            return nil
        })
    }

    func setFanAutomatic(_ index: Int, reply: @escaping (String?) -> Void) {
        reply(withSMC { smc in
            guard index >= 0, index < smc.fanCount else { return "Không có quạt số \(index)" }
            return release(index, smc) ? nil : "Không trả quạt về tự động"
        })
    }

    func resetAllFans(reply: @escaping (String?) -> Void) {
        reply(resetAll())
    }

    /// Reads the real state rather than remembering it, so a helper that
    /// launchd restarted still cleans up after an earlier one.
    @discardableResult
    func resetAll() -> String? {
        withSMC { smc in
            var failed = false
            for index in 0..<smc.fanCount where !release(index, smc) {
                failed = true
            }
            return failed ? "Không trả hết quạt về tự động" : nil
        }
    }

    /// Hands the fan back to the system, and closes fan test mode once no fan is held.
    /// Mode 0 is all the SMC accepts while fan test mode is on; once "Ftst" is
    /// cleared the system puts its own automatic mode (3 on recent firmware) back.
    private func release(_ index: Int, _ smc: SMCSession) -> Bool {
        var restored = true
        if smc.uint8("F\(index)Md") == 1 {
            restored = smc.writeConfirmed("F\(index)Md", 0, attempts: 40)
        }
        if !smc.anyFanManual, smc.uint8("Ftst") == 1 { _ = smc.write("Ftst", [0]) }
        return restored
    }

    private func withSMC(_ body: (SMCSession) -> String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let smc = SMCSession() else { return "Không mở được SMC" }
        return body(smc)
    }
}

final class SMCSession {
    private var connection: io_connect_t = 0

    init?() {
        guard smc_open(&connection) == KERN_SUCCESS else { return nil }
    }

    deinit {
        smc_close(connection)
    }

    var fanCount: Int {
        var bytes = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        return smc_read(connection, "FNum", &bytes, &size) == KERN_SUCCESS ? Int(bytes[0]) : 0
    }

    func uint8(_ key: String) -> UInt8? {
        var bytes = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        return smc_read(connection, key, &bytes, &size) == KERN_SUCCESS && size == 1 ? bytes[0] : nil
    }

    var anyFanManual: Bool {
        (0..<fanCount).contains { uint8("F\($0)Md") == 1 }
    }

    /// Writes a one-byte value and re-reads it until the SMC reports it. Right
    /// after fan test mode is switched on, the SMC takes 6–10 s to accept a
    /// manual mode (measured on an M4 Pro), hence the generous default.
    func writeConfirmed(_ key: String, _ value: UInt8, attempts: Int = 240) -> Bool {
        for _ in 0..<attempts {
            if write(key, [value]), uint8(key) == value { return true }
            usleep(50_000)
        }
        return false
    }

    func float(_ key: String) -> Double? {
        var bytes = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        guard smc_read(connection, key, &bytes, &size) == KERN_SUCCESS, size == 4 else { return nil }
        var value: Float = 0
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes.prefix(4)) }
        return Double(value)
    }

    func range(of index: Int) -> ClosedRange<Double>? {
        guard index >= 0, index < fanCount, let low = float("F\(index)Mn"), let high = float("F\(index)Mx"), high > low else { return nil }
        return low...high
    }

    /// Only fan mode, fan target and the fan-test switch are ever written.
    func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard key == "Ftst" || (key.hasPrefix("F") && (key.hasSuffix("Md") || key.hasSuffix("Tg"))) else { return false }
        return smc_write(connection, key, bytes, UInt32(bytes.count)) == KERN_SUCCESS
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = FanService()
    private var connections = 0

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The system rejects any client that doesn't match before a message is delivered.
        connection.setCodeSigningRequirement(FanHelper.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: FanHelperProtocol.self)
        connection.exportedObject = service
        connections += 1
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async { self?.clientLeft() }
        }
        connection.resume()
        return true
    }

    /// TileDeck quit or crashed: never leave a fan pinned without someone watching temperatures.
    private func clientLeft() {
        connections -= 1
        guard connections <= 0 else { return }
        service.resetAll()
        // A new TileDeck may have connected while the fans were being released.
        guard connections <= 0 else { return }
        // launchd starts the helper again on the next connection.
        exit(0)
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: FanHelper.machService)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
