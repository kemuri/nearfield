import AppKit
import ServiceManagement

@MainActor
enum DriverRemovalWorkflow {
    static func run(
        prepare: () async -> Void,
        removeDriver: () async throws -> Void,
        finish: () async -> Void
    ) async throws {
        await prepare()
        try await removeDriver()
        await finish()
    }
}

extension AppDelegate: SettingsDelegate {
    func settingsDevices() -> [AudioDevice] {
        cachedAudioState.detectedDisplays
    }

    func settingsCoreAudioAvailability() -> CoreAudioAvailability {
        coreAudioAvailability
    }

    func settingsRefreshAudioState() async -> Bool {
        let isReady = await refreshCachedAudioState()
        refreshStatus()
        return isReady
    }

    func settingsMode() -> NearfieldOutputMode {
        currentMode()
    }

    func settingsLeftDeviceUID() -> String? {
        NearfieldPreferences.leftDeviceUID()
    }

    func settingsDisplayOrderUIDs() -> [String] {
        NearfieldPreferences.displayOrderUIDs()
    }

    func settingsOpenAtLogin() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func settingsSetOpenAtLogin(_ enabled: Bool) {
        setOpenAtLogin(enabled)
    }

    func settingsShowMenuBarApp() -> Bool {
        showMenuBarApp()
    }

    func settingsSetShowMenuBarApp(_ enabled: Bool) {
        NearfieldPreferences.setShowMenuBarApp(enabled)
        applyMenuBarState()
        refreshStatus()
    }

    func settingsDidReachSettingsScreen() {
        guard isInitialOnboardingInProgress else { return }
        NearfieldPreferences.markOnboardingCompleted()
        isInitialOnboardingInProgress = false
        #if NEARFIELD_DISTRIBUTION
        startUpdaterIfEligible(checkImmediately: true)
        #endif
        applyMenuBarState()
        // Launch skipped Core Audio startup to show onboarding, so start it
        // here instead of leaving media keys and routing dead until relaunch.
        startCoreAudioServices()
    }

    func settingsDriverInstalled() -> Bool {
        cachedRouterDriverAvailability.isInstalled
    }

    func settingsIsInstallingDriver() -> Bool {
        isInstallingDriver
    }

    func settingsDriverInstallState() -> DriverInstallState {
        driverInstallState
    }

    func settingsResetDriverInstallState() {
        guard !isInstallingDriver else { return }
        driverInstallState = .idle
        clearRecoverableError()
        refreshStatus()
    }

    func settingsNearfieldDriverSelected() -> Bool {
        cachedRouterDefaultOutput
    }

    func settingsAppRoutingEnabled() -> Bool {
        appRoutingEnabled()
    }

    func settingsSetAppRoutingEnabled(_ enabled: Bool) {
        if enabled {
            NearfieldPreferences.setAppRoutingEnabled(true)
            if routerDriverManager.isInstalled {
                do {
                    try performSynchronizedAudioUpdate {
                        try restoreDisplaysAfterProxyDeactivation()
                        try configureRouterDriver()
                    }
                } catch {
                    NearfieldPreferences.setAppRoutingEnabled(false)
                    showError(error)
                }
            } else {
                installAndActivateRouterDriver(.enablingAppRouting)
            }
        } else {
            NearfieldPreferences.setAppRoutingEnabled(false)
            deactivateRouterDriver()
        }
        updateDynamicRoutingRulesLifecycle()
        refreshStatus()
    }

    func settingsAppRoutingAppBundleIDs() -> [String]? {
        NearfieldPreferences.appRoutingAppBundleIDs()
    }

    func settingsSetAppRoutingAppBundleIDs(_ bundleIDs: [String]) {
        NearfieldPreferences.setAppRoutingAppBundleIDs(bundleIDs)
        refreshStatus()
    }

    func settingsSpatialRoutingChannels(for requests: [AppAudioRouteRequest]) -> [String: SpatialRoutingChannel] {
        guard appRoutingEnabled(), cachedRouterDriverAvailability.isLoaded else { return [:] }
        return windowRouteResolver.currentRoutes(for: requests, rawRules: currentRoutingRules())
            .compactMapValues { SpatialRoutingChannel(route: $0) }
    }

