import AppKit
import CoreVideo
import Darwin
import QuartzCore
import os

private let log = Logger(subsystem: "com.dungng.tiledeck", category: "MouseScroll")

/// What the scroll tap needs to know, read on its own thread.
struct MouseScrollSettings: Sendable {
    var smooth = true
    var reverse = false
    /// Pixels per wheel line.
    var step: Double = 50
    /// How briskly the glide settles, per second: lower glides longer.
    var glide: Double = 26
    var exceptions: Set<String> = []
}

/// Smooth scrolling and a separate scroll direction for mouse wheels, leaving
/// trackpads and the Magic Mouse alone (they already scroll smoothly).
@MainActor
final class MouseScroll: ObservableObject {
    static let shared = MouseScroll()
    nonisolated static let speeds: [(title: String, step: Double)] = [("Chậm", 30), ("Vừa", 50), ("Nhanh", 85)]
    nonisolated static let glides: [(title: String, glide: Double)] = [("Ngắn", 40), ("Vừa", 26), ("Dài", 17)]

    private enum Key {
        static let enabled = "mouseScroll", smooth = "mouseScrollSmooth", reverse = "mouseScrollReverse"
        static let speed = "mouseScrollSpeed", glide = "mouseScrollGlide", exceptions = "mouseScrollExceptions"
    }

    @Published private(set) var isEnabled: Bool
    @Published private(set) var smooth: Bool
    @Published private(set) var reverse: Bool
    @Published private(set) var speedIndex: Int
    @Published private(set) var glideIndex: Int
    @Published private(set) var exceptions: [String]

    private var engine: ScrollEngine?
    private let settings = OSAllocatedUnfairLock(initialState: MouseScrollSettings())
    private let frontmost = OSAllocatedUnfairLock<String?>(initialState: nil)

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Key.enabled)
        smooth = defaults.object(forKey: Key.smooth) as? Bool ?? true
        reverse = defaults.bool(forKey: Key.reverse)
        speedIndex = min(defaults.object(forKey: Key.speed) as? Int ?? 1, Self.speeds.count - 1)
        glideIndex = min(defaults.object(forKey: Key.glide) as? Int ?? 1, Self.glides.count - 1)
        exceptions = defaults.stringArray(forKey: Key.exceptions) ?? []
        pushSettings()

        let workspace = NSWorkspace.shared
        let current = workspace.frontmostApplication?.bundleIdentifier
        frontmost.withLock { $0 = current }
        workspace.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmost.withLock { $0 = app?.bundleIdentifier }
        }
        // Starts as soon as Accessibility is granted, without polling.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.activateIfNeeded() }
            }
        }
    }

    func activateIfNeeded() {
        guard isEnabled, engine == nil, AXWindow.isTrusted else { return }
        engine = ScrollEngine(settings: settings, frontmost: frontmost)
        if engine?.start() != true { engine = nil }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Key.enabled)
        if enabled {
            if !AXWindow.isTrusted { AXWindow.requestTrust() }
            activateIfNeeded()
        } else {
            engine?.stop()
            engine = nil
        }
    }

    func setSmooth(_ value: Bool) { smooth = value; store(value, Key.smooth) }
    func setReverse(_ value: Bool) { reverse = value; store(value, Key.reverse) }
    func setSpeed(_ index: Int) { speedIndex = index; store(index, Key.speed) }
    func setGlide(_ index: Int) { glideIndex = index; store(index, Key.glide) }

    func addException(_ bundleID: String) {
        guard !exceptions.contains(bundleID) else { return }
        exceptions.append(bundleID)
        store(exceptions, Key.exceptions)
    }

    func removeException(_ bundleID: String) {
        exceptions.removeAll { $0 == bundleID }
        store(exceptions, Key.exceptions)
    }

    /// Open apps that could be added to the exceptions.
    var exceptionCandidates: [(id: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !exceptions.contains($0.0) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
        pushSettings()
    }

    private func pushSettings() {
        let current = MouseScrollSettings(smooth: smooth, reverse: reverse, step: Self.speeds[speedIndex].step,
                                          glide: Self.glides[glideIndex].glide, exceptions: Set(exceptions))
        settings.withLock { $0 = current }
    }
}

