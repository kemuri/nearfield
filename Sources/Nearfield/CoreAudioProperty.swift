import CoreAudio
import Darwin

enum CoreAudioProperty {
    static func read<Value: BitwiseCopyable>(
        from objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        as _: Value.Type = Value.self
    ) -> Value? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var size = UInt32(MemoryLayout<Value>.size)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<Value>.size,
            alignment: MemoryLayout<Value>.alignment
        )
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<Value>.size)
        defer { storage.deallocate() }
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            storage
        )
        return status == noErr ? storage.load(as: Value.self) : nil
    }

    static func write<Value: BitwiseCopyable>(
        _ value: Value,
        to objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> OSStatus {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var mutableValue = value
        return AudioObjectSetPropertyData(
            objectID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Value>.size),
            &mutableValue
        )
    }

    static func isSettable(
        on objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        guard AudioObjectHasProperty(objectID, &address) else {
            return false
        }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr &&
            settable.boolValue
    }
}