    func settingsRoutingRules() -> String {
        currentRoutingRules()
    }

    func settingsSetRoutingRules(_ rules: String) {
        NearfieldPreferences.setAppRoutingRules(rules)
        do {
            if routerDriverManager.isInstalled {
                try applyCurrentRouterRouteRulesIfNeeded(force: true)
            }
        } catch {
            showError(error)
        }
        updateDynamicRoutingRulesLifecycle()
        refreshStatus()
    }

    func settingsFooterStatus() -> String {
        if isInstallingDriver {
            return "Installing router driver..."
        }
        if coreAudioAvailability == .unavailable {
            return "Core Audio is unavailable. Quit and reopen Nearfield after it restarts."
        }
        if let lastRuntimeError {
            return lastRuntimeError
        }
        if cachedRouterDefaultOutput {
            return appRoutingEnabled()
                ? "Current output: Nearfield - App Audio Routing enabled"
                : "Current output: Nearfield"
        }
        if cachedRouterDriverAvailability.isLoaded {
            return "Current output: router driver loaded but not selected"
        }
        if cachedRouterDriverAvailability.isInstalled {
            return "Router driver is installed but Core Audio has not loaded it"
        }
        if cachedAudioState.isAggregateDefaultOutput {
            return "Current output: target selected - select Nearfield"
        }
        return "Current output: router driver not installed"
    }

    func settingsAppVersionText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        let resolvedVersion = version?.nilIfBlank ?? "0.1.0"