enum ScrollSource {
    case wheel
    /// A mouse driver's own gesture, e.g. Logi Options+ re-sending the MX Master's thumb wheel.
    case driverGesture
    case trackpad

    /// Mouse wheels click by lines. Trackpads and the Magic Mouse scroll in
    /// continuous steps within a gesture (began, changed, ended) or its momentum,
    /// straight from the hardware. Mouse drivers such as Logi Options+ re-send
    /// wheel clicks as continuous steps outside any gesture, and their thumb
    /// wheel as a gesture, but always from their own process.
    static func classify(continuous: Bool, phase: Int64, momentum: Int64, senderPID: Int64) -> ScrollSource {
        if !continuous || (phase == 0 && momentum == 0) { return .wheel }
        return senderPID != 0 ? .driverGesture : .trackpad
    }
}

/// Logi Options+ carries out the MX Master's "hold the gesture button and move
/// left/right" by typing ⌃← / ⌃→. Reversing the mouse also mirrors those, the
/// way Options+'s own direction setting does.
enum DriverGesture {
    static let leftArrow: Int64 = 123
    static let rightArrow: Int64 = 124

    /// The other arrow for a ⌃← / ⌃→ sent by the mouse driver, otherwise nil.
    static func mirroredKey(_ keyCode: Int64, flags: CGEventFlags, fromMouseDriver: Bool) -> Int64? {
        guard fromMouseDriver, flags.contains(.maskControl),
              flags.intersection([.maskCommand, .maskAlternate, .maskShift]).isEmpty else { return nil }
        switch keyCode {
        case leftArrow: return rightArrow
        case rightArrow: return leftArrow
        default: return nil
        }
    }

    /// Whether a process is Logitech's mouse software. Only it: input methods
    /// such as EVKey re-send every key typed, and those must stay as they are.
    static func isMouseDriver(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: 4096)
        guard pid > 0, proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path).lowercased().contains("logioptionsplus")
    }
}

/// How far a smooth scroll still has to go, handed out a frame at a time.
///
/// The motion is a critically damped spring pulled towards where the wheel
/// says the page should be. Each click moves that target, but the speed itself
/// never jumps: it rises and falls smoothly, so several clicks in a row blend
/// into one steady glide instead of a burst per click.
struct SmoothScrollState {
    /// The most that can be queued, so a fast flick of a free-spinning wheel can't build up minutes of scrolling.
    static let maxQueued: CGFloat = 6_000
    /// The fastest it moves, in points per second: faster than that reads as a jump, not a glide.
    static let maxSpeed: CGFloat = 24_000
    /// The slowest it moves near the end, so a glide stops cleanly instead of creeping.
    static let minSpeed: CGFloat = 240

    /// Distance still to go, per axis.
    private(set) var remaining = CGVector.zero
    /// How fast `remaining` is shrinking, in points per second.
    private var speed = CGVector.zero
    /// Fractions of a point owed from earlier frames, so the motion stays even.
    private var carry = CGVector.zero

    var isIdle: Bool { remaining == .zero }

    /// One wheel turn, in lines. Turning the other way drops what was left.
    mutating func add(lines: CGVector, step: Double) {
        let distance = CGVector(dx: lines.dx * step, dy: lines.dy * step)
        if distance.dx * remaining.dx < 0 { remaining.dx = 0; speed.dx = 0; carry.dx = 0 }
        if distance.dy * remaining.dy < 0 { remaining.dy = 0; speed.dy = 0; carry.dy = 0 }
        remaining.dx = min(max(remaining.dx + distance.dx, -Self.maxQueued), Self.maxQueued)
        remaining.dy = min(max(remaining.dy + distance.dy, -Self.maxQueued), Self.maxQueued)
    }

    mutating func cancel() {
        remaining = .zero
        speed = .zero
        carry = .zero
    }

