import AppKit

/// A CGEvent tap on the main run loop for a fixed set of event types. The
/// handler returns the event to let it through, or nil to swallow it.
/// Needs Accessibility; `start()` returns false until it's granted.
@MainActor
final class EventTap {
    typealias Handler = @MainActor (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private let mask: CGEventMask
    private let handler: Handler
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(types: [CGEventType], handler: @escaping Handler) {
        mask = types.reduce(0) { $0 | (CGEventMask(1) << $1.rawValue) }
        self.handler = handler
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let passThrough = Unmanaged.passUnretained(event)
                guard let refcon else { return passThrough }
                let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                return MainActor.assumeIsolated { tap.handle(type, event) }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        return handler(type, event)
    }
}
