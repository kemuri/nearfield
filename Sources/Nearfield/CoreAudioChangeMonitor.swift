import CoreAudio
import Foundation

/// Wakes an async waiter when something it watches changes.
@MainActor
final class ChangeSignal {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var pendingChange = false

    func fire() {
        guard !waiters.isEmpty else {
            pendingChange = true
            return
        }
        let current = waiters
        waiters.removeAll()
        current.values.forEach { $0.resume() }
    }

    /// Returns after the next change, or after |timeout| nanoseconds when
    /// given. A change since the previous wait returns immediately.
    func wait(timeout: UInt64?) async throws {
        if pendingChange {
            pendingChange = false
            return
        }
        let id = UUID()
        var timeoutTask: Task<Void, Never>?
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters[id] = continuation
                if let timeout {
                    timeoutTask = Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: timeout)
                        self?.resume(id)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(id) }
        }
        timeoutTask?.cancel()
        try Task.checkCancellation()
    }

    private func resume(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }
}

/// Watches which processes are playing and where, through Core Audio
/// notifications rather than periodic scans: the process list, and each
/// process's "running output" and output devices.
@MainActor
final class ProcessPlaybackMonitor {
    private let onChange: @MainActor () -> Void
    private var listListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    private static let processSelectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = {
        guard #available(macOS 14.2, *) else { return [] }
        return [
            (kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal),
            (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput),
        ]
    }()

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard #available(macOS 14.2, *), listListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refreshProcessListeners()
                self?.onChange()
            }
        }
        guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr else {
            return
        }
        listListener = block
        refreshProcessListeners()
    }

    func stop() {
        guard #available(macOS 14.2, *) else { return }
        if let listListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listListener)
        }
        listListener = nil
        for process in Array(processListeners.keys) {
            removeListeners(from: process)
        }
    }

    private func refreshProcessListeners() {
        guard #available(macOS 14.2, *) else { return }
        let current = Set(ProcessAudioPlayback.processObjects())
        for process in processListeners.keys where !current.contains(process) {
            removeListeners(from: process)
        }
        for process in current where processListeners[process] == nil {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onChange() }
            }
            for (selector, scope) in Self.processSelectors {
                var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
                AudioObjectAddPropertyListenerBlock(process, &address, .main, block)
            }
            processListeners[process] = block
        }
    }

    private func removeListeners(from process: AudioObjectID) {
        guard let block = processListeners.removeValue(forKey: process) else { return }
        for (selector, scope) in Self.processSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(process, &address, .main, block)
        }
    }
}

/// Observes one property of one Core Audio object on the main queue.
@MainActor
final class CoreAudioPropertyObserver {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private var block: AudioObjectPropertyListenerBlock?

    init?(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.objectID = objectID
        address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onChange() }
        }
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, .main, block) == noErr else {
            return nil
        }
        self.block = block
    }

    func invalidate() {
        guard let block else { return }
        AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, block)
        self.block = nil
    }

    var observedObjectID: AudioObjectID { objectID }
}
