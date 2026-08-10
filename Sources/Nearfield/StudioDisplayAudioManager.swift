import CoreAudio
import CoreGraphics
import Foundation

struct NearfieldState {
    let detectedDisplays: [AudioDevice]
    let aggregateDeviceID: AudioObjectID?
    let isAggregateDefaultOutput: Bool
}

struct StudioDisplayConnectionStatus: Equatable {
    let connectedCount: Int
    let coreAudioAvailability: CoreAudioAvailability

    init(
        connectedCount: Int,
        coreAudioAvailability: CoreAudioAvailability = .available
    ) {
        self.connectedCount = connectedCount
        self.coreAudioAvailability = coreAudioAvailability
    }

    enum State: Equatable {
        case checking
        case coreAudioUnavailable
        case connected
        case notConnected
    }

    var state: State {
        switch coreAudioAvailability {
        case .checking:
            return .checking
        case .unavailable:
            return .coreAudioUnavailable
        case .available:
            return isConnected ? .connected : .notConnected
        }
    }

    var isConnected: Bool {
        coreAudioAvailability == .available &&
            NearfieldRouterPolicy.shouldPublishRouter(studioDisplayCount: connectedCount)
    }

    var title: String {
        switch state {
        case .checking:
            return "Checking Core Audio"
        case .coreAudioUnavailable:
            return "Core Audio Unavailable"
        case .connected:
            return "Connected"
        case .notConnected:
            return "Not Connected"
        }
    }

    var detail: String {
        switch state {
        case .checking:
            return "Checking Studio Display audio devices…"
        case .coreAudioUnavailable:
            return "Unable to check Studio Displays until Core Audio recovers"
        case .connected, .notConnected:
            break
        }

        switch connectedCount {
        case 0:
            return "No Studio Displays connected"
        case 1:
            return "1 of 2 Studio Displays connected"
        default:
            return "\(connectedCount) Studio Displays connected"
        }
    }
}

struct AudioDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let outputChannelCount: UInt32

    var visualKind: DisplayEndpointVisualKind {
        DisplayEndpointVisualKind(deviceUID: uid, deviceName: name)
    }

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

enum DisplayOrder {
    static func normalizedUIDs(_ uids: [String], limit: Int = 3) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for uid in uids where !uid.isEmpty && seen.insert(uid).inserted {
            result.append(uid)
            if result.count == limit {
                break
            }
        }
        return result
    }
}

enum DisplayEndpointVisualKind: Equatable {
    case monitor
    case macBook

    init(deviceUID: String, deviceName: String) {
        let identity = "\(deviceUID) \(deviceName)"
        self = identity.localizedCaseInsensitiveContains("MacBook") ||
            identity.localizedCaseInsensitiveContains("BuiltInSpeaker") ||
            identity.localizedCaseInsensitiveContains("Built-in")
            ? .macBook
            : .monitor
    }

    var symbolName: String {
        switch self {
        case .monitor: "display"
        case .macBook: "laptopcomputer"
        }
    }
}

enum DisplayEndpointVisibility {
    static func builtInDisplayIsVisible() -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return false
        }
        var displayIDs = Array(repeating: CGDirectDisplayID(0), count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return false
        }
        return displayIDs.prefix(Int(displayCount)).contains { CGDisplayIsBuiltin($0) != 0 }
    }

    static func visibleDevices(
        from devices: [AudioDevice],
        builtInDisplayIsVisible: Bool
    ) -> [AudioDevice] {
        devices.filter { device in
            device.visualKind != .macBook || builtInDisplayIsVisible
        }
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
    var displayOrderUIDs: [String] = []
}

struct DisplayOutputState: Codable, Equatable {
    let deviceUID: String
    let volume: Float32?
    let isMuted: Bool?
}

enum DisplayOutputStateBaseline {
    static func merging(
        existing: [DisplayOutputState],
        current: [DisplayOutputState]
    ) -> [DisplayOutputState] {
        var capturedUIDs = Set(existing.map(\.deviceUID))
        return existing + current.filter { state in
            capturedUIDs.insert(state.deviceUID).inserted
        }
    }

