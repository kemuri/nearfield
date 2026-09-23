import Foundation
import os

extension AppDelegate {
    func observeConnectionDefaultOutput() {
        let uid = routerDriverManager.currentDefaultOutputUID()
        connectionHandoff?.observeDefaultOutput(uid)
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
        connectionHandoffTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.connectionHandoff === handoff {
                    self.connectionHandoff = nil
                    self.connectionHandoffTask = nil
                    self.connectionActivationPending = false
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
                            try self.activateConfiguredRouterOutput(currentRouterVolume: self.currentRouterVolumeForContinuity())
                        }
                        self.connectionActivationPending = false
                        self.logger.info("Connection handoff selected Nearfield after display route became ready")
                    },
                    selectPreviousOutput: {
                        self.logger.info("Connection handoff retrying output selection once for playback on the previous device")
                        try self.routerDriverManager.selectPreviousOutputForRecovery(uid: previousOutput ?? "", displayUIDs: targets)
                    },
                    supportsPlaybackVerification: ProcessAudioPlayback.isSupported
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
