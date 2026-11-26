import Foundation
import CoreAudio

public struct NoteCaptureOptions: Sendable {
    public var microphoneUID = ""
    public var startMuted = false
    public var autoMute = false
    public var screenQuality = "standard"
    public var screenAudio = "mixed"
    public init() {}
}

public enum NoteMicrophoneDevices {
    public struct Device: Identifiable, Sendable {
        public let id: String
        public let name: String
    }
    public static func available() -> [Device] {
        devices().compactMap { device in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0,
                  let uid = string(device, selector: kAudioDevicePropertyDeviceUID), let name = string(device, selector: kAudioObjectPropertyName) else { return nil }
            return Device(id: uid, name: name)
        }
    }
    static func deviceID(uid: String) -> AudioDeviceID? {
        if !uid.isEmpty { return devices().first { string($0, selector: kAudioDevicePropertyDeviceUID) == uid } }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { return nil }
        return device
    }
    public static func isMuted(uid: String) -> Bool {
        guard let device = deviceID(uid: uid) else { return false }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return false }
        return muted != 0
    }
    private static func devices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var values = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !values.isEmpty else { return [] }
        let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!) }
        return status == noErr ? values : []
    }
    private static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString, size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, UnsafeMutableRawPointer($0)) }
        guard status == noErr else { return nil }
        return value as String
    }
}
