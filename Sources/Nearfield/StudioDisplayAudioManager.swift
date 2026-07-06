import CoreAudio
import Foundation

struct NearfieldState {
    let detectedDisplays: [AudioDevice]
    let aggregateDeviceID: AudioObjectID?
    let isAggregateDefaultOutput: Bool

    var headline: String {
        if detectedDisplays.count < 2 {
            return "Connect two Studio Displays"
        }
        if isAggregateDefaultOutput {
            return "Nearfield is active"
        }
        if aggregateDeviceID != nil {
            return "Nearfield is ready"
        }
        return "Two Studio Displays found"
    }

    var details: String {
        if detectedDisplays.isEmpty {
            return "No Studio Display speakers found"
        }
        return detectedDisplays.map(\.name).joined(separator: " + ")
    }
}

struct AudioDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let outputChannelCount: UInt32

    func displayName(index: Int) -> String {
        return "Display \(index + 1) - \(name) (\(shortIdentifier))"
    }

    private var shortIdentifier: String {
        let parts = uid.split(separator: ":")
        guard parts.count >= 2 else {
            return String(uid.suffix(10))
        }
        return String(parts[parts.count - 2].suffix(8))
    }
}

enum NearfieldOutputMode: String, CaseIterable {
    case stereo
    case mono

    var title: String {
        switch self {
        case .stereo:
            return "Stereo"
        case .mono:
            return "Mono"
        }
    }
}

struct NearfieldConfiguration {
    var mode: NearfieldOutputMode
    var leftDeviceUID: String?
}

struct DisplayOutputState: Codable {
    let deviceUID: String
    let volume: Float32?
    let isMuted: Bool?
}

enum NearfieldError: LocalizedError {
    case notEnoughStudioDisplays(Int)
    case coreAudio(operation: String, status: OSStatus)
    case aggregateMissing
    case studioPairNotActive

    var errorDescription: String? {
        switch self {
        case .notEnoughStudioDisplays(let count):
            return "Found \(count) Studio Display speaker output(s). Two are required."
        case .coreAudio(let operation, let status):
            return "\(operation) failed with CoreAudio status \(status)."
        case .aggregateMissing:
            return "The Nearfield target device does not exist yet."
        case .studioPairNotActive:
            return "Nearfield is not the current output."
        }
    }
}

final class StudioDisplayAudioManager {
    let aggregateUID = "com.kemuri.Nearfield.TargetAggregate"
    let aggregateName = "Nearfield Target"
    private var observerBlocks: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var observerCallback: (() -> Void)?

    func currentState() -> NearfieldState {
        let displays = studioDisplayOutputs()
        let aggregate = device(matchingUID: aggregateUID)
        return NearfieldState(
            detectedDisplays: displays,
            aggregateDeviceID: aggregate?.id,
            isAggregateDefaultOutput: aggregate?.id == defaultOutputDeviceID()
        )
    }

    func studioDisplayDevices() -> [AudioDevice] {
        studioDisplayOutputs()
    }

    func orderedStudioDisplayUIDs(configuration: NearfieldConfiguration) throws -> [String] {
        let displays = studioDisplayOutputs()
        guard displays.count >= 2 else {
            throw NearfieldError.notEnoughStudioDisplays(displays.count)
        }
        return Self.orderedDisplays(from: displays, leftDeviceUID: configuration.leftDeviceUID)
            .prefix(2)
            .map(\.uid)
    }

