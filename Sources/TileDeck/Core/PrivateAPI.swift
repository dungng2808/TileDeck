import CoreGraphics
import Foundation
import IOKit

/// Private system symbols, resolved lazily with dlsym so a missing symbol on a
/// future macOS disables one feature instead of crashing the app at launch.
enum PrivateAPI {
    private static let displayServicesPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private static let ioKitPath = "/System/Library/Frameworks/IOKit.framework/IOKit"

    private static func symbol<T>(_ path: String, _ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen(path, RTLD_LAZY), let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }

    // MARK: Built-in display brightness (DisplayServices)

    typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    static let getBrightness = symbol(displayServicesPath, "DisplayServicesGetBrightness", as: GetBrightness.self)
    static let setBrightness = symbol(displayServicesPath, "DisplayServicesSetBrightness", as: SetBrightness.self)
    static let canChangeBrightness = symbol(displayServicesPath, "DisplayServicesCanChangeBrightness", as: CanChangeBrightness.self)

    /// Fires whenever the panel's brightness changes, from any process (keys, Control Center, auto-brightness).
    typealias RegisterBrightnessNotifications = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    typealias UnregisterBrightnessNotifications = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Int32

    static let registerBrightnessNotifications = symbol(displayServicesPath, "DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterBrightnessNotifications.self)
    static let unregisterBrightnessNotifications = symbol(displayServicesPath, "DisplayServicesUnregisterForBrightnessChangeNotifications", as: UnregisterBrightnessNotifications.self)

    // MARK: Soft disconnect (SkyLight)

    typealias ConfigureDisplayEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32

    static let configureDisplayEnabled = symbol(skyLightPath, "SLSConfigureDisplayEnabled", as: ConfigureDisplayEnabled.self)

    // MARK: Native on-screen display (OSD.framework)

    typealias ShowOSD = @convention(c) (AnyObject, Selector, Int64, CGDirectDisplayID, UInt32, UInt32, UInt32, UInt32, Bool) -> Void

    /// The system brightness HUD, drawn by macOS itself on any display.
    static let showOSD: ((_ image: Int64, _ display: CGDirectDisplayID, _ filled: UInt32, _ total: UInt32) -> Void)? = {
        guard Bundle(path: "/System/Library/PrivateFrameworks/OSD.framework")?.load() == true,
              let managerClass = NSClassFromString("OSDManager") as? NSObject.Type,
              let manager = managerClass.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() else { return nil }
        let selector = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
        guard let method = class_getInstanceMethod(type(of: manager), selector) else { return nil }
        let show = unsafeBitCast(method_getImplementation(method), to: ShowOSD.self)
        return { image, display, filled, total in
            show(manager, selector, image, display, 0x1F4, 1000, filled, total, false)
        }
    }()

    // MARK: Power management preferences (read-only)

    typealias CopyPMPreferences = @convention(c) () -> Unmanaged<CFDictionary>?
    static let copyPMPreferences = symbol(ioKitPath, "IOPMCopyPMPreferences", as: CopyPMPreferences.self)

    // MARK: Bluetooth controller power (IOBluetooth, as used by blueutil)

    typealias GetBluetoothPower = @convention(c) () -> Int32
    typealias SetBluetoothPower = @convention(c) (Int32) -> Void

    private static let ioBluetoothPath = "/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth"
    static let getBluetoothPower = symbol(ioBluetoothPath, "IOBluetoothPreferenceGetControllerPowerState", as: GetBluetoothPower.self)
    static let setBluetoothPower = symbol(ioBluetoothPath, "IOBluetoothPreferenceSetControllerPowerState", as: SetBluetoothPower.self)

    // MARK: DDC/CI on Apple Silicon (IOAVService)

    typealias AVServiceCreate = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias AVServiceI2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    static let avServiceCreate = symbol(ioKitPath, "IOAVServiceCreateWithService", as: AVServiceCreate.self)
    static let avServiceReadI2C = symbol(ioKitPath, "IOAVServiceReadI2C", as: AVServiceI2C.self)
    static let avServiceWriteI2C = symbol(ioKitPath, "IOAVServiceWriteI2C", as: AVServiceI2C.self)
}
