import AppKit
import os

extension AppDelegate {
    func installAndActivateRouterDriver(_ request: DriverInstallRequest) {
        guard !isInstallingDriver, !isRemovingDriver else { return }
        let upgrade = request == .driverUpgrade ? DriverInstaller.availableDriverUpdate() : nil
        if request == .driverUpgrade {
            refreshDriverUpdateAvailability()
            guard upgrade != nil else { refreshStatus(); return }
            didPromptForDriverUpdate = true
        }
        let activateAfterInstall = request != .driverUpgrade || cachedRouterDefaultOutput
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
            let confirmed: Bool
            if let upgrade {
                confirmed = confirmDriverUpgrade(upgrade)
            } else {
                confirmed = confirmPrivilegedInstall(
                    title: isReinstall ? "Reinstall Nearfield Driver?" : "Install Nearfield Driver?",
                    message: "Nearfield will install NearfieldAudioDevice.driver into /Library/Audio/Plug-Ins/HAL. macOS should ask for an administrator password before installing it."
                )
            }
            guard confirmed else {
                finishDriverInstallAttempt(
                    disableAppRouting: request.disablesAppRoutingOnFailure,
                    state: .idle
                )
                return
            }
        }
        isInstallingDriver = true
        cancelConnectionHandoff()
        driverInstallState = .installing(.preparation)
        clearRecoverableError()
        refreshStatus()

        Task { [weak self] in
            guard let self else { return }

            let driverPath: String
            do {
                driverPath = try await Task.detached(priority: .userInitiated) {
                    // Install the exact bundled version offered by the upgrade
                    // prompt, including in development builds.
                    if let upgrade { return upgrade.bundledDriverURL.path }
                    return try DriverInstaller().buildRouterDriver()
                }.value
            } catch {
                self.failDriverInstallAttempt(error, stage: .preparation, request: request)
                return
            }

            self.driverInstallState = .installing(.authorizationAndInstallation)
            self.refreshStatus()
            do {
                try await DriverInstaller.runPrivilegedTask {
                    try DriverInstaller().installBuiltRouterDriver(at: driverPath)
                }
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
            self.refreshDriverInstallState()
            // Core Audio restarted with the new driver.
            self.routerDriverManager.resetAppliedSettings()
            self.routerOutputActivation.invalidate()
            self.lastAppliedRouterRouteRules = nil
            guard currentDriverIsInstalledOnDisk else {
                self.failDriverInstallAttempt(
                    RouterAudioDriverError.notInstalled,
                    stage: .installation,
                    request: request
                )
                return
            }
            if let upgrade {
                do {
                    try DriverInstaller.verifyInstalledDriverVersion(upgrade.availableVersion)
                } catch {
                    self.failDriverInstallAttempt(error, stage: .installation, request: request)
                    return
                }
            }

            self.driverInstallState = .installing(.activation)
            self.refreshStatus()
            self.invalidateCoreAudioReadiness()
            self.audioManager.invalidateCachedDevices()
            if request != .driverUpgrade, NearfieldRouterPolicy.shouldCompleteDriverInstallWithoutActivation(
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
                    allowsMissingStudioDisplays: request.allowsMissingStudioDisplays,
                    activate: activateAfterInstall
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
        refreshDriverInstallState()
        observeRouterStatus()
        updateDynamicRoutingRulesLifecycle()
        refreshStatus()
    }

    func restorePrimaryWindowFocusAfterPrivilegedInstall() {
        onboardingWindowController?.show()
    }

    func configureRouterDriverAfterInstall(
        allowsMissingStudioDisplays: Bool,
        activate: Bool = true
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
            try configureRouterDriver(activate: activate)
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
