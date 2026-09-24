import AppKit
import os
#if NEARFIELD_DISTRIBUTION
import Sparkle
#endif

enum CoreAudioAvailability: Equatable {
    case checking
    case available
    case unavailable
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if NEARFIELD_DISTRIBUTION
    enum UpdateNotification {
        static let requestIdentifier = "nearfield-update-ready"
        static let categoryIdentifier = "nearfield-update"
        static let installActionIdentifier = "nearfield-install-and-relaunch"
        static let laterActionIdentifier = "nearfield-update-later"
    }
    #endif

    let audioManager = StudioDisplayAudioManager()
    let routerDriverManager = RouterAudioDriverManager()
    /// Rule checks and the Settings window's live routes, on the main thread.
    /// Uses the same cached app and screen snapshots as the follower.
    lazy var windowRouteResolver = WindowAudioRouteResolver(
        runningApplications: { [weak self] in
            MainActor.assumeIsolated { self?.runningApplicationsCache ?? [] }
        },
        displayTargets: { [weak self] in
            MainActor.assumeIsolated { self?.cachedDisplayTargets() ?? [] }
        }
    )
    lazy var windowRouteFollower = WindowRouteFollower { [weak self] rules in
        self?.applyFollowedRouteRules(rules)
    }
    var followedRouteRules: String?
    lazy var routingAppCatalog: RoutingAppCatalog = {
        let catalog = RoutingAppCatalog()
        catalog.onUpdate = { [weak self] in
            self?.reconcileRoutingAliases()
            self?.refreshStatus()
        }
        return catalog
    }()
    var runningApplicationsCache: [WindowAudioRouteResolver.RunningApplication] = []
    var displayTargetsCache: [WindowAudioRouteResolver.DisplayTarget]?
    var nearfieldRunningObserver: CoreAudioPropertyObserver?
    var windowFollowPlaybackMonitor: ProcessPlaybackMonitor?
    lazy var testTonePlayer = TestTonePlayer()
    lazy var displayIdentificationController = DisplayIdentificationController()
    let logger = Logger(subsystem: "com.kemuri.Nearfield", category: "AudioState")
    var onboardingWindowController: OnboardingWindowController?
    #if !NEARFIELD_DISTRIBUTION
    var waveLabWindowController: WaveLabWindowController?
    #endif
    lazy var mediaKeyVolumeController = MediaKeyVolumeController(
        audioManager: audioManager,
        routerDriverManager: routerDriverManager
    )
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    #if NEARFIELD_DISTRIBUTION
    var updaterController: SPUStandardUpdaterController?
    var pendingUpdateInstallation: (() -> Void)?
    #endif
    var isInstallingDriver = false
    var driverInstallState: DriverInstallState = .idle
    /// Read at launch, after installing or removing, and when Settings opens.
    var driverDiskState: RouterDriverDiskState = .missing
    var availableDriverUpdate: RouterDriverUpdate?
    var didPromptForDriverUpdate = false
    var audioStateSynchronizationDepth = 0
    var proxyPreparedDisplayState: [DisplayOutputState]?
    var routerVolumeContinuity = RouterVolumeContinuity()
    var pendingAudioStateChangeTask: Task<Void, Never>?
    var pendingDisplayAssignmentTask: Task<Void, Never>?
    var dynamicRoutingNotificationObservers: [NSObjectProtocol] = []
    var isDynamicRoutingSystemActive = true
    var lastAppliedRouterRouteRules: String?
    var hadSufficientStudioDisplays = false
    var connectionActivationPending = false
    var connectionHandoff: RouterConnectionHandoff?
    var connectionHandoffTask: Task<Void, Never>?
    var connectionHandoffFailure: Error?
    var lastNonNearfieldOutputUID: String?
    var lastRuntimeError: String?
    var applicationRemovalMonitor: DispatchSourceFileSystemObject?
    var didPromptForDriverUninstallAfterApplicationRemoval = false
    var isInitialOnboardingInProgress = false
    var coreAudioAvailability: CoreAudioAvailability = .checking
    var cachedAudioState = NearfieldState(
        detectedDisplays: [],
        aggregateDeviceID: nil,
        isAggregateDefaultOutput: false
    )
    var cachedRouterDriverAvailability = RouterDriverAvailability(installedOnDisk: false)
    var cachedRouterDefaultOutput = false
    lazy var routerOutputActivation = makeRouterOutputActivation()
    var routerStatusNotificationsAvailable = false
    var handoffChangeSignal: ChangeSignal?
    var handoffPlaybackMonitor: ProcessPlaybackMonitor?
    /// Only the active user's copy of Nearfield configures the driver.
    var isSessionActive = true
    var isSystemAsleep = false
    var lastWakeUptime: TimeInterval?
    var displayLossGraceTask: Task<Void, Never>?
    var displaysLostDuringSleepWake = false
    var nearfieldWasDefaultBeforeDisplayLoss = false
    var coreAudioReadinessGeneration = 0
    var coreAudioStartupTask: Task<Void, Never>?
    var didStartAudioServices = false
    var isRemovingDriver = false

