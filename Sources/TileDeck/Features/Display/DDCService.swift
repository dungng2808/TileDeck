import CoreGraphics
import Foundation
import IOKit

/// DDC/CI over Apple Silicon's IOAVService: talks to an external monitor's own
/// brightness setting, the same way its on-screen menu does.
final class DDCService: @unchecked Sendable {
    static let brightnessCode: UInt8 = 0x10

    private let service: CFTypeRef
    private let queue = DispatchQueue(label: "TileDeck.ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var pendingValue: UInt16?
    private var isWriting = false

    private init(service: CFTypeRef) {
        self.service = service
    }

    /// Pairs each external display with its AV service. In the IORegistry every
    /// external framebuffer (carrying the monitor's vendor/product IDs) comes right
    /// before its DCPAVServiceProxy, so one ordered walk is enough.
    static func matchExternalDisplays() -> [CGDirectDisplayID: DDCService] {
        guard let create = PrivateAPI.avServiceCreate else { return [:] }

        var found: [(vendor: Int, product: Int, service: CFTypeRef)] = []
        var lastAttributes: (vendor: Int, product: Int)?
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            var className = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(entry, &className)
            switch String(cString: className) {
            case "IOMobileFramebufferShim", "AppleCLCD2":
                if let attributes = IORegistryEntryCreateCFProperty(entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                   let product = attributes["ProductAttributes"] as? [String: Any] {
                    lastAttributes = (product["LegacyManufacturerID"] as? Int ?? 0, product["ProductID"] as? Int ?? 0)
                }
            case "DCPAVServiceProxy":
                let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                if location == "External", let attributes = lastAttributes,
                   let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() {
                    found.append((attributes.vendor, attributes.product, service))
                }
                lastAttributes = nil
            default:
                break
            }
        }

        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        let externals = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }

        var result: [CGDirectDisplayID: DDCService] = [:]
        for id in externals {
            if let index = found.firstIndex(where: { $0.vendor == Int(CGDisplayVendorNumber(id)) && $0.product == Int(CGDisplayModelNumber(id)) }) {
                result[id] = DDCService(service: found.remove(at: index).service)
            }
        }
        // Monitors with no usable IDs: fall back to registry order.
        for (id, leftover) in zip(externals.filter { result[$0] == nil }, found) {
            result[id] = DDCService(service: leftover.service)
        }
        return result
    }

    /// Reads a VCP value off the main thread; completes on main with (current, max), or nil if the monitor doesn't answer.
    func read(_ code: UInt8 = brightnessCode, completion: @escaping @MainActor ((current: Int, max: Int)?) -> Void) {
        queue.async { [self] in
            var value: (current: Int, max: Int)?
            for _ in 0..<3 where value == nil {
                if let reply = exchange([code], replyLength: 11) {
                    value = (Int(reply[8]) << 8 | Int(reply[9]), Int(reply[6]) << 8 | Int(reply[7]))
                }
            }
            DispatchQueue.main.async { completion(value) }
        }
    }

    /// Writes are slow (~25 ms each), so a dragged slider only sends the latest value.
    func write(_ value: UInt16, code: UInt8 = brightnessCode) {
        lock.lock()
        pendingValue = value
        let shouldStart = !isWriting
        isWriting = true
        lock.unlock()
        guard shouldStart else { return }

        queue.async { [self] in
            while true {
                lock.lock()
                guard let next = pendingValue else {
                    isWriting = false
                    lock.unlock()
                    return
                }
                pendingValue = nil
                lock.unlock()
                _ = exchange([code, UInt8(next >> 8), UInt8(next & 0xFF)], replyLength: 0)
            }
        }
    }

    // MARK: Wire protocol

    private static let address: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    private func exchange(_ send: [UInt8], replyLength: Int) -> [UInt8]? {
        guard let writeI2C = PrivateAPI.avServiceWriteI2C, let readI2C = PrivateAPI.avServiceReadI2C else { return nil }

        var packet: [UInt8] = [0x80 | UInt8(send.count + 1), UInt8(send.count)] + send + [0]
        let seed: UInt8 = send.count == 1 ? 0x6E : 0x6E ^ 0x51
        packet[packet.count - 1] = Self.checksum(seed, packet.dropLast())
        for _ in 0..<2 {
            usleep(10_000)
            guard writeI2C(service, Self.address, Self.dataAddress, &packet, UInt32(packet.count)) == kIOReturnSuccess else { return nil }
        }
        guard replyLength > 0 else { return [] }

        usleep(50_000)
        var reply = [UInt8](repeating: 0, count: replyLength)
        guard readI2C(service, Self.address, Self.dataAddress, &reply, UInt32(replyLength)) == kIOReturnSuccess,
              Self.checksum(0x50, reply.dropLast()) == reply[replyLength - 1] else { return nil }
        return reply
    }

    static func checksum(_ seed: UInt8, _ bytes: ArraySlice<UInt8>) -> UInt8 {
        bytes.reduce(seed, ^)
    }
}