    /// Whole points to scroll in a frame `elapsed` seconds after the last one;
    /// nil once there's nothing left. `glide` is the spring's rate per second.
    mutating func nextFrame(glide: Double, elapsed: Double) -> (dx: Int32, dy: Int32)? {
        guard !isIdle else { return nil }
        let seconds = CGFloat(min(max(elapsed, 0), 0.05))
        let rate = CGFloat(glide)
        func step(_ left: inout CGFloat, _ velocity: inout CGFloat, _ owed: inout CGFloat) -> Int32 {
            guard left != 0 else { return 0 }
            // Exact critically damped step for the distance left (it heads to 0).
            let decay = exp(-rate * seconds)
            let pull = (-velocity + rate * left) * seconds
            let next = (left + pull) * decay
            velocity = -(-velocity - rate * pull) * decay
            var move = left - next
            // Never backwards, never slower than the floor near the end, never faster than the cap.
            let direction: CGFloat = left > 0 ? 1 : -1
            move = min(max(move * direction, min(abs(left), Self.minSpeed * seconds)), Self.maxSpeed * seconds) * direction
            if abs(move) > abs(left) { move = left }
            left -= move
            if abs(left) < 0.01 {
                left = 0
                velocity = 0
            }
            let total = move + owed
            let whole = total.rounded()
            owed = left == 0 ? 0 : total - whole
            return Int32(whole)
        }
        let dx = step(&remaining.dx, &speed.dx, &carry.dx)
        let dy = step(&remaining.dy, &speed.dy, &carry.dy)
        if isIdle && dx == 0 && dy == 0 { return nil }
        return (dx, dy)
    }
}

/// The scroll tap. It runs on its own thread: macOS holds every wheel event
/// until a tap answers, so a busy main thread must never be in the way.
private final class ScrollEngine: @unchecked Sendable {
    /// Marks the events this engine posts, so it lets them through untouched.
    static let marker: Int64 = 0x5444_5343

    private let settings: OSAllocatedUnfairLock<MouseScrollSettings>
    private let frontmost: OSAllocatedUnfairLock<String?>
    private var port: CFMachPort?
    /// The tap thread's run loop; display refreshes hop onto it.
    private var loop: CFRunLoop?
    /// Paces the glide with the display under the cursor, one step per refresh:
    /// a fixed timer beats against a 60 or 100 Hz display and judders.
    private var displayLink: CVDisplayLink?
    private let framePending = OSAllocatedUnfairLock(initialState: false)

    // Only touched on the tap's thread.
    private var mouseDrivers: [pid_t: Bool] = [:]
    private var state = SmoothScrollState()
    private var flags: CGEventFlags = []
    private var lastFrame: CFTimeInterval = 0

    init(settings: OSAllocatedUnfairLock<MouseScrollSettings>, frontmost: OSAllocatedUnfairLock<String?>) {
        self.settings = settings
        self.frontmost = frontmost
    }

