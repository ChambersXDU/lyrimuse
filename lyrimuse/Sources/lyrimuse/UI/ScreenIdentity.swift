import AppKit
import CoreGraphics

enum ScreenIdentity {
    static func id(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        guard let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func screen(withID id: String) -> NSScreen? {
        guard !id.isEmpty else { return nil }
        return NSScreen.screens.first { self.id(of: $0) == id }
    }
}
