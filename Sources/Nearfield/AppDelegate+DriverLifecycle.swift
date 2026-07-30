import AppKit
import os

extension AppDelegate {
    func installAndActivateRouterDriver(_ request: DriverInstallRequest) {
        guard !isInstallingDriver else { return }
        let studioDisplayCount = cachedAudioState.detectedDisplays.count
        guard NearfieldRouterPolicy.shouldAttemptDriverInstall(
            studioDisplayCount: studioDisplayCount,
            allowsMissingStudioDisplays: request.allowsMissingStudioDisplays
        ) else {
            let error = NearfieldError.notEnoughStudioDisplays(studioDisplayCount)
            failDriverInstallAttempt(
                error,
                stage: .preparation,
                request: request
            )
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let isReinstall = cachedRouterDriverAvailability.isInstalled
        if request.requiresConfirmation {
            guard confirmPrivilegedInstall(
                title: isReinstall ? "Reinstall Nearfield Driver?" : "Install Nearfield Driver?",
                message: "Nearfield will install NearfieldAudioDevice.driver into /Library/Audio/Plug-Ins/HAL. macOS should ask for an administrator password before installing it."
            ) else {
                finishDriverInstallAttempt(
                    disableAppRouting: request.disablesAppRoutingOnFailure,
                    state: .idle
                )
                return
            }
        }
        isInstallingDriver = true
        driverInstallState = .installing(.preparation)
        clearRecoverableError()
        refreshStatus()

        Task { [weak self] in
            guard let self else { return }

            let driverPath: String
            do {
                driverPath = try await Task.detached(priority: .userInitiated) {
                    try DriverInstaller().buildRouterDriver()
                }.value
            } catch {
                self.failDriverInstallAttempt(error, stage: .preparation, request: request)
                return
            }

            self.driverInstallState = .installing(.authorizationAndInstallation)
            self.refreshStatus()
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DriverInstaller().installBuiltRouterDriver(at: driverPath)
                }.value
            } catch {
                self.restorePrimaryWindowFocusAfterPrivilegedInstall()
                let stage: DriverInstallFailureStage
                if let installerError = error as? DriverInstallerError,
                   case .authorizationCancelled = installerError {
                    stage = .authorization
                } else {
                    stage = .installation
                }
                self.failDriverInstallAttempt(error, stage: stage, request: request)
                return
            }
            self.restorePrimaryWindowFocusAfterPrivilegedInstall()

            let currentDriverIsInstalledOnDisk =
                await DriverInstaller.waitForCurrentRouterDriverOnDisk()
            guard currentDriverIsInstalledOnDisk else {
                self.failDriverInstallAttempt(
                    RouterAudioDriverError.notInstalled,
                    stage: .installation,
                    request: request
                )
                return
            }

            self.driverInstallState = .installing(.activation)
            self.refreshStatus()
            self.invalidateCoreAudioReadiness()
            self.audioManager.invalidateCachedDevices()
            if NearfieldRouterPolicy.shouldCompleteDriverInstallWithoutActivation(
                currentDriverIsInstalledOnDisk: currentDriverIsInstalledOnDisk,
                allowsMissingStudioDisplays: request.allowsMissingStudioDisplays
            ) {
                self.clearRecoverableError()
                self.finishDriverInstallAttempt(
                    disableAppRouting: false,
                    state: .succeeded
                )
                return
            }

            guard await self.waitForRouterDriverAfterCoreAudioRestart() else {
                self.failDriverInstallAttempt(
                    RouterAudioDriverError.notInstalled,
                    stage: .activation,
                    request: request
                )
                return
            }

            self.driverInstallState = .installing(.configuration)
            self.refreshStatus()
            do {
                try await self.configureRouterDriverAfterInstall(
                    allowsMissingStudioDisplays: request.allowsMissingStudioDisplays
                )
                _ = await self.refreshCachedAudioState()
            } catch {
                self.failDriverInstallAttempt(error, stage: .configuration, request: request)
                return
            }
            self.clearRecoverableError()
            self.finishDriverInstallAttempt(
                disableAppRouting: false,
                state: .succeeded
            )
        }
    }

    func handleDriverInstallError(_ error: Error, presentsErrors: Bool) {
        if presentsErrors {
            showError(error)
        } else {
            recordRecoverableError(error, context: "Driver install failed")
        }
    }

    func failDriverInstallAttempt(
        _ error: Error,
        stage: DriverInstallFailureStage,
        request: DriverInstallRequest
    ) {
        finishDriverInstallAttempt(
            disableAppRouting: request.disablesAppRoutingOnFailure,
            state: .failed(
                DriverInstallFailure(
                    stage: stage,
                    message: error.localizedDescription
                )
            )
        )
        handleDriverInstallError(error, presentsErrors: request.presentsErrors)
    }

    func finishDriverInstallAttempt(
        disableAppRouting: Bool,
        state: DriverInstallState
    ) {
        if disableAppRouting {
            NearfieldPreferences.setAppRoutingEnabled(false)
        }
        driverInstallState = state
        isInstallingDriver = false
        updateDynamicRoutingRulesLifecycle()
        refreshStatus()
    }

    func restorePrimaryWindowFocusAfterPrivilegedInstall() {
        onboardingWindowController?.show()
    }

    func configureRouterDriverAfterInstall(
        allowsMissingStudioDisplays: Bool
    ) async throws {
        let studioDisplayCount: Int
        if allowsMissingStudioDisplays {
            audioManager.invalidateCachedDevices()
            studioDisplayCount = audioManager.currentState().detectedDisplays.count
        } else {
            studioDisplayCount = await waitForSufficientStudioDisplaysAfterCoreAudioRestart()
        }
        guard NearfieldRouterPolicy.shouldConfigureRouterAfterDriverInstall(studioDisplayCount: studioDisplayCount) else {
            if allowsMissingStudioDisplays {
                return
            }
            throw NearfieldError.notEnoughStudioDisplays(studioDisplayCount)
        }
        try performSynchronizedAudioUpdate {
            try restoreDisplaysAfterProxyDeactivation()
            try configureRouterDriver()
        }
    }

    func waitForRouterDriverAfterCoreAudioRestart(
        timeout: TimeInterval = 30,
        interval: TimeInterval = 0.25
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let probeTimeout = min(5, max(0.25, remaining))
            if await refreshCachedAudioState(timeout: probeTimeout),
               cachedRouterDriverAvailability.isLoaded {
                return true
            }
            guard Date() < deadline else { break }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } while !Task.isCancelled
        return false
    }

    func waitForSufficientStudioDisplaysAfterCoreAudioRestart(
        timeout: TimeInterval = 10,
        interval: TimeInterval = 0.25
    ) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        audioManager.invalidateCachedDevices()
        var latestCount = audioManager.currentState().detectedDisplays.count
        while latestCount < 2, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            audioManager.invalidateCachedDevices()
            latestCount = audioManager.currentState().detectedDisplays.count
        }
        return latestCount
    }

    func deactivateRouterDriver() {
        updateDynamicRoutingRulesLifecycle()
        do {
            if routerDriverManager.isInstalled {
                try routerDriverManager.setRoutingEnabled(false)
            }
        } catch {
            showError(error)
        }
    }

    func confirmPrivilegedInstall(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func showError(_ error: Error) {
        recordRecoverableError(error, context: "Audio update failed")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Nearfield could not update audio devices"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    func recordRecoverableError(_ error: Error, context: String) {
        let message = "\(context): \(error.localizedDescription)"
        lastRuntimeError = message
        logger.error("\(message, privacy: .public)")
    }

    func clearRecoverableError() {
        lastRuntimeError = nil
    }
}