    enum UninstallScope {
        case driversOnly
        case driversAndApp
    }

    var isSynchronizingAudioState: Bool {
        audioStateSynchronizationDepth > 0
    }

}

extension AppDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchDiagnostics.record("applicationDidFinishLaunching entered")
        if moveToApplicationsIfNeeded() {
            LaunchDiagnostics.record("application move scheduled; terminating original process")
            return
        }
        LaunchDiagnostics.record("application location accepted")
        proxyPreparedDisplayState = loadProxyPreparedDisplayState()
        LaunchDiagnostics.record("loaded saved proxy display state")
        refreshDriverInstallState()
        let routerDriverDiskState = driverDiskState
        LaunchDiagnostics.record("read router driver disk state=\(String(describing: routerDriverDiskState))")
        cachedRouterDriverAvailability = RouterDriverAvailability(
            installedOnDisk: routerDriverDiskState.isCurrent
        )
        isSessionActive = Self.sessionIsOnConsole()
        NearfieldPreferences.migrateOnboardingCompletionIfNeeded(
            currentDriverIsInstalled: routerDriverDiskState.isCurrent
        )
        let hasCompletedOnboarding = NearfieldPreferences.hasCompletedOnboarding()
        isInitialOnboardingInProgress = NearfieldLaunchPolicy.requiresOnboarding(
            hasCompletedOnboarding: hasCompletedOnboarding,
            currentDriverIsInstalled: routerDriverDiskState.isCurrent
        )
        LaunchDiagnostics.record(
            "resolved onboarding state completed=\(hasCompletedOnboarding) " +
                "required=\(isInitialOnboardingInProgress)"
        )
        #if NEARFIELD_DISTRIBUTION
        LaunchDiagnostics.record("configuring Sparkle updater")
        startUpdaterIfEligible(checkImmediately: !isInitialOnboardingInProgress)
        LaunchDiagnostics.record("configured Sparkle updater")
        #endif
        LaunchDiagnostics.record("configuring application and status-item menus")
        configureMenu()
        LaunchDiagnostics.record("configured application and status-item menus")
        finishLaunching(notification: notification)
        LaunchDiagnostics.record("applicationDidFinishLaunching completed")
    }

    func finishLaunching(notification: Notification) {
        LaunchDiagnostics.record("finishLaunching entered")
        configureDynamicRoutingLifecycleNotifications()
        refreshRoutingAppCatalog()
        LaunchDiagnostics.record("configured routing lifecycle notifications")
        startApplicationRemovalMonitorIfNeeded()
        LaunchDiagnostics.record("configured application removal monitor")
        #if !NEARFIELD_DISTRIBUTION
        if ProcessInfo.processInfo.arguments.contains("--wave-lab") {
            openWaveLab()
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--show-onboarding") {
            openOnboarding()
            return
        }
        #endif

        let isDefaultLaunch =
            notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        let isLoginItemLaunch = currentAppleEventIsLoginItemLaunch()
        let initialPresentation = NearfieldLaunchPolicy.initialLaunchPresentation(
            hasCompletedOnboarding: !isInitialOnboardingInProgress,
            isDefaultLaunch: isDefaultLaunch,
            isLoginItemLaunch: isLoginItemLaunch
        )
        LaunchDiagnostics.record(
            "initial presentation=\(String(describing: initialPresentation)) " +
                "defaultLaunch=\(isDefaultLaunch) loginItemLaunch=\(isLoginItemLaunch)"
        )
        switch initialPresentation {
        case .onboarding:
            // First-run onboarding defers Core Audio startup until the user
            // reaches settings; see settingsDidReachSettingsScreen().
            LaunchDiagnostics.record("presenting onboarding window")
            openOnboarding()
            LaunchDiagnostics.record(
                "onboarding presentation returned visible=" +
                    "\(onboardingWindowController?.window?.isVisible == true)"
            )
            return
        case .settings:
            LaunchDiagnostics.record("presenting settings window")
            openSettings()
            LaunchDiagnostics.record(
                "settings presentation returned visible=" +
                    "\(onboardingWindowController?.window?.isVisible == true)"
            )
        case .none:
            break
        }

        LaunchDiagnostics.record("starting Core Audio services")
        startCoreAudioServices { [weak self] in
            self?.promptForDriverUpdateIfNeeded()
        }
        LaunchDiagnostics.record("finishLaunching completed")
    }

    /// Waits for Core Audio, then brings observation, media keys, and dynamic
    /// routing online. Safe to call from either the normal launch path or the
    /// end of first-run onboarding; repeat calls are ignored.
    func startCoreAudioServices(completion: (() -> Void)? = nil) {
        guard !didStartAudioServices, !isRemovingDriver, coreAudioStartupTask == nil else {
            completion?()
            return
        }

        coreAudioStartupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.coreAudioStartupTask = nil }
            var didRecordStartupFailure = false

            while !Task.isCancelled, !self.didStartAudioServices, !self.isRemovingDriver {
                let isReady = await self.refreshCachedAudioState()
                guard !Task.isCancelled else { return }
                if isReady {
                    self.clearRecoverableError()
                    self.startAudioServices()
                    break
                }

                if !didRecordStartupFailure {
                    self.recordRecoverableError(
                        CoreAudioStartupError.unavailable,
                        context: "Core Audio startup failed"
                    )
                    didRecordStartupFailure = true
                }
                self.refreshStatus()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            self.refreshStatus()
            completion?()
        }
    }

    func startAudioServices() {
        guard !didStartAudioServices else { return }
        didStartAudioServices = true
        runningApplicationsCache = Self.currentRunningApplications()
        observeRouterStatus()
        observeConnectionDefaultOutput()
        hadSufficientStudioDisplays = cachedAudioState.detectedDisplays.count >= 2
        preparePairOnLaunch()
        mediaKeyVolumeController.start()
        audioManager.startObserving { [weak self] in
            Task { @MainActor in
                self?.observeConnectionDefaultOutput()
                self?.scheduleAudioStateChange()
            }
        }
        handleAudioStateChange()
    }

    /// Reads the installed driver from disk. Only at launch, after installing
    /// or removing, and when Settings opens: not on every audio change.
    func refreshDriverInstallState() {
        driverDiskState = DriverInstaller.routerDriverDiskState()
        refreshDriverUpdateAvailability()
    }

    func currentRouterDriverAvailability(
        coreAudioIsReady: Bool = false
    ) -> RouterDriverAvailability {
        let currentDriverIsInstalled = driverDiskState.isCurrent
        return RouterDriverAvailability(
            installedOnDisk: currentDriverIsInstalled,
            loadedByCoreAudio: currentDriverIsInstalled &&
                coreAudioIsReady &&
                routerDriverManager.isInstalled
        )
    }

    func refreshCachedAudioState(timeout: TimeInterval = 5) async -> Bool {
        coreAudioAvailability = .checking
        coreAudioReadinessGeneration += 1
        let generation = coreAudioReadinessGeneration
        let isReady = await CoreAudioReadinessProbe.waitUntilReady(timeout: timeout)
        guard isReady else {
            if generation == coreAudioReadinessGeneration {
                coreAudioAvailability = .unavailable
                cachedRouterDriverAvailability = currentRouterDriverAvailability()
                cachedRouterDefaultOutput = false
            }
            return false
        }

        audioManager.invalidateCachedDevices()
        cachedAudioState = audioManager.currentState()
        cachedRouterDriverAvailability = currentRouterDriverAvailability(coreAudioIsReady: true)
        cachedRouterDefaultOutput = cachedRouterDriverAvailability.isLoaded &&
            routerDriverManager.isRouterDefaultOutput()
        coreAudioAvailability = .available
        return true
    }

    func invalidateCoreAudioReadiness() {
        coreAudioReadinessGeneration += 1
        coreAudioAvailability = .checking
        cachedRouterDriverAvailability = currentRouterDriverAvailability()
        cachedRouterDefaultOutput = false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentPrimaryWindow()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        LaunchDiagnostics.record("applicationWillTerminate entered")
        stopApplicationRemovalMonitor()
        coreAudioStartupTask?.cancel()
        coreAudioReadinessGeneration += 1
        pendingAudioStateChangeTask?.cancel()
        cancelConnectionHandoff()
        windowRouteFollower.stop()
        displayLossGraceTask?.cancel()
        dynamicRoutingNotificationObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        dynamicRoutingNotificationObservers.removeAll()
        mediaKeyVolumeController.stop()
        routerDriverManager.stopObservingStatus()
        audioManager.stopObserving()
        LaunchDiagnostics.record("applicationWillTerminate completed")
    }

}
