import CoreAudio
import Foundation

public enum AudioOutputRoute {
    public enum Transport: String, Sendable {
        case builtIn, bluetooth, airPlay, display, usb, other
    }

    public struct Current: Equatable, Sendable {

        public let uid: String
        public let name: String
        public let transport: Transport
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func transport(forType type: UInt32) -> Transport {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeAirPlay: return .airPlay
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: return .display
        case kAudioDeviceTransportTypeUSB: return .usb
        default: return .other
        }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }

    public static func current() -> Current? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        var typeAddr = address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var typeSize = UInt32(MemoryLayout<UInt32>.size)
        let transport: Transport = AudioObjectGetPropertyData(id, &typeAddr, 0, nil, &typeSize, &type) == noErr
            ? Self.transport(forType: type) : .other
        guard let uid = string(kAudioDevicePropertyDeviceUID, of: id), !uid.isEmpty else { return nil }
        return Current(uid: uid, name: string(kAudioObjectPropertyName, of: id) ?? "", transport: transport)
    }

    private static var listening = false
    public static func startObserving(_ onChange: @escaping @Sendable () -> Void) {
        guard !listening else { return }
        listening = true
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in
            onChange()
        }
    }
}