    func cleanupPublicAggregates() throws {
        try moveDefaultOutputAwayFromNearfield()

        let matchingDevices = managedNearfieldAggregates()

        for device in matchingDevices {
            if device.id == defaultOutputDeviceID() {
                continue
            }
            try destroyAggregate(device.id)
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func cleanupAllNearfieldAggregates() throws {
        try moveDefaultOutputAwayFromNearfield()

        let matchingDevices = managedNearfieldAggregates()

        for device in matchingDevices {
            try destroyAggregate(device.id)
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func rebuildAggregateAndSelect(configuration: NearfieldConfiguration) throws {
        let aggregateID = try rebuildAggregate(configuration: configuration)
        try setDefaultOutputDevice(aggregateID)
    }

    @discardableResult
    func rebuildAggregate(configuration: NearfieldConfiguration) throws -> AudioObjectID {
        let managedAggregates = managedNearfieldAggregates()
        if managedAggregates.contains(where: { $0.id == defaultOutputDeviceID() || $0.id == defaultSystemOutputDeviceID() }) {
            try moveDefaultOutputAwayFromNearfield()
        }
        for existing in managedAggregates {
            if existing.id == defaultOutputDeviceID() || existing.id == defaultSystemOutputDeviceID() {
                try moveDefaultOutputAwayFromNearfield()
            }
            try destroyAggregate(existing.id)
            Thread.sleep(forTimeInterval: 0.25)
        }

        let displays = studioDisplayOutputs()
        guard displays.count >= 2 else {
            throw NearfieldError.notEnoughStudioDisplays(displays.count)
        }

        let orderedDisplays = Self.orderedDisplays(from: displays, leftDeviceUID: configuration.leftDeviceUID)
        return try createAggregate(from: orderedDisplays, mode: configuration.mode)
    }

    func selectAggregateAsDefaultOutput() throws {
        guard let aggregate = device(matchingUID: aggregateUID) else {
            throw NearfieldError.aggregateMissing
        }
        try setDefaultOutputDevice(aggregate.id)
    }

    func selectDeviceAsDefaultOutput(uid: String) throws {
        guard let device = device(matchingUID: uid) else {
            throw NearfieldError.aggregateMissing
        }
        try setDefaultOutputDevice(device.id)
    }

    func isDefaultOutputDevice(uid: String) -> Bool {
        device(matchingUID: uid)?.id == defaultOutputDeviceID()
    }

    func isDefaultSystemOutputDevice(uid: String) -> Bool {
        device(matchingUID: uid)?.id == defaultSystemOutputDeviceID()
    }

    func selectFallbackOutputAsDefault() throws {
        let devices = allDevices()
        guard let fallback = fallbackOutputDevice(from: devices) else {
            return
        }
        try setDefaultOutputDevice(fallback.id)
    }

    func moveDefaultOutputAwayFromNearfield() throws {
        let devices = allDevices()
        let nearfieldAggregateIDs = Set(devices.filter { isNearfieldAggregate($0) }.map(\.id))
        guard !nearfieldAggregateIDs.isEmpty else {
            return
        }

        let defaultOutput = defaultOutputDeviceID()
        let defaultSystemOutput = defaultSystemOutputDeviceID()
        guard defaultOutput.map(nearfieldAggregateIDs.contains) == true ||
                defaultSystemOutput.map(nearfieldAggregateIDs.contains) == true else {
            return
        }
        guard let fallback = fallbackOutputDevice(from: devices) else {
            return
        }

        if defaultOutput.map(nearfieldAggregateIDs.contains) == true {
            try setDefaultDevice(fallback.id, selector: kAudioHardwarePropertyDefaultOutputDevice)
        }
        if defaultSystemOutput.map(nearfieldAggregateIDs.contains) == true {
            try setDefaultDevice(fallback.id, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
        }
    }

    func adjustNearfieldVolume(by delta: Float32) throws {
        guard isAggregateDefaultOutput() else {
            throw NearfieldError.studioPairNotActive
        }

        let displays = Array(studioDisplayOutputs().prefix(2))
        guard displays.count >= 2 else {
            throw NearfieldError.notEnoughStudioDisplays(displays.count)
        }

        let currentVolume = averageVolume(for: displays) ?? 0.5
        let nextVolume = min(max(currentVolume + delta, 0), 1)
        try setMute(false, for: displays)
        try setVolume(nextVolume, for: displays)
    }

    func toggleNearfieldMute() throws {
        guard isAggregateDefaultOutput() else {
            throw NearfieldError.studioPairNotActive
        }

        let displays = Array(studioDisplayOutputs().prefix(2))
        guard displays.count >= 2 else {
            throw NearfieldError.notEnoughStudioDisplays(displays.count)
        }

        let shouldMute = !(areAllMuted(displays) ?? false)
        try setMute(shouldMute, for: displays)
    }

    func setDisplayBalance(_ balance: Float32, leftDeviceUID: String?) throws {
        let displays = studioDisplayOutputs()
        guard displays.count >= 2 else {
            throw NearfieldError.notEnoughStudioDisplays(displays.count)
        }
        let ordered = Self.orderedDisplays(from: displays, leftDeviceUID: leftDeviceUID)
        let volumes = BalanceMath.channelVolumes(
            currentLeft: volume(for: ordered[0]),
            currentRight: volume(for: ordered[1]),
            balance: balance,
            minimumBaseVolume: 0.01
        )
        try setVolume(volumes.left, for: [ordered[0]])
        try setVolume(volumes.right, for: [ordered[1]])
    }

    func prepareDisplaysForProxyOutput() throws {
        let displays = Array(studioDisplayOutputs().prefix(2))
        guard displays.count >= 2 else {
            throw NearfieldError.notEnoughStudioDisplays(displays.count)
        }

        try setMute(false, for: displays)
        try setVolume(1, for: displays)
        if let aggregate = device(matchingUID: aggregateUID) {
            try setMuteIfSupported(false, for: [aggregate])
            try setVolumeIfSupported(1, for: [aggregate])
        }
    }

    func captureDisplayOutputState() throws -> [DisplayOutputState] {
        let displays = Array(studioDisplayOutputs().prefix(2))
        guard displays.count >= 2 else {
            throw NearfieldError.notEnoughStudioDisplays(displays.count)
        }

        return displays.map { device in
            DisplayOutputState(
                deviceUID: device.uid,
                volume: volume(for: device),
                isMuted: isMuted(device)
            )
        }
    }

    func restoreDisplayOutputState(_ states: [DisplayOutputState]) throws {
        for state in states {
            guard let device = device(matchingUID: state.deviceUID) else {
                continue
            }
            if let volume = state.volume {
                try setVolume(volume, for: [device])
            }
            if let isMuted = state.isMuted {
                try setMute(isMuted, for: [device])
            }
        }
    }

    func startObserving(_ callback: @escaping () -> Void) {
        guard observerBlocks.isEmpty else { return }
        observerCallback = callback

        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultSystemOutputDevice
        ]

        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.observerCallback?()
            }
            let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            if status == noErr {
                observerBlocks.append((address, block))
            }
        }
    }

    func stopObserving() {
        for observer in observerBlocks {
            var address = observer.address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, observer.block)
        }
        observerBlocks.removeAll()
        observerCallback = nil
    }

    private func studioDisplayOutputs() -> [AudioDevice] {
        allDevices()
            .filter { $0.outputChannelCount > 0 && $0.name.localizedCaseInsensitiveContains("Studio Display") }
            .sorted { $0.uid < $1.uid }
    }

    private func allDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = Array(repeating: AudioObjectID(0), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }

        return ids.compactMap { audioDevice(for: $0) }
    }

