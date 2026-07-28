import AppKit

extension AppDelegate {
    func refreshStatus() {
        onboardingWindowController?.reload()
    }

    func preparePairOnLaunch() {
        let state = cachedAudioState
        guard state.detectedDisplays.count >= 2 else {
            return
        }
        let shouldActivateVirtualOutput = nearfieldVirtualOutputIsDefaultOutput(state: state)

        do {
            try performSynchronizedAudioUpdate {
                if routerDriverManager.isInstalled {
                    try configureRouterDriver(activate: shouldActivateVirtualOutput)
                } else {
                    try cleanupNearfieldTargetsIfNeeded(state: state, scope: .allManaged)
                }
            }
        } catch {
            recordRecoverableError(error, context: "Launch audio setup failed")
        }
    }

    func configureRouterDriver(activate: Bool = true) throws {
        let currentRouterVolume = currentRouterVolumeForContinuity()
        try cleanupNearfieldTargetsIfNeeded(scope: .appOwned)

        let routingState = currentRouterRoutingState()
        let targetDeviceUIDs = try audioManager.orderedStudioDisplayUIDs(configuration: currentConfiguration())
        try routerDriverManager.configureRouterOutput(
            targetDeviceUIDs: targetDeviceUIDs,
            mode: currentMode(),
            displayName: "Nearfield",
            routingEnabled: routingState.enabled,
            routeRules: routingState.rules
        )
        try routerDriverManager.setPublished(true)
        lastAppliedRouterRouteRules = routingState.rules
        if activate {
            let capturedDisplayState = try prepareDisplaysForVirtualOutputActivation()
            let capturedDisplayVolume = averageCapturedDisplayVolume(capturedDisplayState)
            if let activationVolume = routerVolumeContinuity.activationVolume(
                currentRouterVolume: currentRouterVolume,
                capturedDisplayVolume: capturedDisplayVolume
            ) {
                try routerDriverManager.setBalancedVolume(activationVolume, balance: currentBalance())
                routerVolumeContinuity.observe(activationVolume)
            } else {
                try routerDriverManager.setBalance(currentBalance())
            }
            try routerDriverManager.selectRouterAsDefaultOutput()
        } else {
            try routerDriverManager.setBalance(currentBalance())
            try restoreDisplaysAfterProxyDeactivation()
        }
        updateDynamicRoutingRulesLifecycle()
    }

    func currentRouterVolumeForContinuity() -> Float32? {
        let isContinuingExistingSession =
            proxyPreparedDisplayState != nil ||
            routerDriverManager.isRouterDefaultOutput() ||
            routerVolumeContinuity.lastKnownVolume != nil
        guard isContinuingExistingSession else { return nil }

        let currentVolume = routerDriverManager.currentBaseVolume()
        routerVolumeContinuity.observe(currentVolume)
        return currentVolume
    }

    func performSynchronizedAudioUpdate(_ work: () throws -> Void) rethrows {
        audioStateSynchronizationDepth += 1
        defer { audioStateSynchronizationDepth -= 1 }
        try work()
    }

    func handleAudioStateChange() {
        guard !isSynchronizingAudioState, !isInstallingDriver else {
            refreshStatus()
            return
        }

        let state = audioManager.currentState()
        cachedAudioState = state
        cachedRouterDriverAvailability = currentRouterDriverAvailability(coreAudioIsReady: true)
        cachedRouterDefaultOutput = cachedRouterDriverAvailability.isLoaded &&
            routerDriverManager.isRouterDefaultOutput()
        let hasSufficientDisplays = NearfieldRouterPolicy.shouldPublishRouter(
            studioDisplayCount: state.detectedDisplays.count
        )
        let justReconnectedDisplays = !hadSufficientStudioDisplays && hasSufficientDisplays
        defer {
            hadSufficientStudioDisplays = hasSufficientDisplays
        }

        do {
            if hasSufficientDisplays {
                try handleStudioDisplaysAvailable(state: state, activateVirtualOutput: justReconnectedDisplays)
            } else {
                try handleStudioDisplaysUnavailable(state: state)
            }
            clearRecoverableError()
        } catch {
            recordRecoverableError(error, context: "Audio device refresh failed")
        }
        refreshStatus()
    }

    func handleStudioDisplaysAvailable(state: NearfieldState, activateVirtualOutput: Bool) throws {
        let shouldActivateVirtualOutput = NearfieldRouterPolicy.shouldActivateRouter(
            defaultOutputIsNearfield: nearfieldVirtualOutputIsDefaultOutput(state: state),
            displaysJustReconnected: activateVirtualOutput,
            shouldReactivateAfterReconnect: shouldReactivateVirtualOutputAfterDisplayReconnect
        )
        shouldReactivateVirtualOutputAfterDisplayReconnect = false

        try performSynchronizedAudioUpdate {
            if routerDriverManager.isInstalled {
                try configureRouterDriver(activate: shouldActivateVirtualOutput)
            } else {
                try cleanupNearfieldTargetsIfNeeded(state: state, scope: .allManaged)
                try restoreDisplaysAfterProxyDeactivation()
            }
        }
    }

