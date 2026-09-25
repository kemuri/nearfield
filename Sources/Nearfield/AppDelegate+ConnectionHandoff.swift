import Foundation
import os

extension AppDelegate {
    func observeConnectionDefaultOutput() {
        let uid = routerDriverManager.currentDefaultOutputUID()
        connectionHandoff?.observeDefaultOutput(uid)
        handoffChangeSignal?.fire()
        if let uid, !NearfieldAudioIdentifiers.virtualOutputUIDs.contains(uid) {
            lastNonNearfieldOutputUID = uid
        }
    }

    func cancelConnectionHandoff() {
        connectionHandoff?.cancel()
        connectionHandoffTask?.cancel()
        connectionHandoffTask = nil
        connectionHandoff = nil
        connectionHandoffFailure = nil
        connectionActivationPending = false
        stopHandoffMonitoring()
    }

    /// Wakes the handoff on Core Audio notifications (playback, default
    /// output, driver status) instead of scanning on a timer.
    func startHandoffMonitoring() -> ChangeSignal {
        stopHandoffMonitoring()
        let signal = ChangeSignal()
        handoffChangeSignal = signal
        if ProcessAudioPlayback.isSupported {
            let monitor = ProcessPlaybackMonitor { [weak signal] in signal?.fire() }
            monitor.start()
            handoffPlaybackMonitor = monitor
        }
        return signal
    }

    func stopHandoffMonitoring() {
        handoffPlaybackMonitor?.stop()
        handoffPlaybackMonitor = nil
        handoffChangeSignal = nil
    }

    func handoffWait(_ reason: RouterConnectionHandoff.Wait, signal: ChangeSignal) async throws {
        switch reason {
        case .readiness:
            if routerStatusNotificationsAvailable {
                // The driver notifies when the route becomes ready.
                try await signal.wait(timeout: 1_000_000_000)
            } else {
                // Older drivers are polled, as before.
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        case .playbackConfirmation:
            try await Task.sleep(nanoseconds: 1_000_000_000)
        case .playbackIdle:
            // Notifications cover apps starting, moving between outputs and
            // output changes; the long timeout is only a safety net.
            try await signal.wait(timeout: 60_000_000_000)
        }
    }

    func startConnectionHandoff() throws {
        cancelConnectionHandoff()
        let configuration = currentConfiguration()
        let targets = try audioManager.orderedStudioDisplayUIDs(configuration: configuration)
        let initialOutput = routerDriverManager.currentDefaultOutputUID()
        let previousOutput = initialOutput == RouterAudioDriverManager.routerDeviceUID
            ? lastNonNearfieldOutputUID : initialOutput
        let handoff = RouterConnectionHandoff(
            previousOutputUID: previousOutput,
            initialDefaultUID: initialOutput,
            routerUID: RouterAudioDriverManager.routerDeviceUID
        )
        connectionHandoff = handoff
        connectionActivationPending = true
        let changeSignal = startHandoffMonitoring()
        connectionHandoffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.connectionHandoff === handoff {
                    self.connectionHandoff = nil
                    self.connectionHandoffTask = nil
                    self.connectionActivationPending = false
                    self.stopHandoffMonitoring()
                }
                self.scheduleAudioStateChange()
            }
            do {
                try await handoff.run(.init(
                    snapshot: {
                        let currentTargets = try? self.audioManager.orderedStudioDisplayUIDs(configuration: self.currentConfiguration())
                        return .init(
                            displaysConnected: currentTargets == targets && self.currentMode() == configuration.mode,
                            targetReady: try self.routerDriverManager.targetOutputIsReady(deviceUIDs: targets, mode: configuration.mode),
                            defaultOutputUID: self.routerDriverManager.currentDefaultOutputUID(),
                            playback: ProcessAudioPlayback.activeOutputs()
                        )
                    },
                    prepare: {
                        try self.performSynchronizedAudioUpdate {
                            try self.configureRouterDriver(activate: false)
                        }
                    },
                    activate: {
                        try self.performSynchronizedAudioUpdate {
                            try self.activateConfiguredRouterOutput()
                        }
                        self.cachedRouterDefaultOutput = true
                        self.connectionActivationPending = false
                        self.logger.info("Connection handoff selected Nearfield after display route became ready")
                    },
                    selectPreviousOutput: {
                        self.logger.info("Connection handoff retrying output selection once for playback on the previous device")
                        try self.routerDriverManager.selectPreviousOutputForRecovery(uid: previousOutput ?? "", displayUIDs: targets)
                    },
                    supportsPlaybackVerification: ProcessAudioPlayback.isSupported,
                    waitForChange: { [weak self] reason in
                        guard let self else { throw CancellationError() }
                        try await self.handoffWait(reason, signal: changeSignal)
                    }
                ))
                self.logger.info("Connection handoff completed")
            } catch is CancellationError {
                // A disconnect, a user selection, or driver maintenance superseded this attempt.
            } catch {
                self.connectionHandoffFailure = error
                self.recordRecoverableError(error, context: "Automatic output switching failed")
                self.refreshStatus()
            }
        }
    }
}