        if let build = build?.nilIfBlank, build != resolvedVersion {
            return "Version \(resolvedVersion) (\(build))"
        }
        return "Version \(resolvedVersion)"
    }

    func settingsBalance() -> Float {
        NearfieldPreferences.balance()
    }

    func settingsSetBalance(_ balance: Float) {
        let clamped = min(max(balance, -1), 1)
        NearfieldPreferences.setBalance(clamped)
        do {
            if routerDriverManager.isInstalled {
                try routerDriverManager.setBalance(Float32(clamped))
                if routerDriverManager.isRouterDefaultOutput() {
                    _ = try prepareDisplaysForVirtualOutputActivation()
                }
            } else {
                let configuration = currentConfiguration()
                try audioManager.setDisplayBalance(
                    Float32(clamped),
                    leftDeviceUID: configuration.leftDeviceUID,
                    displayOrderUIDs: configuration.displayOrderUIDs
                )
            }
        } catch {
            showError(error)
        }
        refreshStatus()
    }

    func settingsSetMode(_ mode: NearfieldOutputMode) {
        setMode(mode)
        refreshStatus()
    }

    func settingsSetLeftDeviceUID(_ uid: String) {
        let currentOrder = try? audioManager.orderedStudioDisplayUIDs(configuration: currentConfiguration())
        let reordered = currentOrder.map { order in
            [uid] + order.filter { $0 != uid }
        } ?? [uid]
        settingsSetDisplayOrderUIDs(reordered)
    }

    func settingsSetDisplayOrderUIDs(_ uids: [String]) {
        let normalizedUIDs = DisplayOrder.normalizedUIDs(uids)
        guard !normalizedUIDs.isEmpty,
              NearfieldPreferences.displayOrderUIDs() != normalizedUIDs else {
            return
        }
        pendingDisplayAssignmentTask?.cancel()
        NearfieldPreferences.setDisplayOrderUIDs(normalizedUIDs)
        // Persisting the visual order and applying the driver configuration are
        // one operation: a successful drop must change the real channel map.
        rebuildForConfigurationChange()

        guard routerDriverManager.isInstalled else { return }
        pendingDisplayAssignmentTask = Task { @MainActor [weak self] in
            // The driver rebuilds its private aggregate asynchronously. Its
            // private device is intentionally hidden from app-side device
            // enumeration, so reapply balance after the observed rebuild gap.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled,
                  let self,
                  NearfieldPreferences.displayOrderUIDs() == normalizedUIDs else {
                return
            }
            do {
                // Read the live master volume when applying balance. A user may
                // have changed it through macOS or media keys during the rebuild.
                try self.routerDriverManager.setBalance(self.currentBalance())
            } catch {
                self.showError(error)
            }
            self.pendingDisplayAssignmentTask = nil
            self.refreshStatus()
        }
    }

    func settingsApplyConfiguration() {
        rebuildForConfigurationChange()
    }

    func settingsInstallDriver(_ request: DriverInstallRequest) {
        guard !isInstallingDriver else { return }
        installAndActivateRouterDriver(request)
        refreshStatus()
    }

    func settingsRemoveEverything() {
        guard let scope = promptForUninstallScope() else { return }
        Task { @MainActor [weak self] in
            guard let self, await self.removeDriversAndTargets() else { return }
            if scope == .driversAndApp {
                self.removeApplicationBundleFromApplications()
            }
            self.refreshStatus()
        }
    }

    @discardableResult
    func removeDriversAndTargets() async -> Bool {
        dynamicRoutingRulesTask?.cancel()
        dynamicRoutingRulesTask = nil
        lastAppliedRouterRouteRules = nil
        NearfieldPreferences.clearAppRoutingEnabled()
        isRemovingDriver = true
        coreAudioStartupTask?.cancel()
        pendingAudioStateChangeTask?.cancel()
        pendingAudioStateChangeTask = nil
        mediaKeyVolumeController.stop()
        audioManager.stopObserving()
        didStartAudioServices = false

        var shouldRestorePhysicalDefault = proxyPreparedDisplayState != nil || cachedRouterDefaultOutput
        do {
            try await DriverRemovalWorkflow.run(
                prepare: { [self] in
                    shouldRestorePhysicalDefault = prepareAudioForDriverRemoval(
                        shouldRestorePhysicalDefault: shouldRestorePhysicalDefault
                    )
                },
                removeDriver: {
                    try await Task.detached(priority: .userInitiated) {
                        try DriverInstaller().removeAllInstalledDriversAndRestartCoreAudio()
                    }.value
                },
                finish: { [self] in
                    await finishAudioCleanupAfterDriverRemoval(
                        shouldRestorePhysicalDefault: shouldRestorePhysicalDefault
                    )
                }
            )
        } catch {
            isRemovingDriver = false
            showError(error)
            refreshStatus()
            resumeCoreAudioServicesAfterDriverRemoval()
            return false
        }

        isRemovingDriver = false
        refreshStatus()
        resumeCoreAudioServicesAfterDriverRemoval()
        return true
    }

    private func prepareAudioForDriverRemoval(
        shouldRestorePhysicalDefault: Bool
    ) -> Bool {
        guard coreAudioAvailability == .available else {
            recordRecoverableError(
                CoreAudioStartupError.unavailable,
                context: "Skipping pre-uninstall audio restoration"
            )
            return shouldRestorePhysicalDefault
        }

        var shouldRestorePhysicalDefault = shouldRestorePhysicalDefault
        do {
            shouldRestorePhysicalDefault = nearfieldVirtualOutputIsAnyDefault() || shouldRestorePhysicalDefault
            try performSynchronizedAudioUpdate {
                try restoreDisplaysAfterProxyDeactivation()
                if shouldRestorePhysicalDefault {
                    _ = try audioManager.selectFallbackOutputAsDefault()
                }
            }
        } catch {
            recordRecoverableError(error, context: "Pre-uninstall audio restoration failed")
        }
        return shouldRestorePhysicalDefault
    }

    private func finishAudioCleanupAfterDriverRemoval(
        shouldRestorePhysicalDefault: Bool
    ) async {
        invalidateCoreAudioReadiness()
        guard await waitForCoreAudioAfterDriverRemoval() else {
            recordRecoverableError(
                CoreAudioStartupError.unavailable,
                context: "Driver removed; post-uninstall audio cleanup deferred"
            )
            return
        }

        var cleanupFailed = false
        do {
            try performSynchronizedAudioUpdate {
                try restoreDisplaysAfterProxyDeactivation()
            }
        } catch {
            cleanupFailed = true
            recordRecoverableError(error, context: "Post-uninstall display restoration failed")
        }

        do {
            try performSynchronizedAudioUpdate {
                try audioManager.cleanupAllNearfieldAggregates()
                markAggregateSchemaCurrent()
            }
        } catch {
            cleanupFailed = true
            recordRecoverableError(error, context: "Post-uninstall target cleanup failed")
        }

        if shouldRestorePhysicalDefault {
            do {
                try await restorePhysicalDefaultOutputAfterCoreAudioRestart()
            } catch {
                cleanupFailed = true
                recordRecoverableError(error, context: "Post-uninstall default output restoration failed")
            }
        }

        if !cleanupFailed {
            proxyPreparedDisplayState = nil
            saveProxyPreparedDisplayState(nil)
            clearRecoverableError()
        }
        _ = await refreshCachedAudioState()
    }

    private func waitForCoreAudioAfterDriverRemoval(
        timeout: TimeInterval = 30,
        interval: TimeInterval = 0.5
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            if await refreshCachedAudioState(timeout: min(5, max(0.25, remaining))) {
                return true
            }
            guard Date() < deadline else { break }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } while !Task.isCancelled
        return false
    }

    private func resumeCoreAudioServicesAfterDriverRemoval() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            while self.coreAudioStartupTask != nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
            }
            self.startCoreAudioServices()
        }
    }

    private func restorePhysicalDefaultOutputAfterCoreAudioRestart(
        timeout: TimeInterval = 5,
        interval: TimeInterval = 0.2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSelectionError: Error?

        repeat {
            audioManager.invalidateCachedDevices()
            do {
                if try audioManager.selectFallbackOutputAsDefault() {
                    return
                }
            } catch {
                lastSelectionError = error
            }

            guard Date() < deadline else { break }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } while !Task.isCancelled

        if let lastSelectionError {
            throw lastSelectionError
        }
        throw NearfieldError.noPhysicalOutputAvailable
    }

    private func removeApplicationBundleFromApplications() {
        let bundleURL = applicationBundleURLForRemoval()
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            showError(applicationRemovalError("Nearfield.app was not found in Applications."))
            return
        }

        do {
            didPromptForDriverUninstallAfterApplicationRemoval = true
            stopApplicationRemovalMonitor()
            if SMAppService.mainApp.status == .enabled {
                do {
                    try SMAppService.mainApp.unregister()
                } catch {
                    recordRecoverableError(error, context: "Open-at-login cleanup failed")
                }
            }
            try FileManager.default.removeItem(at: bundleURL)
            NearfieldPreferences.resetAll()
            NSApp.terminate(nil)
        } catch {
            startApplicationRemovalMonitorIfNeeded()
            showError(error)
        }
    }

    private func applicationBundleURLForRemoval() -> URL {
        let currentBundleURL = currentApplicationBundleURL()
        if currentBundleURL.pathExtension == "app", isInApplicationsDirectory(currentBundleURL) {
            return currentBundleURL
        }
        return URL(fileURLWithPath: "/Applications/Nearfield.app", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    func applicationRemovalError(_ message: String) -> NSError {
        NSError(
            domain: "com.kemuri.Nearfield",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    func settingsPlayIdentificationChime(on display: AudioDevice) {
        do {
            let physicalOutputsArePrepared = proxyPreparedDisplayState != nil ||
                routerDriverManager.isRouterDefaultOutput()
            try testTonePlayer.playIdentificationChime(
                on: display,
                volume: IdentificationChimeGain.playerVolume(
                    physicalOutputsArePrepared: physicalOutputsArePrepared,
                    routerAudibleGain: routerDriverManager.currentAudibleGain()
                )
            )
        } catch {
            showError(error)
        }
    }

    func settingsShowDisplayIdentification(
        for displayUID: String,
        fallbackSide: DisplayIdentificationSide
    ) {
        displayIdentificationController.show(
            displayUID: displayUID,
            fallbackSide: fallbackSide
        )
    }
}
