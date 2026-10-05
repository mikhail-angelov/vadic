import AudioToolbox
import CoreAudio

/// Silences the default output device for the duration of a recording and restores it afterwards.
/// Uses the device mute switch; devices without one (some HDMI/USB outputs) get their volume set to 0.
/// Leaves the device alone if it was already silent, so restore never unmutes what the user muted.
@MainActor
final class OutputMuter {
    private enum Saved {
        case mute(AudioDeviceID)
        case volume(AudioDeviceID, Float32)
    }

    private var saved: Saved?

    func mute() {
        guard saved == nil, let device = Self.defaultOutputDevice() else { return }
        if var address = Self.address(kAudioDevicePropertyMute), Self.isSettable(device, &address) {
            if Self.get(UInt32.self, device, &address) == 0, Self.set(UInt32(1), device, &address) {
                saved = .mute(device)
            }
        } else if var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume),
                  Self.isSettable(device, &address),
                  let volume = Self.get(Float32.self, device, &address), volume > 0,
                  Self.set(Float32(0), device, &address) {
            saved = .volume(device, volume)
        }
    }

    func restore() {
        switch saved {
        case .mute(let device):
            if var address = Self.address(kAudioDevicePropertyMute) { _ = Self.set(UInt32(0), device, &address) }
        case .volume(let device, let volume):
            if var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume) {
                _ = Self.set(volume, device, &address)
            }
        case nil:
            break
        }
        saved = nil
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let device = get(AudioDeviceID.self, AudioObjectID(kAudioObjectSystemObject), &address)
        return device == kAudioObjectUnknown ? nil : device
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress? {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func isSettable(_ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(object, &address)
            && AudioObjectIsPropertySettable(object, &address, &settable) == noErr
            && settable.boolValue
    }

    private static func get<T: BitwiseCopyable>(_: T.Type, _ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> T? {
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func set<T: BitwiseCopyable>(_ value: T, _ object: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }
}
