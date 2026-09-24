import AppKit
import CoreAudio
import CoreGraphics

extension AppDelegate {
    /// Around sleep and wake the displays can disappear briefly; Nearfield
    /// waits this long after waking before treating them as gone.
    static let sleepWakeDisplayGraceSeconds: TimeInterval = 20

    func refreshStatus() {
        // Nothing to refresh while Settings is closed; the window controller
        // is released then.
        onboardingWindowController?.reload()
    }

    func preparePairOnLaunch() {
        let state = cachedAudioState
        guard isSessionActive, state.detectedDisplays.count >= 2 else {
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

    /// Sends the driver only what changed, and touches the displays' volume
    /// and mute only when Nearfield becomes the output.
    func configureRouterDriver(activate: Bool = true) throws {
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
            try routerOutputActivation.activateIfNeeded(displayUIDs: targetDeviceUIDs)
        } else {
            try routerDriverManager.setBalance(currentBalance())
            try restoreDisplaysAfterProxyDeactivation()
        }
        updateDynamicRoutingRulesLifecycle()
    }

    /// Selects Nearfield for the current displays; see RouterOutputActivation
    /// for the order that keeps the volume safe.
    func activateConfiguredRouterOutput() throws {
        let displayUIDs = try audioManager.orderedStudioDisplayUIDs(configuration: currentConfiguration())
        try routerOutputActivation.activate(displayUIDs: displayUIDs)
    }

    func makeRouterOutputActivation() -> RouterOutputActivation {
        let activation = RouterOutputActivation(operations: .init(
            currentRouterVolume: { [unowned self] in self.currentRouterVolumeForContinuity() },
            captureDisplays: { [unowned self] in
                self.averageCapturedDisplayVolume(try self.captureDisplaysForVirtualOutputActivation())
            },
            setRouterVolume: { [unowned self] currentRouterVolume, capturedDisplayVolume in
                if let volume = self.routerVolumeContinuity.activationVolume(
                    currentRouterVolume: currentRouterVolume,
                    capturedDisplayVolume: capturedDisplayVolume
                ) {
                    try self.routerDriverManager.setBalancedVolume(volume, balance: self.currentBalance())
                    self.routerVolumeContinuity.observe(volume)
                } else {
                    try self.routerDriverManager.setBalance(self.currentBalance())
                }
            },
            selectRouter: { [unowned self] in try self.routerDriverManager.selectRouterAsDefaultOutput() },
            displaysWithOtherPlayback: { [unowned self] uids in
                self.audioManager.displaysWithOtherPlayback(
                    uids,
                    driverProcessID: self.routerDriverManager.status()?.hostProcessID
                )
            },
            displayRaiseDecibels: { [unowned self] uids in self.audioManager.fullVolumeRaiseDecibels(forUIDs: uids) },
            shiftRouterVolume: { [unowned self] decibels in
                try self.routerDriverManager.shiftBaseVolume(byDecibels: decibels, balance: self.currentBalance())
            },
            raiseDisplays: { [unowned self] in try self.audioManager.prepareDisplaysForProxyOutput() },
            restoreDisplays: { [unowned self] in try self.restorePhysicalDisplayState() },
            routerIsDefault: { [unowned self] in self.routerDriverManager.isRouterDefaultOutput() },
            applyBalance: { [unowned self] in try self.routerDriverManager.setBalance(self.currentBalance()) },
            saveWaitingCompensation: { NearfieldPreferences.setWaitingDisplayCompensation($0) }
        ))
        activation.onWaitingChange = { [weak self] in
            // Not from inside a Core Audio listener that may be removed.
            Task { @MainActor in self?.updateWaitingDisplayMonitoring() }
        }
        return activation
    }

    /// While displays wait to be raised, watch for the other apps on them
    /// stopping or moving away.
    func updateWaitingDisplayMonitoring() {
        guard let displayUIDs = routerOutputActivation.waitingDisplayUIDs else {
            waitingDisplayPlaybackMonitor?.stop()
            waitingDisplayPlaybackMonitor = nil
            waitingDisplayObservers.forEach { $0.invalidate() }
            waitingDisplayObservers = []
            return
        }
        guard waitingDisplayObservers.isEmpty, waitingDisplayPlaybackMonitor == nil else { return }
        logger.info("Waiting to raise the displays' volume until no other app plays on them")
        let onChange: @MainActor () -> Void = { [weak self] in self?.raiseWaitingDisplaysIfFree() }
        if #available(macOS 14.2, *) {
            let monitor = ProcessPlaybackMonitor(onChange: onChange)
            monitor.start()
            waitingDisplayPlaybackMonitor = monitor
        }
        waitingDisplayObservers = displayUIDs.compactMap { uid in
            audioManager.deviceID(forUID: uid).flatMap {
                CoreAudioPropertyObserver(objectID: $0, selector: kAudioDevicePropertyDeviceIsRunningSomewhere, onChange: onChange)
            }
        }
        raiseWaitingDisplaysIfFree()
    }