    static func pendingStates(
        from states: [DisplayOutputState],
        afterRestoring restoredDeviceUIDs: Set<String>
    ) -> [DisplayOutputState] {
        states.filter { !restoredDeviceUIDs.contains($0.deviceUID) }
    }
}

enum NearfieldError: LocalizedError {
    case notEnoughStudioDisplays(Int)
    case coreAudio(operation: String, status: OSStatus)
    case aggregateMissing
    case studioPairNotActive
    case noPhysicalOutputAvailable

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
        case .noPhysicalOutputAvailable:
            return "macOS did not make a physical audio output available after restarting Core Audio."
        }
    }
}

final class StudioDisplayAudioManager {
    let aggregateUID = NearfieldAudioIdentifiers.appTargetAggregateUID
    let aggregateName = NearfieldAudioIdentifiers.appTargetAggregateName
    private var observerBlocks: [(address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var observerCallback: (() -> Void)?
    private var devicesCache: [AudioDevice]?

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

    func invalidateCachedDevices() {
        invalidateDeviceCache()
    }

    func orderedStudioDisplayUIDs(configuration: NearfieldConfiguration) throws -> [String] {
        let displays = studioDisplayOutputs()
        guard displays.count >= 2 else {
            throw NearfieldError.notEnoughStudioDisplays(displays.count)
        }
        return Self.orderedDisplays(
            from: displays,
            leftDeviceUID: configuration.leftDeviceUID,
            displayOrderUIDs: configuration.displayOrderUIDs
        )
            .prefix(3)
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

    func hasManagedNearfieldAggregates() -> Bool {
        !managedNearfieldAggregates().isEmpty
    }

    func isDefaultOutputDevice(uid: String) -> Bool {
        device(matchingUID: uid)?.id == defaultOutputDeviceID()
    }

    func isDefaultSystemOutputDevice(uid: String) -> Bool {
        device(matchingUID: uid)?.id == defaultSystemOutputDeviceID()
    }

    @discardableResult
    func selectFallbackOutputAsDefault() throws -> Bool {
        let devices = allDevices()
        guard let fallback = fallbackOutputDevice(from: devices) else {
            return false
        }
        try setDefaultOutputDevice(fallback.id)
        return defaultOutputDeviceID() == fallback.id &&
            defaultSystemOutputDeviceID() == fallback.id
    }

    func moveDefaultOutputAwayFromNearfield() throws {
        let devices = allDevices()
        let nearfieldAggregateIDs = Set(managedNearfieldAggregates().map(\.id))
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

        let displays = Array(studioDisplayOutputs().prefix(3))
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

        let displays = Array(studioDisplayOutputs().prefix(3))
        guard displays.count >= 2 else {
            throw NearfieldError.notEnoughStudioDisplays(displays.count)
        }

        let shouldMute = !(areAllMuted(displays) ?? false)
        try setMute(shouldMute, for: displays)
    }

    func setDisplayBalance(
        _ balance: Float32,
        leftDeviceUID: String?,
        displayOrderUIDs: [String] = []
    ) throws {
        let displays = studioDisplayOutputs()
        guard displays.count >= 2 else {
            throw NearfieldError.notEnoughStudioDisplays(displays.count)
        }
        let ordered = Self.orderedDisplays(
            from: displays,
            leftDeviceUID: leftDeviceUID,
            displayOrderUIDs: displayOrderUIDs
        )
        let rightDisplay = ordered.count >= 3 ? ordered[2] : ordered[1]
        let volumes = BalanceMath.channelVolumes(
            currentLeft: volume(for: ordered[0]),
            currentRight: volume(for: rightDisplay),
            balance: balance,
            minimumBaseVolume: 0.01
        )
        try setVolume(volumes.left, for: [ordered[0]])
        if ordered.count == 2 {
            try setVolume(volumes.right, for: [ordered[1]])
        } else {
            let centerVolume = max(volumes.left, volumes.right)
            try setVolume(centerVolume, for: [ordered[1]])
            try setVolume(volumes.right, for: [ordered[2]])
        }
    }

    func prepareDisplaysForProxyOutput() throws {
        let displays = Array(studioDisplayOutputs().prefix(3))
        guard displays.count >= 2 else {
            throw NearfieldError.notEnoughStudioDisplays(displays.count)
        }

        try setMute(false, for: displays)
        try setVolume(1, for: displays)
        if let aggregate = device(matchingUID: aggregateUID) {
            _ = try setDevicePropertyIfSupported(
                UInt32(0),
                selector: kAudioDevicePropertyMute,
                label: "mute",
                for: aggregate
            )
            _ = try setDevicePropertyIfSupported(
                Float32(1),
                selector: kAudioDevicePropertyVolumeScalar,
                label: "volume",
                for: aggregate
            )
        }
    }

    func captureDisplayOutputState() throws -> [DisplayOutputState] {
        let displays = Array(studioDisplayOutputs().prefix(3))
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

    func restoreDisplayOutputState(_ states: [DisplayOutputState]) throws -> [DisplayOutputState] {
        var restoredDeviceUIDs = Set<String>()
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
            restoredDeviceUIDs.insert(state.deviceUID)
        }
        return DisplayOutputStateBaseline.pendingStates(
            from: states,
            afterRestoring: restoredDeviceUIDs
        )
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
                self?.invalidateDeviceCache()
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
        Array(allDevices()
            .filter { $0.outputChannelCount > 0 && $0.name.localizedCaseInsensitiveContains("Studio Display") }
            .sorted { $0.uid < $1.uid }
            .prefix(3))
    }

    private func allDevices() -> [AudioDevice] {
        if let devicesCache {
            return devicesCache
        }

        let devices = fetchAllDevices()
        devicesCache = devices
        return devices
    }

    private func invalidateDeviceCache() {
        devicesCache = nil
    }

    private func fetchAllDevices() -> [AudioDevice] {
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
        for uid in NearfieldAudioIdentifiers.managedAggregateUIDs {
            if let hiddenAggregate = device(matchingUID: uid),
               isNearfieldAggregate(hiddenAggregate),
               !devices.contains(where: { $0.id == hiddenAggregate.id }) {
                devices.append(hiddenAggregate)
            }
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
        let eligibleDevices = devices.filter {
            $0.outputChannelCount > 0 &&
                !NearfieldAudioIdentifiers.virtualOutputUIDs.contains($0.uid) &&
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
        return NearfieldAudioIdentifiers.managedAggregateUIDs.contains(device.uid) ||
            NearfieldAudioIdentifiers.managedAggregateNames.contains(device.name)
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
        let id: AudioObjectID? = CoreAudioProperty.read(
            from: AudioObjectID(kAudioObjectSystemObject),
            selector: selector
        )
        return id.flatMap { $0 == 0 ? nil : $0 }
    }

    private func classID(for objectID: AudioObjectID) -> AudioClassID? {
        CoreAudioProperty.read(
            from: objectID,
            selector: kAudioObjectPropertyClass,
            as: AudioClassID.self
        )
    }

    static func orderedDisplays(
        from displays: [AudioDevice],
        leftDeviceUID: String?,
        displayOrderUIDs: [String] = []
    ) -> [AudioDevice] {
        let selectedDisplays = Array(displays.prefix(3))
        guard selectedDisplays.count >= 2 else { return selectedDisplays }

        let storedOrder = DisplayOrder.normalizedUIDs(displayOrderUIDs.isEmpty
            ? leftDeviceUID.map { [$0] } ?? []
            : displayOrderUIDs)
        let ordered = storedOrder.compactMap { uid in
            selectedDisplays.first(where: { $0.uid == uid })
        }
        let remaining = selectedDisplays.filter { display in
            !ordered.contains(where: { $0.uid == display.uid })
        }
        return ordered + remaining
    }

    private func destroyAggregate(_ deviceID: AudioObjectID) throws {
        invalidateDeviceCache()
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        guard status == noErr else {
            throw NearfieldError.coreAudio(operation: "Removing existing aggregate device", status: status)
        }
        invalidateDeviceCache()
    }

    private func setDefaultOutputDevice(_ deviceID: AudioObjectID) throws {
        try setDefaultDevice(deviceID, selector: kAudioHardwarePropertyDefaultOutputDevice)
        try setDefaultDevice(deviceID, selector: kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    private func setDefaultDevice(_ deviceID: AudioObjectID, selector: AudioObjectPropertySelector) throws {
        let status = CoreAudioProperty.write(
            deviceID,
            to: AudioObjectID(kAudioObjectSystemObject),
            selector: selector
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
        if let master: Float32 = CoreAudioProperty.read(
            from: device.id,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return master
        }

        let channelValues = (1...max(1, device.outputChannelCount)).compactMap { channel -> Float32? in
            CoreAudioProperty.read(
                from: device.id,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioDevicePropertyScopeOutput,
                element: channel,
                as: Float32.self
            )
        }
        guard !channelValues.isEmpty else { return nil }
        return channelValues.reduce(0, +) / Float32(channelValues.count)
    }

    private func setVolume(_ volume: Float32, for devices: [AudioDevice]) throws {
        for device in devices {
            let didSetVolume = try setDevicePropertyIfSupported(
                volume,
                selector: kAudioDevicePropertyVolumeScalar,
                label: "volume",
                for: device
            )
            if !didSetVolume {
                throw NearfieldError.coreAudio(
                    operation: "Setting \(device.name) volume",
                    status: kAudioHardwareUnknownPropertyError
                )
            }
        }
    }

    private func areAllMuted(_ devices: [AudioDevice]) -> Bool? {
        let values = devices.compactMap { isMuted($0) }
        guard !values.isEmpty else { return nil }
        return values.allSatisfy { $0 }
    }

    private func isMuted(_ device: AudioDevice) -> Bool? {
        if let master: UInt32 = CoreAudioProperty.read(
            from: device.id,
            selector: kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput,
            element: kAudioObjectPropertyElementMain
        ) {
            return master != 0
        }

        let channelValues = (1...max(1, device.outputChannelCount)).compactMap { channel -> UInt32? in
            CoreAudioProperty.read(
                from: device.id,
                selector: kAudioDevicePropertyMute,
                scope: kAudioDevicePropertyScopeOutput,
                element: channel,
                as: UInt32.self
            )
        }
        guard !channelValues.isEmpty else { return nil }
        return channelValues.allSatisfy { $0 != 0 }
    }

    private func setMute(_ muted: Bool, for devices: [AudioDevice]) throws {
        for device in devices {
            let didSetMute = try setDevicePropertyIfSupported(
                UInt32(muted ? 1 : 0),
                selector: kAudioDevicePropertyMute,
                label: "mute",
                for: device
            )
            if !didSetMute {
                throw NearfieldError.coreAudio(
                    operation: "Setting \(device.name) mute",
                    status: kAudioHardwareUnknownPropertyError
                )
            }
        }
    }

    @discardableResult
    private func setDevicePropertyIfSupported<Value: BitwiseCopyable>(
        _ value: Value,
        selector: AudioObjectPropertySelector,
        label: String,
        for device: AudioDevice
    ) throws -> Bool {
        let scope = kAudioDevicePropertyScopeOutput
        let mainElement = kAudioObjectPropertyElementMain
        if CoreAudioProperty.isSettable(
            on: device.id,
            selector: selector,
            scope: scope,
            element: mainElement
        ) {
            let status = CoreAudioProperty.write(
                value,
                to: device.id,
                selector: selector,
                scope: scope,
                element: mainElement
            )
            guard status == noErr else {
                throw NearfieldError.coreAudio(
                    operation: "Setting \(device.name) \(label)",
                    status: status
                )
            }
            return true
        }

        var didSetAnyChannel = false
        for channel in 1...max(1, device.outputChannelCount) {
            guard CoreAudioProperty.isSettable(
                on: device.id,
                selector: selector,
                scope: scope,
                element: channel
            ) else {
                continue
            }
            let status = CoreAudioProperty.write(
                value,
                to: device.id,
                selector: selector,
                scope: scope,
                element: channel
            )
            guard status == noErr else {
                throw NearfieldError.coreAudio(
                    operation: "Setting \(device.name) channel \(channel) \(label)",
                    status: status
                )
            }
            didSetAnyChannel = true
        }
        return didSetAnyChannel
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
