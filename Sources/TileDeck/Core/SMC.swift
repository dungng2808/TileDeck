import CSMC
import Foundation

/// Read-only SMC access (writing needs root). Used to detect which charging
/// controls this Mac's firmware still exposes.
enum SMC {
    static func read(_ key: String) -> [UInt8]? {
        var connection: io_connect_t = 0
        guard smc_open(&connection) == KERN_SUCCESS else { return nil }
        defer { smc_close(connection) }

        var bytes = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        guard smc_read(connection, key, &bytes, &size) == KERN_SUCCESS else { return nil }
        return Array(bytes.prefix(Int(size)))
    }

    static func hasKey(_ key: String) -> Bool {
        read(key) != nil
    }
}