    /// Takes back volume added while displays waited when Nearfield last quit
    /// or crashed, before anything else adjusts the volume.
    func undoInterruptedDisplayWait() {
        let compensation = NearfieldPreferences.waitingDisplayCompensation()
        guard compensation != 0, cachedRouterDriverAvailability.isLoaded else { return }
        do {
            _ = try routerDriverManager.shiftBaseVolume(byDecibels: -compensation, balance: currentBalance())
            NearfieldPreferences.setWaitingDisplayCompensation(0)
        } catch {
            recordRecoverableError(error, context: "Restoring Nearfield's volume failed")
        }
    }

    func raiseWaitingDisplaysIfFree() {
        guard routerOutputActivation.waitingDisplayUIDs != nil else { return }
        do {
            try performSynchronizedAudioUpdate {
                try routerOutputActivation.raiseWaitingDisplaysIfFree()
            }
        } catch {
            recordRecoverableError(error, context: "Preparing the Studio Displays failed")
        }
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

        let wasRouterDefaultOutput = cachedRouterDefaultOutput
        let state = audioManager.currentState()
        let displaysChanged = state.detectedDisplays.map(\.uid) != cachedAudioState.detectedDisplays.map(\.uid)
        cachedAudioState = state
        if displaysChanged {
            displayTargetsCache = nil
        }
        cachedRouterDriverAvailability = currentRouterDriverAvailability(coreAudioIsReady: true)
        cachedRouterDefaultOutput = cachedRouterDriverAvailability.isLoaded &&
            routerDriverManager.isRouterDefaultOutput()
        if !cachedRouterDefaultOutput {
            routerOutputActivation.invalidate()
        }
        observeRouterStatus()
        handoffChangeSignal?.fire()

        guard isSessionActive else {
            // Another user's session owns the driver and the displays.
            refreshStatus()
            return
        }

        let hasSufficientDisplays = NearfieldRouterPolicy.shouldPublishRouter(
            studioDisplayCount: state.detectedDisplays.count
        )
        if !hasSufficientDisplays, hadSufficientStudioDisplays, isWithinSleepWakeGrace() {
            // Displays often drop out briefly around sleep and wake. Keep
            // everything as it is and check again once the grace period ends.
            if !displaysLostDuringSleepWake {
                displaysLostDuringSleepWake = true
                nearfieldWasDefaultBeforeDisplayLoss = wasRouterDefaultOutput
            }
            scheduleDisplayLossGraceCheck()
            refreshStatus()
            return
        }
        let recoveredAfterSleepWake = displaysLostDuringSleepWake && hasSufficientDisplays
        let restoreNearfieldAfterSleepWake = recoveredAfterSleepWake &&
            nearfieldWasDefaultBeforeDisplayLoss && !cachedRouterDefaultOutput
        if displaysLostDuringSleepWake {
            displaysLostDuringSleepWake = false
            nearfieldWasDefaultBeforeDisplayLoss = false
            displayLossGraceTask?.cancel()
            displayLossGraceTask = nil
        }

        let displaysJustConnected = (!hadSufficientStudioDisplays && hasSufficientDisplays) ||
            restoreNearfieldAfterSleepWake
        defer {
            hadSufficientStudioDisplays = hasSufficientDisplays
        }

        do {
            if hasSufficientDisplays {
                try handleStudioDisplaysAvailable(state: state, displaysJustConnected: displaysJustConnected)
            } else {
                try handleStudioDisplaysUnavailable(state: state)
            }
            if let connectionHandoffFailure {
                recordRecoverableError(connectionHandoffFailure, context: "Automatic output switching failed")
            } else {
                clearRecoverableError()
            }
        } catch {
            recordRecoverableError(error, context: "Audio device refresh failed")
        }
        refreshStatus()
    }

    func isWithinSleepWakeGrace() -> Bool {
        if isSystemAsleep {
            return true
        }
        guard let lastWakeUptime else { return false }
        return ProcessInfo.processInfo.systemUptime - lastWakeUptime < Self.sleepWakeDisplayGraceSeconds
    }

