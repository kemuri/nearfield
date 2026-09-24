import CoreAudio
import Foundation

enum ProcessAudioPlayback {
    struct Properties {
        var processObjects: () -> [AudioObjectID]
        var outputIsRunning: (AudioObjectID) -> Bool
        var processID: (AudioObjectID) -> Int32?
        var outputDevices: (AudioObjectID) -> [AudioObjectID]
        var deviceUID: (AudioObjectID) -> String?

        @available(macOS 14.2, *)
        static var coreAudio: Properties {
            Properties(
                processObjects: { objectIDs(on: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList) },
                outputIsRunning: { CoreAudioProperty.read(from: $0, selector: kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1 },
                processID: { CoreAudioProperty.read(from: $0, selector: kAudioProcessPropertyPID, as: Int32.self) },
                outputDevices: { objectIDs(on: $0, selector: kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput) },
                deviceUID: { string(on: $0, selector: kAudioDevicePropertyDeviceUID) }
            )
        }
    }

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    @available(macOS 14.2, *)
    static func processObjects() -> [AudioObjectID] {
        objectIDs(on: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
    }

    static func activeOutputs() -> [RouterConnectionHandoff.Playback] {
        guard #available(macOS 14.2, *) else { return [] }
        return activeOutputs(using: .coreAudio)
    }

    static func activeOutputs(
        using properties: Properties,
        excludingProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) -> [RouterConnectionHandoff.Playback] {
        properties.processObjects().compactMap { process in
            guard properties.outputIsRunning(process),
                  let pid = properties.processID(process), pid > 0,
                  pid != excludingProcessID else { return nil }
            let devices = properties.outputDevices(process)
            let uids = devices.compactMap(properties.deviceUID)
            guard !uids.isEmpty, uids.count == devices.count else { return nil }
            return RouterConnectionHandoff.Playback(processID: pid, outputUIDs: Set(uids))
        }
    }

    static func string(on object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func objectIDs(
        on object: AudioObjectID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size > 0, size.isMultiple(of: UInt32(MemoryLayout<AudioObjectID>.size)) else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values) == noErr else { return [] }
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}
