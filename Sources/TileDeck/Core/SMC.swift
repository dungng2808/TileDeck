import CSMC
import Foundation

/// Read-only SMC access (writing needs root). Used to detect which charging
/// controls this Mac's firmware still exposes, and to read fans and temperatures.
enum SMC {
    static func read(_ key: String) -> [UInt8]? {
        Connection()?.bytes(key)
    }

    static func hasKey(_ key: String) -> Bool {
        read(key) != nil
    }

    /// An open SMC session, for reading many keys in a row.
    final class Connection {
        private var connection: io_connect_t = 0

        init?() {
            guard smc_open(&connection) == KERN_SUCCESS else { return nil }
        }

        deinit {
            smc_close(connection)
        }

        func bytes(_ key: String) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: 32)
            var size: UInt32 = 0
            guard smc_read(connection, key, &bytes, &size) == KERN_SUCCESS else { return nil }
            return Array(bytes.prefix(Int(size)))
        }

        /// Apple Silicon stores fan speeds and temperatures as little-endian 32-bit floats ("flt ").
        func float(_ key: String) -> Double? {
            guard let bytes = bytes(key), bytes.count == 4 else { return nil }
            var value: Float = 0
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: bytes) }
            return value.isFinite ? Double(value) : nil
        }

        func uint8(_ key: String) -> UInt8? {
            bytes(key)?.first
        }

        /// Every key name the SMC exposes (a few thousand).
        func allKeys() -> [String] {
            let count = smc_key_count(connection)
            var keys: [String] = []
            keys.reserveCapacity(Int(count))
            var name = [CChar](repeating: 0, count: 5)
            for index in 0..<count where smc_key_at(connection, index, &name) == KERN_SUCCESS {
                keys.append(String(cString: name))
            }
            return keys
        }
    }
}