    private func audioDevice(for id: AudioObjectID) -> AudioDevice? {
        guard let name: String = getObjectProperty(id, selector: kAudioObjectPropertyName),
              let uid: String = getObjectProperty(id, selector: kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        return AudioDevice(id: id, uid: uid, name: name, outputChannelCount: outputChannelCount(for: id))
    }

    private func managedNearfieldAggregates() -> [AudioDevice] {
        var devices = allDevices().filter { isNearfieldAggregate($0) }
        if let hiddenAggregate = device(matchingUID: aggregateUID),
           !devices.contains(where: { $0.id == hiddenAggregate.id }) {
            devices.append(hiddenAggregate)
        }
        return devices
    }

    private func outputChannelCount(for deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return 0
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferListPointer) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer.assumingMemoryBound(to: AudioBufferList.self))
        return bufferList.reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    private func device(matchingUID uid: String) -> AudioDevice? {
        if let visibleDevice = allDevices().first(where: { $0.uid == uid }) {
            return visibleDevice
        }
        guard let id = deviceID(matchingUID: uid) else {
            return nil
        }
        return audioDevice(for: id)
    }

    private func deviceID(matchingUID uid: String) -> AudioObjectID? {
        if let id = deviceID(matchingUID: uid, selector: kAudioHardwarePropertyTranslateUIDToDevice) {
            return id
        }
        return deviceID(matchingUID: uid, selector: kAudioHardwarePropertyDeviceForUID)
    }

