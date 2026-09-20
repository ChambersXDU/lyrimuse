import AppKit

import AudioToolbox
import CoreAudio
import OSLog

@MainActor
final class VolumeMonitor {
    static let shared = VolumeMonitor()

    private static let logger = Logger(subsystem: "me.yudaotor.lyrimuse", category: "volume")

    private var onChange: ((Float, Bool) -> Void)?

    private var started = false
    private var device = AudioObjectID(kAudioObjectUnknown)

    private var volumeAddr: AudioObjectPropertyAddress?
    private var muteAddr: AudioObjectPropertyAddress?

    private var lastVolume: Float?
    private var lastMuted: Bool?

    private let queue = DispatchQueue(label: "me.yudaotor.lyrimuse.volume")

    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var volumeListener: AudioObjectPropertyListenerBlock?

    private static var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {}

    func start(onChange: @escaping (Float, Bool) -> Void) {
        guard !started else { return }
        started = true
        self.onChange = onChange

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.rebindToDefaultDevice(notify: false) }
        }
        deviceListener = block
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, queue, block)
        if status != noErr {
            Self.logger.error("failed to observe default output device: \(status)")
        }
        rebindToDefaultDevice(notify: false)
    }

    func stop() {
        guard started else { return }
        started = false
        if let deviceListener {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, queue, deviceListener)
        }
        deviceListener = nil
        detachVolumeListener()
        onChange = nil
    }

    private func rebindToDefaultDevice(notify: Bool) {
        guard started else { return }
        detachVolumeListener()

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &Self.defaultDeviceAddress, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else {
            Self.logger.error("no default output device (status \(status))")
            return
        }
        device = deviceID
        volumeAddr = Self.volumeAddress(for: deviceID)
        muteAddr = Self.muteAddress(for: deviceID)
        guard volumeAddr != nil || muteAddr != nil else {

            Self.logger.info("output device has no readable volume property; volume banner disabled for it")
            return
        }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.handleVolumeChanged() }
        }
        volumeListener = block
        for addr in [volumeAddr, muteAddr].compactMap({ $0 }) {
            var a = addr
            let st = AudioObjectAddPropertyListenerBlock(deviceID, &a, queue, block)
            if st != noErr { Self.logger.error("failed to observe volume property: \(st)") }
        }

        lastVolume = readVolume()
        lastMuted = readMuted()
    }

    private func detachVolumeListener() {
        guard let volumeListener, device != kAudioObjectUnknown else {
            self.volumeListener = nil
            return
        }
        for addr in [volumeAddr, muteAddr].compactMap({ $0 }) {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(device, &a, queue, volumeListener)
        }
        self.volumeListener = nil
        volumeAddr = nil
        muteAddr = nil
        lastVolume = nil
        lastMuted = nil
    }

    private func handleVolumeChanged() {
        guard started else { return }
        let volume = readVolume()
        let muted = readMuted()

        guard volume != lastVolume || muted != lastMuted else { return }
        lastVolume = volume
        lastMuted = muted
        guard let volume else { return }
        Self.logger.info("volume changed to \(Int(volume * 100), privacy: .public)% muted=\(muted ?? false, privacy: .public)")
        onChange?(volume, muted ?? false)
    }

    private func readVolume() -> Float? {
        guard var addr = volumeAddr, device != kAudioObjectUnknown else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return min(1, max(0, value))
    }

    private func readMuted() -> Bool? {
        guard var addr = muteAddr, device != kAudioObjectUnknown else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func volumeAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress? {
        let candidates: [AudioObjectPropertySelector] = [
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            kAudioDevicePropertyVolumeScalar,
        ]
        for selector in candidates {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            if AudioObjectHasProperty(device, &addr) { return addr }
        }
        return nil
    }

    private static func muteAddress(for device: AudioObjectID) -> AudioObjectPropertyAddress? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(device, &addr) ? addr : nil
    }
}

extension VolumeMonitor {

    static func apply(enabled: Bool) {
        guard enabled else {
            shared.stop()
            return
        }
        shared.start { volume, muted in
            let percent = Int((volume * 100).rounded())
            let icon: String
            if muted || percent == 0 {
                icon = "speaker.slash.fill"
            } else if volume < 0.34 {
                icon = "speaker.wave.1.fill"
            } else if volume < 0.67 {
                icon = "speaker.wave.2.fill"
            } else {
                icon = "speaker.wave.3.fill"
            }
            NotchTransientCenter.shared.show(
                .init(
                    icon: icon,
                    text: muted ? L10n.t("已静音") : "\(percent)%",
                    progress: muted ? 0 : Double(volume)
                ),
                for: 1.2
            )
        }
    }
}
