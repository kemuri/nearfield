import CoreAudio
import Foundation

enum RouterAudioDriverError: LocalizedError {
    case notInstalled
    case configurationFailed(String, OSStatus)
    case defaultOutputFailed(OSStatus)
    case balanceFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "NearfieldAudioDevice.driver is not installed or CoreAudio has not loaded it yet."
        case .configurationFailed(let setting, let status):
            return "Configuring router driver setting '\(setting)' failed with CoreAudio status \(status)."
        case .defaultOutputFailed(let status):
            return "Selecting the Nearfield router output failed with CoreAudio status \(status)."
        case .balanceFailed(let channel, let status):
            return "Setting router driver \(channel) balance failed with CoreAudio status \(status)."
        }
    }
}

final class RouterAudioDriverManager {
    static let routerDeviceUID = "NearfieldAudioDevice_UID"
    static let driverTargetAggregateUID = "com.kemuri.Nearfield.DriverTargetAggregate"
    private static let routerBoxUID = "NearfieldAudioBox_UID"

    private enum ConfigType: Int32 {
        case outputDevice = 1
        case outputDeviceBufferFrameSize = 2
        case deviceName = 3
        case deviceActiveCondition = 4
        case routingEnabled = 5
        case routeRules = 6
        case driverCapabilities = 7
        case targetAggregateDevices = 8
        case targetAggregateMode = 9
    }

    private enum ActiveCondition: Int {
        case proxiedDeviceActive = 0
        case always = 2
    }

    var isInstalled: Bool {
        routerDeviceID() != nil && routerBoxID() != nil
    }

    @MainActor
    func waitUntilInstalled(timeout: TimeInterval = 30, interval: TimeInterval = 0.25) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isInstalled {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return isInstalled
    }

    func configureRouterOutput(
        targetDeviceUIDs: [String],
        mode: NearfieldOutputMode,
        fallbackTargetOutputUID: String,
        displayName: String,
        routingEnabled: Bool,
        routeRules: String
    ) throws {
        guard let boxID = routerBoxID() else {
            throw RouterAudioDriverError.notInstalled
        }

        try setConfiguratorPID(Int32(ProcessInfo.processInfo.processIdentifier), boxID: boxID)
        try setConfiguration("deviceName", value: displayName, boxID: boxID)
        if supportsDriverOwnedTargetAggregate(boxID: boxID) {
            try setConfiguration("targetAggregateDevices", value: targetDeviceUIDs.joined(separator: "\n"), boxID: boxID)
            try setConfiguration("targetAggregateMode", value: mode.rawValue, boxID: boxID)
            try setConfiguration("outputDevice", value: Self.driverTargetAggregateUID, boxID: boxID)
        } else {
            try setConfiguration("outputDevice", value: fallbackTargetOutputUID, boxID: boxID)
        }
        try setConfiguration("outputDeviceActiveCondition", value: "\(ActiveCondition.proxiedDeviceActive.rawValue)", boxID: boxID)
        try setConfiguration("routingEnabled", value: routingEnabled ? "1" : "0", boxID: boxID)
        try setConfiguration("routeRules", value: routeRules, boxID: boxID)
    }

    func supportsDriverOwnedTargetAggregate() -> Bool {
        guard let boxID = routerBoxID() else {
            return false
        }
        return supportsDriverOwnedTargetAggregate(boxID: boxID)
    }

    func setRoutingEnabled(_ enabled: Bool) throws {
        guard let boxID = routerBoxID() else {
            throw RouterAudioDriverError.notInstalled
        }
        try setConfiguratorPID(Int32(ProcessInfo.processInfo.processIdentifier), boxID: boxID)
        try setConfiguration("routingEnabled", value: enabled ? "1" : "0", boxID: boxID)
    }

    func setRouteRules(_ rules: String) throws {
        guard let boxID = routerBoxID() else {
            throw RouterAudioDriverError.notInstalled
        }
        try setConfiguratorPID(Int32(ProcessInfo.processInfo.processIdentifier), boxID: boxID)
        try setConfiguration("routeRules", value: rules, boxID: boxID)
    }

