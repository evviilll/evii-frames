import Foundation
import ObjectiveC
import VideoToolbox

enum AppleFrameRate {
    /// `VTFrameRateConversionConfiguration.isSupported`, read by name so an
    /// older SDK still links. False on anything before iOS 26, and false when
    /// this device (including an iPhone 14 Pro on iOS 27) answers no.
    /// v0.1 never starts a `VTFrameProcessor` session.
    static var isRuntimeSupported: Bool {
        if #available(iOS 26, *) {
            return classPropertyIsTrue("VTFrameRateConversionConfiguration", "isSupported")
        }
        return false
    }

    private static func classPropertyIsTrue(_ className: String, _ property: String) -> Bool {
        guard let cls: AnyClass = NSClassFromString(className) else { return false }
        let selector = NSSelectorFromString(property)
        guard let method = class_getClassMethod(cls, selector) else { return false }
        // ObjC BOOL is one byte. Nonzero means the device supports the processor.
        typealias Getter = @convention(c) (AnyClass, Selector) -> UInt8
        let fn = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        return fn(cls, selector) != 0
    }
}