    func handleStudioDisplaysUnavailable(state: NearfieldState) throws {
        dynamicRoutingRulesTask?.cancel()
        dynamicRoutingRulesTask = nil
        lastAppliedRouterRouteRules = nil
        _ = currentRouterVolumeForContinuity()

        if nearfieldVirtualOutputIsDefaultOutput(state: state) {
            shouldReactivateVirtualOutputAfterDisplayReconnect = true
        }

        let shouldMoveToFallback = nearfieldVirtualOutputIsAnyDefault(state: state)
        if shouldMoveToFallback {
            try audioManager.selectFallbackOutputAsDefault()
        }
        if routerDriverManager.isInstalled {
            try routerDriverManager.setPublished(false)
        }
        try restoreDisplaysAfterProxyDeactivation()
    }

    func scheduleAudioStateChange() {
        pendingAudioStateChangeTask?.cancel()
        pendingAudioStateChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.pendingAudioStateChangeTask = nil
            self?.handleAudioStateChange()
        }
    }

    func prepareDisplaysForVirtualOutputActivation() throws -> [DisplayOutputState]? {
        var capturedDisplayState: [DisplayOutputState]?
        if proxyPreparedDisplayState == nil {
            let displayState = try audioManager.captureDisplayOutputState()
            proxyPreparedDisplayState = displayState
            saveProxyPreparedDisplayState(displayState)
            capturedDisplayState = displayState
        }
        try audioManager.prepareDisplaysForProxyOutput()
        return capturedDisplayState
    }

    func averageCapturedDisplayVolume(_ displayState: [DisplayOutputState]?) -> Float32? {
        guard let displayState else { return nil }
        let values = displayState.compactMap(\.volume)
        guard !values.isEmpty else { return nil }
        return min(max(values.reduce(0, +) / Float32(values.count), 0), 1)
    }

    func restoreDisplaysAfterProxyDeactivation() throws {
        guard let displayState = proxyPreparedDisplayState else { return }
        try audioManager.restoreDisplayOutputState(displayState)
        proxyPreparedDisplayState = nil
        saveProxyPreparedDisplayState(nil)
    }

    enum AggregateCleanupScope: Equatable {
        case appOwned
        case allManaged
    }

    func cleanupNearfieldTargetsIfNeeded(
        state: NearfieldState? = nil,
        scope: AggregateCleanupScope
    ) throws {
        let currentState = state ?? audioManager.currentState()
        let schemaNeedsCleanup = NearfieldPreferences.aggregateSchemaNeedsCleanup()
        guard currentState.aggregateDeviceID != nil ||
                schemaNeedsCleanup ||
                (scope == .allManaged && audioManager.hasManagedNearfieldAggregates()) else {
            return
        }
        try audioManager.cleanupAllNearfieldAggregates()
        markAggregateSchemaCurrent()
    }

    func nearfieldVirtualOutputIsDefaultOutput(state: NearfieldState? = nil) -> Bool {
        let currentState = state ?? audioManager.currentState()
        return currentState.isAggregateDefaultOutput ||
            NearfieldAudioIdentifiers.virtualOutputUIDs.contains { uid in
                audioManager.isDefaultOutputDevice(uid: uid)
            }
    }

    func nearfieldVirtualOutputIsAnyDefault(state: NearfieldState? = nil) -> Bool {
        let currentState = state ?? audioManager.currentState()
        return nearfieldVirtualOutputIsDefaultOutput(state: currentState) ||
            NearfieldAudioIdentifiers.virtualOutputUIDs.contains { uid in
                audioManager.isDefaultSystemOutputDevice(uid: uid)
            }
    }

    func loadProxyPreparedDisplayState() -> [DisplayOutputState]? {
        guard let data = NearfieldPreferences.proxyPreparedDisplayStateData() else {
            return nil
        }
        return try? JSONDecoder().decode([DisplayOutputState].self, from: data)
    }

    func saveProxyPreparedDisplayState(_ state: [DisplayOutputState]?) {
        guard let state else {
            NearfieldPreferences.setProxyPreparedDisplayStateData(nil)
            return
        }
        if let data = try? JSONEncoder().encode(state) {
            NearfieldPreferences.setProxyPreparedDisplayStateData(data)
        }
    }

    func setMode(_ mode: NearfieldOutputMode) {
        NearfieldPreferences.setOutputMode(mode)
    }

    func rebuildForConfigurationChange() {
        do {
            try performSynchronizedAudioUpdate {
                try restoreDisplaysAfterProxyDeactivation()
                if routerDriverManager.isInstalled {
                    try configureRouterDriver()
                } else {
                    try cleanupNearfieldTargetsIfNeeded(scope: .allManaged)
                    try audioManager.setDisplayBalance(currentBalance(), leftDeviceUID: currentConfiguration().leftDeviceUID)
                }
            }
        } catch {
            showError(error)
        }
        refreshStatus()
    }

    func markAggregateSchemaCurrent() {
        NearfieldPreferences.markAggregateSchemaCurrent()
    }

    func currentConfiguration() -> NearfieldConfiguration {
        NearfieldConfiguration(
            mode: currentMode(),
            leftDeviceUID: NearfieldPreferences.leftDeviceUID()
        )
    }

    func currentMode() -> NearfieldOutputMode {
        NearfieldPreferences.outputMode()
    }

    func currentBalance() -> Float32 {
        NearfieldPreferences.balance()
    }

    func appRoutingEnabled() -> Bool {
        NearfieldPreferences.appRoutingEnabled()
    }

    func currentRoutingRules() -> String {
        NearfieldPreferences.appRoutingRules()
    }

    func currentRouterRoutingState() -> (enabled: Bool, rules: String) {
        guard appRoutingEnabled() else {
            return (false, "")
        }
        let rawRules = currentRoutingRules()
        return (true, windowRouteResolver.resolvedRules(from: rawRules))
    }

    func applyCurrentRouterRouteRulesIfNeeded(force: Bool = false) throws {
        guard appRoutingEnabled(), routerDriverManager.isInstalled else { return }
        let rawRules = currentRoutingRules()
        let resolvedRules = windowRouteResolver.resolvedRules(from: rawRules)
        guard force || resolvedRules != lastAppliedRouterRouteRules else { return }
        if force {
            try routerDriverManager.setRoutingEnabled(true)
        }
        try routerDriverManager.setRouteRules(resolvedRules)
        lastAppliedRouterRouteRules = resolvedRules
    }

    func updateDynamicRoutingRulesLifecycle() {
        let rawRules = currentRoutingRules()
        let hasWindowScopedRoute = windowRouteResolver.hasWindowScopedRoute(in: rawRules)
        let hasRunningWindowScopedRoute = hasWindowScopedRoute &&
            windowRouteResolver.hasRunningWindowScopedRoute(in: rawRules)
        let shouldRun = isDynamicRoutingSystemActive &&
            appRoutingEnabled() &&
            routerDriverManager.isInstalled &&
            cachedAudioState.detectedDisplays.count >= 2 &&
            hasRunningWindowScopedRoute
        if shouldRun {
            startDynamicRoutingRulesTask()
        } else {
            stopDynamicRoutingRulesTask()
            if appRoutingEnabled(),
               routerDriverManager.isInstalled,
               hasWindowScopedRoute,
               !hasRunningWindowScopedRoute {
                applyWindowRoutingFallbackRulesIfNeeded(rawRules: rawRules)
            }
        }
    }

    func startDynamicRoutingRulesTask() {
        guard dynamicRoutingRulesTask == nil else { return }
        dynamicRoutingRulesTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let rawRules = self.currentRoutingRules()
                guard self.windowRouteResolver.hasRunningWindowScopedRoute(in: rawRules) else {
                    self.applyWindowRoutingFallbackRulesIfNeeded(rawRules: rawRules)
                    self.dynamicRoutingRulesTask = nil
                    return
                }
                do {
                    try self.applyCurrentRouterRouteRulesIfNeeded()
                } catch {
                    self.recordRecoverableError(error, context: "App Audio Routing refresh failed")
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func applyWindowRoutingFallbackRulesIfNeeded(rawRules: String) {
        let fallbackRules = windowRouteResolver.fallbackRulesWithoutProcessOverrides(from: rawRules)
        guard fallbackRules != lastAppliedRouterRouteRules else { return }
        do {
            try routerDriverManager.setRouteRules(fallbackRules)
            lastAppliedRouterRouteRules = fallbackRules
        } catch {
            recordRecoverableError(error, context: "App Audio Routing cleanup failed")
        }
    }

    func stopDynamicRoutingRulesTask() {
        dynamicRoutingRulesTask?.cancel()
        dynamicRoutingRulesTask = nil
    }

    func configureDynamicRoutingLifecycleNotifications() {
        guard dynamicRoutingNotificationObservers.isEmpty else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let refreshNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ]

        dynamicRoutingNotificationObservers = refreshNames.map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.updateDynamicRoutingRulesLifecycle()
                }
            }
        }

        dynamicRoutingNotificationObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isDynamicRoutingSystemActive = false
                    self?.stopDynamicRoutingRulesTask()
                }
            }
        )

        dynamicRoutingNotificationObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isDynamicRoutingSystemActive = true
                    self?.updateDynamicRoutingRulesLifecycle()
                }
            }
        )

        dynamicRoutingNotificationObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isDynamicRoutingSystemActive = false
                    self?.stopDynamicRoutingRulesTask()
                }
            }
        )

        dynamicRoutingNotificationObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.isDynamicRoutingSystemActive = true
                    self?.updateDynamicRoutingRulesLifecycle()
                }
            }
        )
    }

}