    func scheduleDisplayLossGraceCheck() {
        guard displayLossGraceTask == nil else { return }
        displayLossGraceTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isWithinSleepWakeGrace() {
                let remaining = self.lastWakeUptime.map {
                    Self.sleepWakeDisplayGraceSeconds - (ProcessInfo.processInfo.systemUptime - $0)
                } ?? Self.sleepWakeDisplayGraceSeconds
                try? await Task.sleep(nanoseconds: UInt64(max(0.5, remaining) * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            self.displayLossGraceTask = nil
            self.audioManager.invalidateCachedDevices()
            self.handleAudioStateChange()
        }
    }

    func handleStudioDisplaysAvailable(state: NearfieldState, displaysJustConnected: Bool) throws {
        if displaysJustConnected {
            try startConnectionHandoff()
            return
        }
        if connectionHandoff?.isSwitchingOutput == true {
            // The asynchronous handoff owns activation and any recovery switch.
            return
        }
        let shouldActivateVirtualOutput = NearfieldRouterPolicy.shouldActivateRouter(
            defaultOutputIsNearfield: nearfieldVirtualOutputIsDefaultOutput(state: state),
            displaysJustConnected: displaysJustConnected,
            connectionActivationPending: connectionActivationPending
        )

        try performSynchronizedAudioUpdate {
            if cachedRouterDriverAvailability.isLoaded {
                try configureRouterDriver(activate: shouldActivateVirtualOutput)
                // Keep the connection request through temporary setup failures.
                // Once selected, later notifications respect manual output changes.
                connectionActivationPending = false
            } else {
                try cleanupNearfieldTargetsIfNeeded(state: state, scope: .allManaged)
                try restoreDisplaysAfterProxyDeactivation()
            }
        }
    }

    func handleStudioDisplaysUnavailable(state: NearfieldState) throws {
        cancelConnectionHandoff()
        windowRouteFollower.stop()
        followedRouteRules = nil
        lastAppliedRouterRouteRules = nil
        routerOutputActivation.invalidate()
        _ = currentRouterVolumeForContinuity()

        let shouldMoveToFallback = nearfieldVirtualOutputIsAnyDefault(state: state)
        if shouldMoveToFallback {
            try audioManager.selectFallbackOutputAsDefault(
                preferredUID: lastNonNearfieldOutputUID,
                excludingPreparedDisplayUIDs: Set(proxyPreparedDisplayState?.map(\.deviceUID) ?? [])
            )
        }
        observeConnectionDefaultOutput()
        if cachedRouterDriverAvailability.isLoaded {
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

    /// Records the displays' volume and mute before Nearfield takes them over.
    /// Returns them when this is the first capture.
    func captureDisplaysForVirtualOutputActivation() throws -> [DisplayOutputState]? {
        let currentDisplayState = try audioManager.captureDisplayOutputState()
        let existingDisplayState = proxyPreparedDisplayState ?? []
        let mergedDisplayState = DisplayOutputStateBaseline.merging(
            existing: existingDisplayState,
            current: currentDisplayState
        )
        let capturedDisplayState = proxyPreparedDisplayState == nil ? currentDisplayState : nil
        if proxyPreparedDisplayState == nil || mergedDisplayState.count != existingDisplayState.count {
            proxyPreparedDisplayState = mergedDisplayState
            saveProxyPreparedDisplayState(mergedDisplayState)
        }
        return capturedDisplayState
    }

    func averageCapturedDisplayVolume(_ displayState: [DisplayOutputState]?) -> Float32? {
        guard let displayState else { return nil }
        let values = displayState.compactMap(\.volume)
        guard !values.isEmpty else { return nil }
        return min(max(values.reduce(0, +) / Float32(values.count), 0), 1)
    }

    /// Puts the displays' volume and mute back; Nearfield no longer counts
    /// them as prepared.
    func restoreDisplaysAfterProxyDeactivation() throws {
        try routerOutputActivation.restoreDisplays()
    }

    func restorePhysicalDisplayState() throws {
        guard let displayState = proxyPreparedDisplayState else { return }
        let pendingDisplayState = try audioManager.restoreDisplayOutputState(displayState)
        proxyPreparedDisplayState = pendingDisplayState.isEmpty ? nil : pendingDisplayState
        saveProxyPreparedDisplayState(proxyPreparedDisplayState)
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
        cancelConnectionHandoff()
        displayTargetsCache = nil
        routerOutputActivation.invalidate()
        do {
            try performSynchronizedAudioUpdate {
                try restoreDisplaysAfterProxyDeactivation()
                if routerDriverManager.isInstalled {
                    try configureRouterDriver()
                } else {
                    try cleanupNearfieldTargetsIfNeeded(scope: .allManaged)
                    let configuration = currentConfiguration()
                    try audioManager.setDisplayBalance(
                        currentBalance(),
                        leftDeviceUID: configuration.leftDeviceUID,
                        displayOrderUIDs: configuration.displayOrderUIDs
                    )
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
            leftDeviceUID: NearfieldPreferences.leftDeviceUID(),
            displayOrderUIDs: NearfieldPreferences.displayOrderUIDs()
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

    /// App routes for the driver. Window-scoped routes come from the window
    /// follower; until it has checked, their apps play on both displays.
    func currentRouterRoutingState() -> (enabled: Bool, rules: String) {
        guard appRoutingEnabled() else {
            return (false, "")
        }
        let rawRules = currentRoutingRules()
        guard windowRouteResolver.hasWindowScopedRoute(in: rawRules) else {
            return (true, windowRouteResolver.resolvedRules(from: rawRules))
        }
        return (true, followedRouteRules ?? windowRouteResolver.fallbackRulesWithoutProcessOverrides(from: rawRules))
    }

    func applyCurrentRouterRouteRulesIfNeeded(force: Bool = false) throws {
        guard appRoutingEnabled(), routerDriverManager.isInstalled else { return }
        let resolvedRules = currentRouterRoutingState().rules
        guard force || resolvedRules != lastAppliedRouterRouteRules else { return }
        if force {
            try routerDriverManager.setRoutingEnabled(true)
        }
        try routerDriverManager.setRouteRules(resolvedRules)
        lastAppliedRouterRouteRules = resolvedRules
    }

    /// New window routes from the follower. With driver 1.1 this is the fast
    /// path: applied on the next audio cycle and never written to disk.
    func applyFollowedRouteRules(_ rules: String) {
        followedRouteRules = rules
        guard isSessionActive,
              appRoutingEnabled(),
              cachedRouterDriverAvailability.isLoaded,
              rules != lastAppliedRouterRouteRules else {
            return
        }
        do {
            try routerDriverManager.setRouteRules(rules)
            lastAppliedRouterRouteRules = rules
        } catch {
            recordRecoverableError(error, context: "App Audio Routing refresh failed")
        }
    }

    func updateDynamicRoutingRulesLifecycle() {
        let rawRules = currentRoutingRules()
        let hasWindowScopedRoute = windowRouteResolver.hasWindowScopedRoute(in: rawRules)
        let hasRunningWindowScopedRoute = hasWindowScopedRoute &&
            windowRouteResolver.hasRunningWindowScopedRoute(in: rawRules)
        let driverIsLoaded = cachedRouterDriverAvailability.isLoaded
        let shouldRun = isDynamicRoutingSystemActive &&
            isSessionActive &&
            appRoutingEnabled() &&
            driverIsLoaded &&
            cachedAudioState.detectedDisplays.count >= 2 &&
            hasRunningWindowScopedRoute
        if shouldRun {
            windowRouteFollower.update(
                runningApplications: runningApplicationsCache,
                displayTargets: cachedDisplayTargets(),
                rawRules: rawRules
            )
            windowRouteFollower.start()
            observeNearfieldPlaybackStart()
        } else {
            stopDynamicRoutingRulesTask()
            if appRoutingEnabled(),
               driverIsLoaded,
               hasWindowScopedRoute,
               !hasRunningWindowScopedRoute {
                applyWindowRoutingFallbackRulesIfNeeded(rawRules: rawRules)
            }
        }
    }

    func applyWindowRoutingFallbackRulesIfNeeded(rawRules: String) {
        let fallbackRules = windowRouteResolver.fallbackRulesWithoutProcessOverrides(from: rawRules)
        guard isSessionActive, fallbackRules != lastAppliedRouterRouteRules else { return }
        do {
            try routerDriverManager.setRouteRules(fallbackRules)
            lastAppliedRouterRouteRules = fallbackRules
        } catch {
            recordRecoverableError(error, context: "App Audio Routing cleanup failed")
        }
    }

    func stopDynamicRoutingRulesTask() {
        windowRouteFollower.stop()
        followedRouteRules = nil
        nearfieldRunningObserver?.invalidate()
        nearfieldRunningObserver = nil
        windowFollowPlaybackMonitor?.stop()
        windowFollowPlaybackMonitor = nil
    }

    /// Screen areas of the displays, cached until the screens, displays or
    /// their order change (matching reads IOKit).
    func cachedDisplayTargets() -> [WindowAudioRouteResolver.DisplayTarget] {
        if let displayTargetsCache {
            return displayTargetsCache
        }
        let targets = WindowAudioRouteResolver.currentDisplayTargets(
            displays: cachedAudioState.detectedDisplays,
            leftDeviceUID: NearfieldPreferences.leftDeviceUID(),
            displayOrderUIDs: NearfieldPreferences.displayOrderUIDs()
        )
        displayTargetsCache = targets
        return targets
    }

    /// Checks window routes as soon as an app starts or stops playing, or
    /// (before macOS 14.2) as soon as Nearfield starts playing.
    func observeNearfieldPlaybackStart() {
        if #available(macOS 14.2, *) {
            guard windowFollowPlaybackMonitor == nil else { return }
            let monitor = ProcessPlaybackMonitor { [weak self] in
                self?.windowRouteFollower.checkNow()
            }
            monitor.start()
            windowFollowPlaybackMonitor = monitor
            return
        }
        guard let routerDeviceID = audioManager.deviceID(forUID: RouterAudioDriverManager.routerDeviceUID) else {
            return
        }
        if nearfieldRunningObserver?.observedObjectID == routerDeviceID {
            return
        }
        nearfieldRunningObserver?.invalidate()
        nearfieldRunningObserver = CoreAudioPropertyObserver(
            objectID: routerDeviceID,
            selector: kAudioDevicePropertyDeviceIsRunningSomewhere
        ) { [weak self] in
            self?.windowRouteFollower.checkNow()
        }
    }

    func refreshWindowRouteSnapshot(checkNow: Bool) {
        runningApplicationsCache = Self.currentRunningApplications()
        updateDynamicRoutingRulesLifecycle()
        if checkNow {
            windowRouteFollower.checkNow()
        }
    }

    static func currentRunningApplications() -> [WindowAudioRouteResolver.RunningApplication] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let bundleID = app.bundleIdentifier else { return nil }
            return .init(bundleID: bundleID, processID: app.processIdentifier)
        }
    }

    static func sessionIsOnConsole() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return session[kCGSessionOnConsoleKey as String] as? Bool ?? true
    }

    func observeRouterStatus() {
        routerStatusNotificationsAvailable = cachedRouterDriverAvailability.isLoaded &&
            routerDriverManager.observeStatus { [weak self] in
                self?.handleRouterStatusChange()
            }
    }

    func handleRouterStatusChange() {
        handoffChangeSignal?.fire()
        refreshStatus()
    }

    func configureDynamicRoutingLifecycleNotifications() {
        guard dynamicRoutingNotificationObservers.isEmpty else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let appListChanges: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        dynamicRoutingNotificationObservers = appListChanges.map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshWindowRouteSnapshot(checkNow: false)
                }
            }
        }

        // An app coming to the front or a Space change can move a window
        // between displays without the window itself moving.
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            dynamicRoutingNotificationObservers.append(
                workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.windowRouteFollower.checkNow()
                    }
                }
            )
        }

        dynamicRoutingNotificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.displayTargetsCache = nil
                    self.refreshWindowRouteSnapshot(checkNow: true)
                }
            }
        )

        dynamicRoutingNotificationObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isDynamicRoutingSystemActive = false
                    self?.stopDynamicRoutingRulesTask()
                }
            }
        )

        dynamicRoutingNotificationObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isDynamicRoutingSystemActive = true
                    self?.updateDynamicRoutingRulesLifecycle()
                }
            }
        )

        dynamicRoutingNotificationObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSystemAsleep = true
                }
            }
        )

        dynamicRoutingNotificationObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isSystemAsleep = false
                    self.lastWakeUptime = ProcessInfo.processInfo.systemUptime
                    self.scheduleAudioStateChange()
                }
            }
        )

        dynamicRoutingNotificationObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Fast user switching: the now-active user's Nearfield
                    // configures the driver until this session returns.
                    self.isSessionActive = false
                    self.isDynamicRoutingSystemActive = false
                    self.cancelConnectionHandoff()
                    self.stopDynamicRoutingRulesTask()
                }
            }
        )

        dynamicRoutingNotificationObservers.append(
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isSessionActive = true
                    self.isDynamicRoutingSystemActive = true
                    // Another session may have reconfigured the driver.
                    self.routerDriverManager.resetAppliedSettings()
                    self.lastAppliedRouterRouteRules = nil
                    self.routerOutputActivation.invalidate()
                    self.runningApplicationsCache = Self.currentRunningApplications()
                    self.scheduleAudioStateChange()
                }
            }
        )
    }

}
