import CoreAudio
import Foundation

enum RouterAudioDriverError: LocalizedError {
    case notInstalled
    case unsupportedDriver
    case unsupportedThreeDisplayDriver
    case unsupportedReadinessDriver
    case configurationFailed(String, OSStatus)
    case defaultOutputFailed(OSStatus)
    case balanceFailed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "NearfieldAudioDevice.driver is not installed or CoreAudio has not loaded it yet."
        case .unsupportedDriver:
            return "The installed Nearfield audio driver is outdated and does not support private target routing. Reinstall the driver from Nearfield Settings."
        case .unsupportedThreeDisplayDriver:
            return "The installed Nearfield audio driver is outdated and does not support three-display output. Reinstall the driver from Nearfield Settings."
        case .unsupportedReadinessDriver:
            return "Update the audio driver in Nearfield Settings to enable reliable automatic output switching."
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
    static let routerDeviceUID = NearfieldAudioIdentifiers.routerDeviceUID
    static let driverTargetAggregateUID = NearfieldAudioIdentifiers.driverTargetAggregateUID
    private static let routerBoxUID = NearfieldAudioIdentifiers.routerBoxUID

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
        case targetOutputReadiness = 10
    }

    private enum ActiveCondition: Int {
        case proxiedDeviceActive = 0
        case always = 2
    }

    /// What was last sent to a 1.1 driver instance; only differences are sent.
    private var appliedSettings: RouterDriverSettings?
    private var appliedSettingsInstance: Int64?
    /// What was last sent through the legacy channel, per box object.
    private var appliedLegacyValues: [String: String] = [:]
    private var appliedLegacyBoxID: AudioObjectID?
    private var legacyCapabilities: (boxID: AudioObjectID, value: String?)?
    private var statusObservation: (boxID: AudioObjectID, block: AudioObjectPropertyListenerBlock)?
    /// The device's control objects, which only change with the device.
    private var cachedControls: (deviceID: AudioObjectID, left: AudioObjectID, right: AudioObjectID, mute: AudioObjectID?)?

    var isInstalled: Bool {
        routerBoxID() != nil
    }

    /// Driver 1.1.0 and later: settings and status are dictionaries on the box.
    var supportsSettingsProperty: Bool {
        routerBoxID().map(hasSettingsProperty(boxID:)) ?? false
    }

    /// Forget what was sent, for example after the driver was reinstalled.
    func resetAppliedSettings() {
        appliedSettings = nil
        appliedSettingsInstance = nil
        appliedLegacyValues = [:]
        appliedLegacyBoxID = nil
        legacyCapabilities = nil
    }

    func configureRouterOutput(
        targetDeviceUIDs: [String],
        mode: NearfieldOutputMode,
        displayName: String,
        routingEnabled: Bool,
        routeRules: String
    ) throws {
        let split = RouterRouteRules.split(routeRules)
        try configure(RouterDriverSettings(
            deviceName: displayName,
            targetDevices: targetDeviceUIDs,
            mode: mode,
            routingEnabled: routingEnabled,
            routeRules: split.rules,
            processRoutes: split.processRoutes,
            diagnostics: NearfieldPreferences.driverDiagnostics(),
            underrunStrategy: NearfieldPreferences.driverUnderrunStrategy()
        ), legacyRouteRules: routeRules)
    }

    func setRoutingEnabled(_ enabled: Bool) throws {
        guard let boxID = routerBoxID() else {
            throw RouterAudioDriverError.notInstalled
        }
        if hasSettingsProperty(boxID: boxID) {
            try sendChanges(["routingEnabled": enabled], boxID: boxID)
            appliedSettings?.routingEnabled = enabled
        } else {
            try setLegacyConfiguration("routingEnabled", value: enabled ? "1" : "0", boxID: boxID)
        }
    }

    /// Resolved rules may contain window-following process routes, which a
    /// 1.1 driver applies on its next audio cycle without saving them.
    func setRouteRules(_ rules: String) throws {
        guard let boxID = routerBoxID() else {
            throw RouterAudioDriverError.notInstalled
        }
        if hasSettingsProperty(boxID: boxID) {
            if readStatus(boxID: boxID)?.instance != appliedSettingsInstance {
                // A restarted driver lost the process routes; send both again.
                appliedSettings = nil
            }
            let split = RouterRouteRules.split(rules)
            var changes: [String: Any] = [:]
            if appliedSettings?.routeRules != split.rules { changes["routeRules"] = split.rules }
            if appliedSettings?.processRoutes != split.processRoutes {
                changes["processRoutes"] = Dictionary(uniqueKeysWithValues: split.processRoutes.map { (String($0.key), $0.value) })
            }
            guard !changes.isEmpty else { return }
            try sendChanges(changes, boxID: boxID)
            appliedSettings?.routeRules = split.rules
            appliedSettings?.processRoutes = split.processRoutes
        } else {
            try setLegacyConfiguration("routeRules", value: rules, boxID: boxID)
        }
    }

    func setPublished(_ published: Bool) throws {
        guard let boxID = routerBoxID() else {
            throw RouterAudioDriverError.notInstalled
        }
        let current: UInt32? = CoreAudioProperty.read(from: boxID, selector: kAudioBoxPropertyAcquired)
        guard current.map({ ($0 != 0) != published }) ?? true else { return }
        let status = CoreAudioProperty.write(
            UInt32(published ? 1 : 0),
            to: boxID,
            selector: kAudioBoxPropertyAcquired
        )
        guard status == noErr else {
            throw RouterAudioDriverError.configurationFailed("devicePublished", status)
        }
    }

    /// The driver's status (driver 1.1.0 and later), or nil for older drivers.
    func status() -> RouterDriverStatus? {
        guard let boxID = routerBoxID(), hasSettingsProperty(boxID: boxID) else { return nil }
        return readStatus(boxID: boxID)
    }

    /// Calls |handler| on the main queue whenever the driver's status changes.
    /// Returns false for drivers without status notifications. Call again
    /// after Core Audio restarts; it re-registers when the box changed.
    @discardableResult
    func observeStatus(_ handler: @escaping () -> Void) -> Bool {
        guard let boxID = routerBoxID(), hasSettingsProperty(boxID: boxID) else {
            stopObservingStatus()
            return false
        }
        if statusObservation?.boxID == boxID {
            return true
        }
        stopObservingStatus()
        var address = Self.address(RouterDriverProperty.status)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(boxID, &address, .main, block) == noErr else {
            return false
        }
        statusObservation = (boxID, block)
        return true
    }

    func stopObservingStatus() {
        guard let observation = statusObservation else { return }
        var address = Self.address(RouterDriverProperty.status)
        AudioObjectRemovePropertyListenerBlock(observation.boxID, &address, .main, observation.block)
        statusObservation = nil
    }

    private func configure(_ settings: RouterDriverSettings, legacyRouteRules: String) throws {
        guard let boxID = routerBoxID() else {
            throw RouterAudioDriverError.notInstalled
        }
        guard hasSettingsProperty(boxID: boxID) else {
            try configureLegacy(settings, routeRules: legacyRouteRules, boxID: boxID)
            return
        }
        let status = readStatus(boxID: boxID)
        guard status?.capabilities.contains("driverOwnedTargetAggregate") ?? false else {
            throw RouterAudioDriverError.unsupportedDriver
        }
        if settings.targetDevices.count >= 3,
           !(status?.capabilities.contains("threeDisplayTargetAggregate") ?? false) {
            throw RouterAudioDriverError.unsupportedThreeDisplayDriver
        }
        if status?.instance != appliedSettingsInstance {
            // A restarted driver lost the process routes; send everything.
            appliedSettings = nil
        }
        let changes = settings.changes(since: appliedSettings)
        guard !changes.isEmpty else { return }
        try sendChanges(changes, boxID: boxID)
        appliedSettings = settings
        appliedSettingsInstance = status?.instance
    }

    private func sendChanges(_ changes: [String: Any], boxID: AudioObjectID) throws {
        var address = Self.address(RouterDriverProperty.settings)
        var dictionary = changes as CFDictionary
        let status = withUnsafeMutablePointer(to: &dictionary) { pointer in
            AudioObjectSetPropertyData(boxID, &address, 0, nil, UInt32(MemoryLayout<CFDictionary>.size), pointer)
        }
        guard status == noErr else {
            throw RouterAudioDriverError.configurationFailed("settings", status)
        }
    }

    private func readStatus(boxID: AudioObjectID) -> RouterDriverStatus? {
        var address = Self.address(RouterDriverProperty.status)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        guard AudioObjectGetPropertyData(boxID, &address, 0, nil, &size, &value) == noErr,
              let dictionary = value?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return RouterDriverStatus(dictionary: dictionary)
    }

    private func hasSettingsProperty(boxID: AudioObjectID) -> Bool {
        var address = Self.address(RouterDriverProperty.settings)
        return AudioObjectHasProperty(boxID, &address)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: Legacy configuration channel (drivers before 1.1.0)

    private func configureLegacy(_ settings: RouterDriverSettings, routeRules: String, boxID: AudioObjectID) throws {
        let capabilities = try legacyCapabilities(boxID: boxID)
        guard Self.supportsDriverOwnedTargetAggregate(in: capabilities) else {
            throw RouterAudioDriverError.unsupportedDriver
        }
        if settings.targetDevices.count >= 3,
           !Self.supportsThreeDisplayTargetAggregate(in: capabilities) {
            throw RouterAudioDriverError.unsupportedThreeDisplayDriver
        }
        try setLegacyConfiguration("deviceName", value: settings.deviceName, boxID: boxID)
        try setLegacyConfiguration("targetAggregateDevices", value: settings.targetDevices.joined(separator: "\n"), boxID: boxID)
        try setLegacyConfiguration("targetAggregateMode", value: settings.mode.rawValue, boxID: boxID)
        try setLegacyConfiguration("outputDevice", value: Self.driverTargetAggregateUID, boxID: boxID)
        try setLegacyConfiguration("outputDeviceActiveCondition", value: "\(ActiveCondition.proxiedDeviceActive.rawValue)", boxID: boxID)
        try setLegacyConfiguration("routingEnabled", value: settings.routingEnabled ? "1" : "0", boxID: boxID)
        try setLegacyConfiguration("routeRules", value: routeRules, boxID: boxID)
    }

    private func legacyCapabilities(boxID: AudioObjectID) throws -> String? {
        if let cached = legacyCapabilities, cached.boxID == boxID {
            return cached.value
        }
        let value = try? configurationValue(.driverCapabilities, boxID: boxID)
        legacyCapabilities = (boxID, value ?? nil)
        return value ?? nil
    }

    private func setLegacyConfiguration(_ key: String, value: String, boxID: AudioObjectID) throws {
        if appliedLegacyBoxID != boxID {
            appliedLegacyValues = [:]
            appliedLegacyBoxID = boxID
        }
        guard appliedLegacyValues[key] != value else { return }
        try setConfiguratorPID(Int32(ProcessInfo.processInfo.processIdentifier), boxID: boxID)
        try setConfiguration(key, value: value, boxID: boxID)
        appliedLegacyValues[key] = value
    }

    func selectRouterAsDefaultOutput() throws {
        guard let routerDeviceID = routerDeviceID() else {
            throw RouterAudioDriverError.notInstalled
        }

        if defaultOutputDeviceID() != routerDeviceID {
            try setDefaultDevice(routerDeviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
        }
        if defaultDeviceID(selector: kAudioHardwarePropertyDefaultSystemOutputDevice) != routerDeviceID {
            try setDefaultDevice(routerDeviceID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
    }

    func targetOutputIsReady(deviceUIDs: [String], mode: NearfieldOutputMode) throws -> Bool {
        guard let boxID = routerBoxID() else { return false }
        if hasSettingsProperty(boxID: boxID) {
            return readStatus(boxID: boxID)?.isReady(deviceUIDs: deviceUIDs, mode: mode) ?? false
        }
        let capabilities = try legacyCapabilities(boxID: boxID)
        guard Self.capabilityTokens(in: capabilities).contains("targetOutputReadiness") else {
            throw RouterAudioDriverError.unsupportedReadinessDriver
        }
        return Self.readinessMatches(
            try configurationValue(.targetOutputReadiness, boxID: boxID),
            deviceUIDs: deviceUIDs, mode: mode
        )
    }

    static func readinessMatches(_ status: String?, deviceUIDs: [String], mode: NearfieldOutputMode) -> Bool {
        guard (2...3).contains(deviceUIDs.count) else { return false }
        return status == (["ready", mode.rawValue] + deviceUIDs).joined(separator: "\n")
    }

    func currentDefaultOutputUID() -> String? {
        defaultOutputDeviceID().flatMap {
            ProcessAudioPlayback.string(on: $0, selector: kAudioDevicePropertyDeviceUID)
        }
    }

    func selectPreviousOutputForRecovery(uid: String, displayUIDs: [String]) throws {
        // Display outputs are prepared at unity gain for the router. Never
        // briefly make one of those full-volume endpoints the direct output.
        guard !displayUIDs.contains(uid), !NearfieldAudioIdentifiers.virtualOutputUIDs.contains(uid),
              uid != Self.driverTargetAggregateUID,
              let device = audioObjectID(forUID: uid, selector: kAudioHardwarePropertyTranslateUIDToDevice),
              CoreAudioProperty.read(from: device, selector: kAudioDevicePropertyDeviceIsAlive, as: UInt32.self) == 1 else {
            throw RouterConnectionHandoff.Failure.playbackDidNotFollow
        }
        try setDefaultDevice(device, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    func isRouterDefaultOutput() -> Bool {
        routerDeviceID() == defaultOutputDeviceID()
    }

    func currentBaseVolume() -> Float32? {
        guard let controls = volumeControlIDs(),
              let left = volumeControlValue(controls.left),
              let right = volumeControlValue(controls.right) else {
            return nil
        }
        return max(left, right)
    }

    func currentAudibleGain() -> Float32? {
        guard !isMuted() else { return 0 }
        guard let controls = volumeControlIDs(),
              let leftScalar = volumeControlValue(controls.left),
              let rightScalar = volumeControlValue(controls.right) else {
            return nil
        }
        let louderControl = leftScalar >= rightScalar ? controls.left : controls.right
        let louderScalar = max(leftScalar, rightScalar)
        guard louderScalar > 0 else { return 0 }
        guard let decibels: Float32 = CoreAudioProperty.read(
            from: louderControl,
            selector: kAudioLevelControlPropertyDecibelValue
        ) else {
            return louderScalar
        }
        return min(max(powf(10, decibels / 20), 0), 1)
    }

    /// Applies |balance| around the current master volume. Writes nothing
    /// when the channels already match.
    func setBalance(_ balance: Float32) throws {
        guard let controls = volumeControlIDs() else {
            throw RouterAudioDriverError.notInstalled
        }
        let currentLeft = volumeControlValue(controls.left)
        let currentRight = volumeControlValue(controls.right)
        let volumes = BalanceMath.channelVolumes(
            currentLeft: currentLeft,
            currentRight: currentRight,
            balance: balance
        )
        if let currentLeft, abs(currentLeft - volumes.left) < 0.0001,
           let currentRight, abs(currentRight - volumes.right) < 0.0001 {
            return
        }
        try setVolumeControl(controls.left, value: volumes.left, channel: "left")
        try setVolumeControl(controls.right, value: volumes.right, channel: "right")
    }

    func setBalancedVolume(_ volume: Float32, balance: Float32) throws {
        guard let controls = volumeControlIDs() else {
            throw RouterAudioDriverError.notInstalled
        }
        let clampedVolume = min(max(volume, 0), 1)
        let volumes = BalanceMath.channelVolumes(
            currentLeft: clampedVolume,
            currentRight: clampedVolume,
            balance: balance
        )
        try setVolumeControl(controls.left, value: volumes.left, channel: "left")
        try setVolumeControl(controls.right, value: volumes.right, channel: "right")
    }

    /// Moves Nearfield's volume by |decibels| within its range, keeping
    /// |balance|. Returns the change actually applied.
    func shiftBaseVolume(byDecibels decibels: Float32, balance: Float32) throws -> Float32 {
        guard decibels != 0 else { return 0 }
        guard let controls = volumeControlIDs(), let base = currentBaseVolume() else {
            throw RouterAudioDriverError.notInstalled
        }
        guard let current = convertLevel(base, on: controls.left, selector: kAudioLevelControlPropertyConvertScalarToDecibels),
              let range: AudioValueRange = CoreAudioProperty.read(
                from: controls.left,
                selector: kAudioLevelControlPropertyDecibelRange
              ) else {
            throw RouterAudioDriverError.configurationFailed("volume in decibels", kAudioHardwareUnknownPropertyError)
        }
        let target = min(max(current + decibels, Float32(range.mMinimum)), Float32(range.mMaximum))
        guard let scalar = convertLevel(target, on: controls.left, selector: kAudioLevelControlPropertyConvertDecibelsToScalar) else {
            throw RouterAudioDriverError.configurationFailed("volume in decibels", kAudioHardwareUnknownPropertyError)
        }
        try setBalancedVolume(scalar, balance: balance)
        return target - current
    }

    private func convertLevel(_ value: Float32, on control: AudioObjectID, selector: AudioObjectPropertySelector) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var data = value
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(control, &address, 0, nil, &size, &data) == noErr, data.isFinite else {
            return nil
        }
        return data
    }

    func adjustVolume(by delta: Float32, balance: Float32) throws {
        guard let controls = volumeControlIDs() else {
            throw RouterAudioDriverError.notInstalled
        }
        let currentLeft = volumeControlValue(controls.left) ?? 0.5
        let currentRight = volumeControlValue(controls.right) ?? 0.5
        let volumes = BalanceMath.adjustedChannelVolumes(
            currentLeft: currentLeft,
            currentRight: currentRight,
            delta: delta,
            balance: balance
        )
        let nextBase = max(volumes.left, volumes.right)
        if nextBase > 0 {
            try setMuted(false)
        }
        try setVolumeControl(controls.left, value: volumes.left, channel: "left")
        try setVolumeControl(controls.right, value: volumes.right, channel: "right")
    }

    func toggleMute() throws {
        try setMuted(!isMuted())
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

    static func supportsDriverOwnedTargetAggregate(in capabilities: String?) -> Bool {
        capabilityTokens(in: capabilities)
            .contains("driverOwnedTargetAggregate")
    }

    static func supportsThreeDisplayTargetAggregate(in capabilities: String?) -> Bool {
        capabilityTokens(in: capabilities)
            .contains("threeDisplayTargetAggregate")
    }

    private static func capabilityTokens(in capabilities: String?) -> [String] {
        capabilities?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? []
    }

    private func configurationValue(_ type: ConfigType, boxID: AudioObjectID) throws -> String? {
        try setConfiguratorPID(Int32(ProcessInfo.processInfo.processIdentifier), boxID: boxID)
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
        let status = CoreAudioProperty.write(
            value,
            to: boxID,
            selector: kAudioObjectPropertyIdentify
        )
        guard status == noErr else {
            throw RouterAudioDriverError.configurationFailed(setting, status)
        }
    }

    private func setDefaultDevice(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) throws {
        let status = CoreAudioProperty.write(
            deviceID,
            to: AudioObjectID(kAudioObjectSystemObject),
            selector: selector
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
        let status = CoreAudioProperty.write(
            value,
            to: controlID,
            selector: kAudioLevelControlPropertyScalarValue
        )
        guard status == noErr else {
            throw RouterAudioDriverError.balanceFailed(channel, status)
        }
    }

    private func volumeControlValue(_ controlID: AudioObjectID) -> Float32? {
        CoreAudioProperty.read(
            from: controlID,
            selector: kAudioLevelControlPropertyScalarValue,
            as: Float32.self
        )
    }

    private func setMuted(_ muted: Bool) throws {
        guard let controlID = muteControlID() else {
            throw RouterAudioDriverError.notInstalled
        }
        let status = CoreAudioProperty.write(
            UInt32(muted ? 1 : 0),
            to: controlID,
            selector: kAudioBooleanControlPropertyValue
        )
        guard status == noErr else {
            throw RouterAudioDriverError.balanceFailed("mute", status)
        }
    }

    private func isMuted() -> Bool {
        guard let controlID = muteControlID() else { return false }
        let value: UInt32? = CoreAudioProperty.read(
            from: controlID,
            selector: kAudioBooleanControlPropertyValue
        )
        return value.map { $0 != 0 } ?? false
    }

    private func volumeControlIDs() -> (left: AudioObjectID, right: AudioObjectID)? {
        guard let deviceID = routerDeviceID() else { return nil }
        if let cached = cachedControls, cached.deviceID == deviceID {
            return (cached.left, cached.right)
        }
        let controls = ownedObjectIDs(for: deviceID).filter { objectID in
            classID(for: objectID) == kAudioVolumeControlClassID &&
                controlScope(for: objectID) == kAudioObjectPropertyScopeOutput
        }

        guard let left = controls.first(where: { controlElement(for: $0) == 1 }),
              let right = controls.first(where: { controlElement(for: $0) == 2 }) else {
            return nil
        }
        let mute = ownedObjectIDs(for: deviceID).first { objectID in
            classID(for: objectID) == kAudioMuteControlClassID &&
                controlScope(for: objectID) == kAudioObjectPropertyScopeOutput
        }
        cachedControls = (deviceID, left, right, mute)
        return (left, right)
    }

    private func muteControlID() -> AudioObjectID? {
        guard let deviceID = routerDeviceID() else { return nil }
        if cachedControls?.deviceID != deviceID {
            _ = volumeControlIDs()
        }
        return cachedControls?.deviceID == deviceID ? cachedControls?.mute : nil
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
        CoreAudioProperty.read(
            from: objectID,
            selector: selector,
            as: UInt32.self
        )
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func defaultDeviceID(selector: AudioObjectPropertySelector) -> AudioObjectID? {
        let id: AudioObjectID? = CoreAudioProperty.read(
            from: AudioObjectID(kAudioObjectSystemObject),
            selector: selector
        )
        return id.flatMap { $0 == 0 ? nil : $0 }
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