    private func deviceID(matchingUID uid: String, selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidRef = uid as CFString
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status: OSStatus

        if selector == kAudioHardwarePropertyDeviceForUID {
            status = withUnsafeMutablePointer(to: &uidRef) { uidPointer in
                withUnsafeMutablePointer(to: &id) { idPointer in
                    var translation = AudioValueTranslation(
                        mInputData: UnsafeMutableRawPointer(uidPointer),
                        mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                        mOutputData: UnsafeMutableRawPointer(idPointer),
                        mOutputDataSize: UInt32(MemoryLayout<AudioObjectID>.size)
                    )
                    var translationSize = UInt32(MemoryLayout<AudioValueTranslation>.size)
                    return AudioObjectGetPropertyData(
                        AudioObjectID(kAudioObjectSystemObject),
                        &address,
                        0,
                        nil,
                        &translationSize,
                        &translation
                    )
                }
            }
        } else {
            status = withUnsafePointer(to: &uidRef) { uidPointer in
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    UInt32(MemoryLayout<CFString>.size),
                    uidPointer,
                    &size,
                    &id
                )
            }
        }

        return status == noErr && id != 0 ? id : nil
    }

    private func fallbackOutputDevice(from devices: [AudioDevice]) -> AudioDevice? {
        let virtualOutputUIDs: Set<String> = [
            "ProxyAudioDevice_UID",
            "StudioPairRouterAudioDevice_UID",
            "NearfieldAudioDevice_UID"
        ]
        let eligibleDevices = devices.filter {
            $0.outputChannelCount > 0 &&
                !virtualOutputUIDs.contains($0.uid) &&
                !isNearfieldAggregate($0)
        }
        return eligibleDevices.first(where: isBuiltInSpeaker) ??
            eligibleDevices.first { !$0.name.localizedCaseInsensitiveContains("Studio Display") } ??
            eligibleDevices.first
    }

    private func isBuiltInSpeaker(_ device: AudioDevice) -> Bool {
        device.name.localizedCaseInsensitiveContains("MacBook") ||
            device.name.localizedCaseInsensitiveContains("Built-in") ||
            device.name.localizedCaseInsensitiveContains("Internal Speakers")
    }

    private func isNearfieldAggregate(_ device: AudioDevice) -> Bool {
        guard classID(for: device.id) == kAudioAggregateDeviceClassID else {
            return false
        }
        let managedAggregateUIDs: Set<String> = [
            aggregateUID,
            "com.kemuri.StudioPair.Aggregate"
        ]
        let managedAggregateNames: Set<String> = [
            aggregateName,
            "Studio Pair Target",
            "Studio Pair",
            "Nearfield Target"
        ]
        return managedAggregateUIDs.contains(device.uid) || managedAggregateNames.contains(device.name)
    }

    private func isAggregateDefaultOutput() -> Bool {
        device(matchingUID: aggregateUID)?.id == defaultOutputDeviceID()
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func defaultSystemOutputDeviceID() -> AudioObjectID? {
        defaultDeviceID(selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
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

    private func classID(for objectID: AudioObjectID) -> AudioClassID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioClassID(0)
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func orderedDisplays(from displays: [AudioDevice], leftDeviceUID: String?) -> [AudioDevice] {
        let selectedDisplays = Array(displays.prefix(2))
        guard selectedDisplays.count == 2, let leftDeviceUID else {
            return selectedDisplays
        }
        guard let left = selectedDisplays.first(where: { $0.uid == leftDeviceUID }),
              let right = selectedDisplays.first(where: { $0.uid != leftDeviceUID }) else {
            return selectedDisplays
        }
        return [left, right]
    }

    private func createAggregate(from devices: [AudioDevice], mode: NearfieldOutputMode) throws -> AudioObjectID {
        let outputChannelsPerDisplay: UInt32 = 1
        let isStacked = mode == .stereo ? 1 : 0
        let subdevices: [[String: Any]] = devices.enumerated().map { index, device in
            [
                kAudioSubDeviceUIDKey: device.uid,
                kAudioSubDeviceNameKey: device.name,
                kAudioSubDeviceOutputChannelsKey: min(device.outputChannelCount, outputChannelsPerDisplay),
                kAudioSubDeviceDriftCompensationKey: index == 0 ? 0 : 1,
                kAudioSubDeviceDriftCompensationQualityKey: kAudioAggregateDriftCompensationHighQuality
            ]
        }

        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: aggregateName,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceMainSubDeviceKey: devices[0].uid,
            kAudioAggregateDeviceIsPrivateKey: 0,
            kAudioAggregateDeviceIsStackedKey: isStacked
        ]

        var aggregateID = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw NearfieldError.coreAudio(operation: "Creating aggregate device", status: status)
        }
        try hideDeviceIfSupported(aggregateID)
        return aggregateID
    }

    private func hideDeviceIfSupported(_ deviceID: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable = DarwinBoolean(false)
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        guard settableStatus == noErr, isSettable.boolValue else {
            return
        }
        try setUInt32Property(
            deviceID,
            selector: kAudioDevicePropertyIsHidden,
            scope: kAudioObjectPropertyScopeGlobal,
            element: kAudioObjectPropertyElementMain,
            value: 1,
            operation: "Hiding Nearfield target device"
        )
    }

    private func destroyAggregate(_ deviceID: AudioObjectID) throws {
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        guard status == noErr else {
            throw NearfieldError.coreAudio(operation: "Removing existing aggregate device", status: status)
        }
    }

    private func setDefaultOutputDevice(_ deviceID: AudioObjectID) throws {
        try setDefaultDevice(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try setDefaultDevice(deviceID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
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
            throw NearfieldError.coreAudio(operation: "Selecting default output", status: status)
        }
    }

    private func averageVolume(for devices: [AudioDevice]) -> Float32? {
        let values = devices.compactMap { volume(for: $0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float32(values.count)
    }

    private func volume(for device: AudioDevice) -> Float32? {
        if let master = getFloatProperty(
            device.id,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return master
        }

        let channelValues = (1...max(1, device.outputChannelCount)).compactMap { channel -> Float32? in
            getFloatProperty(
                device.id,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: channel
            )
        }
        guard !channelValues.isEmpty else { return nil }
        return channelValues.reduce(0, +) / Float32(channelValues.count)
    }

    private func setVolume(_ volume: Float32, for devices: [AudioDevice]) throws {
        for device in devices {
            let didSetVolume = try setVolumeIfSupported(volume, for: [device])
            if !didSetVolume {
                throw NearfieldError.coreAudio(
                    operation: "Setting \(device.name) volume",
                    status: kAudioHardwareUnknownPropertyError
                )
            }
        }
    }

    @discardableResult
    private func setVolumeIfSupported(_ volume: Float32, for devices: [AudioDevice]) throws -> Bool {
        var didSetAnyVolume = false
        for device in devices {
            if canSetAudioProperty(
                device.id,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: kAudioObjectPropertyElementMain
            ) {
                try setFloatProperty(
                    device.id,
                    selector: kAudioDevicePropertyVolumeScalar,
                    scope: kAudioDevicePropertyScopeOutput,
                    element: kAudioObjectPropertyElementMain,
                    value: volume,
                    operation: "Setting \(device.name) volume"
                )
                didSetAnyVolume = true
                continue
            }

            for channel in 1...max(1, device.outputChannelCount) {
                guard canSetAudioProperty(
                    device.id,
                    selector: kAudioDevicePropertyVolumeScalar,
                    scope: kAudioDevicePropertyScopeOutput,
                    element: channel
                ) else {
                    continue
                }
                try setFloatProperty(
                    device.id,
                    selector: kAudioDevicePropertyVolumeScalar,
                    scope: kAudioDevicePropertyScopeOutput,
                    element: channel,
                    value: volume,
                    operation: "Setting \(device.name) channel \(channel) volume"
                )
                didSetAnyVolume = true
            }
        }
        return didSetAnyVolume
    }

    private func areAllMuted(_ devices: [AudioDevice]) -> Bool? {
        let values = devices.compactMap { isMuted($0) }
        guard !values.isEmpty else { return nil }
        return values.allSatisfy { $0 }
    }

    private func isMuted(_ device: AudioDevice) -> Bool? {
        if let master = getUInt32Property(
            device.id,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return master != 0
        }

        let channelValues = (1...max(1, device.outputChannelCount)).compactMap { channel -> UInt32? in
            getUInt32Property(
                device.id,
                selector: kAudioDevicePropertyMute,
                scope: kAudioDevicePropertyScopeOutput,
                element: channel
            )
        }
        guard !channelValues.isEmpty else { return nil }
        return channelValues.allSatisfy { $0 != 0 }
    }

    private func setMute(_ muted: Bool, for devices: [AudioDevice]) throws {
        for device in devices {
            let didSetMute = try setMuteIfSupported(muted, for: [device])
            if !didSetMute {
                throw NearfieldError.coreAudio(
                    operation: "Setting \(device.name) mute",
                    status: kAudioHardwareUnknownPropertyError
                )
            }
        }
    }

    @discardableResult
    private func setMuteIfSupported(_ muted: Bool, for devices: [AudioDevice]) throws -> Bool {
        let value = UInt32(muted ? 1 : 0)
        var didSetAnyMute = false
        for device in devices {
            if canSetAudioProperty(
                device.id,
                selector: kAudioDevicePropertyMute,
                scope: kAudioDevicePropertyScopeOutput,
                element: kAudioObjectPropertyElementMain
            ) {
                try setUInt32Property(
                    device.id,
                    selector: kAudioDevicePropertyMute,
                    scope: kAudioDevicePropertyScopeOutput,
                    element: kAudioObjectPropertyElementMain,
                    value: value,
                    operation: "Setting \(device.name) mute"
                )
                didSetAnyMute = true
                continue
            }

            for channel in 1...max(1, device.outputChannelCount) {
                guard canSetAudioProperty(
                    device.id,
                    selector: kAudioDevicePropertyMute,
                    scope: kAudioDevicePropertyScopeOutput,
                    element: channel
                ) else {
                    continue
                }
                try setUInt32Property(
                    device.id,
                    selector: kAudioDevicePropertyMute,
                    scope: kAudioDevicePropertyScopeOutput,
                    element: channel,
                    value: value,
                    operation: "Setting \(device.name) channel \(channel) mute"
                )
                didSetAnyMute = true
            }
        }
        return didSetAnyMute
    }

    private func canSetAudioProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard AudioObjectHasProperty(objectID, &address) else {
            return false
        }
        var isSettable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(objectID, &address, &isSettable) == noErr && isSettable.boolValue
    }

    private func getFloatProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func getUInt32Property(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func setFloatProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        value: Float32,
        operation: String
    ) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var mutableValue = value
        let status = AudioObjectSetPropertyData(
            objectID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &mutableValue
        )
        guard status == noErr else {
            throw NearfieldError.coreAudio(operation: operation, status: status)
        }
    }

    private func setUInt32Property(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement,
        value: UInt32,
        operation: String
    ) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var mutableValue = value
        let status = AudioObjectSetPropertyData(
            objectID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableValue
        )
        guard status == noErr else {
            throw NearfieldError.coreAudio(operation: operation, status: status)
        }
    }

    private func getObjectProperty<T>(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFTypeRef>?
        var size = UInt32(MemoryLayout<Unmanaged<CFTypeRef>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as? T
    }
}
