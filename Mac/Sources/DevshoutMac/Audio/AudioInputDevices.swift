// Lists audio input devices through Core Audio, and watches for them coming and going.
//
// Unsure on macOS (not compiled in CI yet):
// - Reading CFString properties into `Unmanaged<CFString>?` and taking a retained value: Core Audio documents that
//   the caller releases kAudioDevicePropertyDeviceUID / kAudioObjectPropertyName strings.
// - Whether aggregate and virtual devices (Zoom, Teams, BlackHole) should be filtered out; they are listed for now.
import CoreAudio
import Foundation

/// An audio input device. `uid` is stable across reboots and reconnections: store that in settings.
public struct AudioInputDevice: Sendable, Hashable, Identifiable {
    public var id: String { uid }
    public let uid: String
    public let name: String
    public let isDefault: Bool
    public let deviceID: AudioDeviceID
    public let inputChannels: Int

    public init(uid: String, name: String, isDefault: Bool, deviceID: AudioDeviceID, inputChannels: Int) {
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
        self.deviceID = deviceID
        self.inputChannels = inputChannels
    }
}

public enum AudioInputDevices {
    /// Every device with at least one input channel, the system default first, then by name.
    public static func all() -> [AudioInputDevice] {
        let defaultID = defaultInputDeviceID()
        let devices = allDeviceIDs().compactMap { id -> AudioInputDevice? in
            let channels = inputChannelCount(of: id)
            guard channels > 0, let uid = stringProperty(of: id, kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(of: id, kAudioObjectPropertyName) ?? uid
            return AudioInputDevice(uid: uid, name: name, isDefault: id == defaultID, deviceID: id, inputChannels: channels)
        }
        return devices.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    public static func device(withUID uid: String) -> AudioInputDevice? {
        all().first { $0.uid == uid }
    }

    public static func defaultDevice() -> AudioInputDevice? {
        all().first { $0.isDefault }
    }

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    /// Whether the device is still there (false once a USB or Bluetooth device is unplugged).
    public static func isAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
        return status == noErr && alive != 0
    }

    // MARK: Core Audio helpers

    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return OSStatus(kAudioHardwareUnspecifiedError) }
            return AudioObjectGetPropertyData(system, &address, 0, nil, &size, base)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func stringProperty(of objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

/// Calls `onChange` (on the main queue) when input devices are added or removed, or the default input changes.
/// Keep it alive for as long as you want updates; it stops listening when released.
public final class AudioInputDevicesObserver {
    private let block: AudioObjectPropertyListenerBlock
    private var addresses: [AudioObjectPropertyAddress] = [
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain),
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain),
    ]

    public init(onChange: @escaping () -> Void) {
        block = { _, _ in onChange() }
        let system = AudioObjectID(kAudioObjectSystemObject)
        for index in addresses.indices {
            _ = AudioObjectAddPropertyListenerBlock(system, &addresses[index], DispatchQueue.main, block)
        }
    }

    deinit {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for index in addresses.indices {
            _ = AudioObjectRemovePropertyListenerBlock(system, &addresses[index], DispatchQueue.main, block)
        }
    }
}
