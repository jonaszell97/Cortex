import AudioToolbox
import CoreAudio

/// The mute switch and volume of the Mac's built-in speakers.
struct SpeakerLevel: Equatable {
    var isMuted: Bool
    var volume: Float

    static let medium: Float = 0.5

    /// What to set so a sound can be heard, or nil when it can already be.
    var audible: SpeakerLevel? {
        guard isMuted || volume == 0 else { return nil }
        return SpeakerLevel(isMuted: false, volume: max(volume, Self.medium))
    }

    /// The device hands back a volume a hair off the one set (0.5 reads as 0.49999997).
    func isSetting(_ other: SpeakerLevel) -> Bool {
        isMuted == other.isMuted && abs(volume - other.volume) < 0.005
    }
}

/// Turns the built-in speakers on for as long as `$sound` plays, then puts
/// them back. Sounds overlap, so the speakers are restored when the last one
/// ends, and not at all if you changed them in between.
@MainActor
final class SpeakerBoost {
    static let shared = SpeakerBoost(read: Speakers.level, write: Speakers.set)

    private let read: () -> SpeakerLevel?
    private let write: (SpeakerLevel) -> Void
    private var active = 0
    private var restoring: (original: SpeakerLevel, boosted: SpeakerLevel)?

    /// `read` is nil while the built-in speakers are not the output.
    init(read: @escaping () -> SpeakerLevel?, write: @escaping (SpeakerLevel) -> Void) {
        self.read = read
        self.write = write
    }

    func begin() {
        active += 1
        guard restoring == nil, let original = read(), let boosted = original.audible else { return }
        restoring = (original, boosted)
        write(boosted)
    }

    func end() {
        active = max(active - 1, 0)
        guard active == 0, let (original, boosted) = restoring else { return }
        restoring = nil
        if let now = read(), now.isSetting(boosted) { write(original) }
    }
}

/// CoreAudio's view of the default output, when that is the built-in speakers
/// (not the headphone jack, HDMI, USB or Bluetooth).
private enum Speakers {
    static func level() -> SpeakerLevel? {
        guard let device = builtInSpeakers(), let volume = get(Float32.self, device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume) else { return nil }
        return SpeakerLevel(isMuted: get(UInt32.self, device, kAudioDevicePropertyMute) == 1, volume: volume)
    }

    static func set(_ level: SpeakerLevel) {
        guard let device = builtInSpeakers() else { return }
        put(level.volume, device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        put(UInt32(level.isMuted ? 1 : 0), device, kAudioDevicePropertyMute)
    }

    /// 'ispk': the speakers inside the Mac, as opposed to 'hdpn' on the same chip.
    private static let internalSpeaker: UInt32 = 0x6973_706B

    private static func builtInSpeakers() -> AudioObjectID? {
        guard let device = get(AudioObjectID.self, AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              device != kAudioObjectUnknown,
              get(UInt32.self, device, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn,
              get(UInt32.self, device, kAudioDevicePropertyDataSource) == internalSpeaker else { return nil }
        return device
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        // The system object and the device's transport are global; the rest is of the output.
        let global = selector == kAudioHardwarePropertyDefaultOutputDevice || selector == kAudioDevicePropertyTransportType
        return AudioObjectPropertyAddress(mSelector: selector, mScope: global ? kAudioObjectPropertyScopeGlobal : kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func get<Value: BitwiseCopyable>(_: Value.Type, _ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Value? {
        var address = address(selector)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        return withUnsafeTemporaryAllocation(of: Value.self, capacity: 1) { buffer in
            var size = UInt32(MemoryLayout<Value>.size)
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!) == noErr else { return nil }
            return buffer[0]
        }
    }

    private static func put<Value>(_ value: Value, _ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = address(selector)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &address),
              AudioObjectIsPropertySettable(object, &address, &settable) == noErr, settable.boolValue else { return }
        var value = value
        AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Value>.size), &value)
    }
}
