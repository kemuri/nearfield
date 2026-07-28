import AppKit
import ServiceManagement

extension AppDelegate: SettingsDelegate {
    func settingsDevices() -> [AudioDevice] {
        cachedAudioState.detectedDisplays
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

    func settingsSpatialRoutingChannel(
        for bundleIdentifier: String,
        routingBundleIdentifiers: [String]
    ) -> SpatialRoutingChannel? {
        guard appRoutingEnabled(), cachedRouterDriverAvailability.isLoaded else {
            return nil
        }
        guard let route = windowRouteResolver.currentRoute(
            for: bundleIdentifier,
            routingBundleIDs: routingBundleIdentifiers,
            rawRules: currentRoutingRules()
        ) else {
            return nil
        }
        return SpatialRoutingChannel(route: route)
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
                try audioManager.setDisplayBalance(Float32(clamped), leftDeviceUID: currentConfiguration().leftDeviceUID)
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
        NearfieldPreferences.setLeftDeviceUID(uid)
        refreshStatus()
    }

    func settingsSwapAssignment() {
        let devices = Array(audioManager.studioDisplayDevices().prefix(2))
        guard devices.count >= 2 else { return }
        let currentLeftUID = NearfieldPreferences.leftDeviceUID() ?? devices[0].uid
        let nextLeftUID = devices.first(where: { $0.uid != currentLeftUID })?.uid ?? devices[1].uid
        NearfieldPreferences.setLeftDeviceUID(nextLeftUID)
        rebuildForConfigurationChange()
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
        do {
            let isCoreAudioReady = coreAudioAvailability == .available
                ? true
                : await refreshCachedAudioState()
            guard isCoreAudioReady else {
                throw CoreAudioStartupError.unavailable
            }
            let shouldRestorePhysicalDefault = nearfieldVirtualOutputIsAnyDefault()
            try performSynchronizedAudioUpdate {
                try restoreDisplaysAfterProxyDeactivation()
                if shouldRestorePhysicalDefault {
                    _ = try audioManager.selectFallbackOutputAsDefault()
                }
            }
            try await Task.detached(priority: .userInitiated) {
                try DriverInstaller().removeAllInstalledDriversAndRestartCoreAudio()
            }.value
            invalidateCoreAudioReadiness()
            guard await refreshCachedAudioState(timeout: 10) else {
                throw CoreAudioStartupError.unavailable
            }
            if shouldRestorePhysicalDefault {
                try await restorePhysicalDefaultOutputAfterCoreAudioRestart()
            }
            try performSynchronizedAudioUpdate {
                try audioManager.cleanupAllNearfieldAggregates()
                markAggregateSchemaCurrent()
                proxyPreparedDisplayState = nil
                saveProxyPreparedDisplayState(nil)
            }
            if shouldRestorePhysicalDefault {
                try await restorePhysicalDefaultOutputAfterCoreAudioRestart()
            }
            _ = await refreshCachedAudioState()
            clearRecoverableError()
            refreshStatus()
            return true
        } catch {
            showError(error)
            refreshStatus()
            return false
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
            try FileManager.default.removeItem(at: bundleURL)
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

    private func applicationRemovalError(_ message: String) -> NSError {
        NSError(
            domain: "com.kemuri.Nearfield",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    func settingsPlayTestTone(_ channel: TestToneChannel) {
        do {
            try testTonePlayer.play(channel: channel)
        } catch {
            showError(error)
        }
    }
}