    func start() -> Bool {
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: [CGEventType.scrollWheel, .keyDown, .keyUp].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) },
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<ScrollEngine>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        // The run loop, and the thread with it, ends once `stop()` invalidates the port and any glide finishes.
        let thread = Thread { [self] in
            loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CFRunLoopRun()
            stopDisplayLink()
        }
        thread.name = "TileDeck.mouseScroll"
        thread.qualityOfService = .userInteractive
        thread.start()
        log.info("scroll tap started")
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        self.port = nil
        if let loop { CFRunLoopStop(loop) }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return pass
        }
        if type == .keyDown || type == .keyUp {
            mirrorDriverGesture(event)
            return pass
        }
        guard type == .scrollWheel, event.getIntegerValueField(.eventSourceUserData) != Self.marker else { return pass }
        let source = ScrollSource.classify(continuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
                                           phase: event.getIntegerValueField(.scrollWheelEventScrollPhase),
                                           momentum: event.getIntegerValueField(.scrollWheelEventMomentumPhase),
                                           senderPID: event.getIntegerValueField(.eventSourceUnixProcessID))
        guard source != .trackpad else { return pass }
        let settings = settings.withLock { $0 }
        if let app = frontmost.withLock({ $0 }), settings.exceptions.contains(app) { return pass }
        // The driver already glides its gestures; they only need the direction.
        if source == .driverGesture {
            if settings.reverse { Self.flip(event) }
            return pass
        }

        let held = event.flags
        if !settings.smooth || !held.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty {
            // ⌘/⌥/⌃ + wheel usually means zoom: keep the original clicks, only flipped if asked.
            if settings.reverse { Self.flip(event) }
            return pass
        }

        var lines = CGVector(dx: Self.lines(event, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventDeltaAxis2),
                             dy: Self.lines(event, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventDeltaAxis1))
        if settings.reverse { lines = CGVector(dx: -lines.dx, dy: -lines.dy) }
        // ⇧ + wheel scrolls sideways, as in most apps.
        if held.contains(.maskShift), lines.dx == 0 { lines = CGVector(dx: lines.dy, dy: 0) }
        guard lines != .zero else {
            if settings.reverse { Self.flip(event) }
            return pass
        }

        flags = held.subtracting(.maskShift)
        state.add(lines: lines, step: settings.step)
        startGliding()
        return nil
    }

    private func mirrorDriverGesture(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == DriverGesture.leftArrow || keyCode == DriverGesture.rightArrow,
              settings.withLock({ $0.reverse }) else { return }
        let pid = pid_t(event.getIntegerValueField(.eventSourceUnixProcessID))
        let fromDriver: Bool
        if let known = mouseDrivers[pid] {
            fromDriver = known
        } else {
            fromDriver = DriverGesture.isMouseDriver(pid)
            mouseDrivers[pid] = fromDriver
        }
        if let mirrored = DriverGesture.mirroredKey(keyCode, flags: event.flags, fromMouseDriver: fromDriver) {
            event.setIntegerValueField(.keyboardEventKeycode, value: mirrored)
        }
    }

    private static func lines(_ event: CGEvent, _ precise: CGEventField, _ whole: CGEventField) -> CGFloat {
        let value = event.getDoubleValueField(precise)
        return value != 0 ? value : CGFloat(event.getIntegerValueField(whole))
    }

    private static func flip(_ event: CGEvent) {
        for field in [CGEventField.scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2,
                      .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2] {
            event.setIntegerValueField(field, value: -event.getIntegerValueField(field))
        }
        for field in [CGEventField.scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2] {
            event.setDoubleValueField(field, value: -event.getDoubleValueField(field))
        }
    }

    private func startGliding() {
        if displayLink == nil {
            var link: CVDisplayLink?
            guard CVDisplayLinkCreateWithActiveCGDisplays(&link) == kCVReturnSuccess, let link else { return }
            CVDisplayLinkSetOutputHandler(link) { [weak self] _, _, _, _, _ in
                self?.requestFrame()
                return kCVReturnSuccess
            }
            displayLink = link
        }
        guard let displayLink, !CVDisplayLinkIsRunning(displayLink) else { return }
        if let display = Self.displayUnderCursor() { CVDisplayLinkSetCurrentCGDisplay(displayLink, display) }
        lastFrame = CACurrentMediaTime() - 1.0 / 120
        CVDisplayLinkStart(displayLink)
    }

    private func stopDisplayLink() {
        if let displayLink, CVDisplayLinkIsRunning(displayLink) { CVDisplayLinkStop(displayLink) }
    }

    private static func displayUnderCursor() -> CGDirectDisplayID? {
        guard let point = CGEvent(source: nil)?.location else { return nil }
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 else { return nil }
        return display
    }

    /// Runs on the display link's thread: hands the frame to the tap thread, at most one at a time.
    private func requestFrame() {
        guard let loop, framePending.withLock({ pending in
            defer { pending = true }
            return !pending
        }) else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            framePending.withLock { $0 = false }
            frame()
        }
        CFRunLoopWakeUp(loop)
    }

    private func frame() {
        let now = CACurrentMediaTime()
        let elapsed = now - lastFrame
        lastFrame = now
        let glide = settings.withLock { $0.glide }
        guard port != nil, let (dx, dy) = state.nextFrame(glide: glide, elapsed: elapsed) else {
            state.cancel()
            stopDisplayLink()
            return
        }
        guard dx != 0 || dy != 0,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.flags = flags
        if let location = CGEvent(source: nil)?.location { event.location = location }
        event.post(tap: .cgSessionEventTap)
    }
}