    func selectRouterAsDefaultOutput() throws {
        guard let routerDeviceID = routerDeviceID() else {
            throw RouterAudioDriverError.notInstalled
        }

        try setDefaultDevice(routerDeviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try setDefaultDevice(routerDeviceID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    func isRouterDefaultOutput() -> Bool {
        routerDeviceID() == defaultOutputDeviceID()
    }

    func setBalance(_ balance: Float32) throws {
        guard let controls = volumeControlIDs() else {
            throw RouterAudioDriverError.notInstalled
        }
        let volumes = BalanceMath.channelVolumes(
            currentLeft: volumeControlValue(controls.left),
            currentRight: volumeControlValue(controls.right),
            balance: balance
        )
        try setVolumeControl(controls.left, value: volumes.left, channel: "left")
        try setVolumeControl(controls.right, value: volumes.right, channel: "right")
    }

    private func setConfiguratorPID(_ pid: Int32, boxID: AudioObjectID) throws {
        try setIdentifyValue(pid, boxID: boxID, setting: "configuratorPID")
    }

    private func setConfiguration(_ key: String, value: String, boxID: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let configuration = "\(key)=\(value)" as CFString
        var configurationPointer = Unmanaged.passUnretained(configuration).toOpaque()
        let status = AudioObjectSetPropertyData(
            boxID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UnsafeRawPointer>.size),
            &configurationPointer
        )
        guard status == noErr else {
            throw RouterAudioDriverError.configurationFailed(key, status)
        }
    }

    private func supportsDriverOwnedTargetAggregate(boxID: AudioObjectID) -> Bool {
        guard let capabilities = try? configurationValue(.driverCapabilities, boxID: boxID) else {
            return false
        }
        return capabilities
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains("driverOwnedTargetAggregate")
    }

    private func configurationValue(_ type: ConfigType, boxID: AudioObjectID) throws -> String? {
        try setIdentifyValue(-type.rawValue, boxID: boxID, setting: "configurationRead")
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            boxID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        guard status == noErr else {
            throw RouterAudioDriverError.configurationFailed("configurationRead", status)
        }
        return value?.takeRetainedValue() as String?
    }

    private func setIdentifyValue(_ value: Int32, boxID: AudioObjectID, setting: String) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyIdentify,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableValue = value
        let status = AudioObjectSetPropertyData(
            boxID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Int32>.size),
            &mutableValue
        )
        guard status == noErr else {
            throw RouterAudioDriverError.configurationFailed(setting, status)
        }
    }

    private func setDefaultDevice(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableID
        )
        guard status == noErr else {
            throw RouterAudioDriverError.defaultOutputFailed(status)
        }
    }

    private func routerDeviceID() -> AudioObjectID? {
        audioObjectID(forUID: Self.routerDeviceUID, selector: kAudioHardwarePropertyTranslateUIDToDevice)
    }

    private func routerBoxID() -> AudioObjectID? {
        audioObjectID(forUID: Self.routerBoxUID, selector: kAudioHardwarePropertyTranslateUIDToBox)
    }

    private func setVolumeControl(_ controlID: AudioObjectID, value: Float32, channel: String) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableValue = value
        let status = AudioObjectSetPropertyData(
            controlID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableValue
        )
        guard status == noErr else {
            throw RouterAudioDriverError.balanceFailed(channel, status)
        }
    }

    private func volumeControlValue(_ controlID: AudioObjectID) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioLevelControlPropertyScalarValue,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float32(0)
        var dataSize = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(controlID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
    }

    private func volumeControlIDs() -> (left: AudioObjectID, right: AudioObjectID)? {
        guard let deviceID = routerDeviceID() else { return nil }
        let controls = ownedObjectIDs(for: deviceID).filter { objectID in
            classID(for: objectID) == kAudioVolumeControlClassID &&
                controlScope(for: objectID) == kAudioObjectPropertyScopeOutput
        }

        guard let left = controls.first(where: { controlElement(for: $0) == 1 }),
              let right = controls.first(where: { controlElement(for: $0) == 2 }) else {
            return nil
        }
        return (left, right)
    }

    private func ownedObjectIDs(for objectID: AudioObjectID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyOwnedObjects,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioObjectID>.size) else {
            return []
        }

        var ids = Array(repeating: AudioObjectID(0), count: Int(dataSize) / MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &ids)
        return status == noErr ? ids : []
    }

    private func classID(for objectID: AudioObjectID) -> AudioClassID? {
        getUInt32Property(objectID, selector: kAudioObjectPropertyClass)
    }

    private func controlScope(for objectID: AudioObjectID) -> AudioObjectPropertyScope? {
        getUInt32Property(objectID, selector: kAudioControlPropertyScope)
    }

    private func controlElement(for objectID: AudioObjectID) -> AudioObjectPropertyElement? {
        getUInt32Property(objectID, selector: kAudioControlPropertyElement)
    }

    private func getUInt32Property(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private func audioObjectID(forUID uid: String, selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let uidRef = uid as CFString
        var uidPointer = Unmanaged.passUnretained(uidRef).toOpaque()
        var result = AudioObjectID(kAudioObjectUnknown)
        var resultSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<UnsafeRawPointer>.size),
            &uidPointer,
            &resultSize,
            &result
        )
        return status == noErr && result != kAudioObjectUnknown ? result : nil
    }
}
