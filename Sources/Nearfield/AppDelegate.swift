import AppKit
import os
#if NEARFIELD_DISTRIBUTION
import Sparkle
#endif

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

    enum CoreAudioAvailability: Equatable {
        case checking
        case available
        case unavailable
    }

    let audioManager = StudioDisplayAudioManager()
    let routerDriverManager = RouterAudioDriverManager()
    let windowRouteResolver = WindowAudioRouteResolver()
    lazy var testTonePlayer = TestTonePlayer()
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
    var audioStateSynchronizationDepth = 0
    var proxyPreparedDisplayState: [DisplayOutputState]?
    var pendingAudioStateChangeTask: Task<Void, Never>?
    var dynamicRoutingRulesTask: Task<Void, Never>?
    var dynamicRoutingNotificationObservers: [NSObjectProtocol] = []
    var isDynamicRoutingSystemActive = true
    var lastAppliedRouterRouteRules: String?
    var hadSufficientStudioDisplays = false
    var shouldReactivateVirtualOutputAfterDisplayReconnect = false
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
    var cachedRouterDriverAvailability = RouterDriverAvailability(
        installedOnDisk: DriverInstaller.isRouterDriverInstalledOnDisk()
    )
    var cachedRouterDefaultOutput = false
    var coreAudioReadinessGeneration = 0
    var coreAudioStartupTask: Task<Void, Never>?
    var didStartAudioServices = false

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
        if moveToApplicationsIfNeeded() {
            return
        }
        proxyPreparedDisplayState = loadProxyPreparedDisplayState()
        cachedRouterDriverAvailability = currentRouterDriverAvailability()
        isInitialOnboardingInProgress = !cachedRouterDriverAvailability.isInstalled
        #if NEARFIELD_DISTRIBUTION
        startUpdaterIfEligible(checkImmediately: !isInitialOnboardingInProgress)
        #endif
        configureMenu()
        finishLaunching(notification: notification)
    }

    func finishLaunching(notification: Notification) {
        configureDynamicRoutingLifecycleNotifications()
        startApplicationRemovalMonitorIfNeeded()
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
        // First-run onboarding defers Core Audio startup until the user reaches
        // the settings screen; see settingsDidReachSettingsScreen().
        if presentInitialOnboardingIfNeeded() {
            return
        }

        startCoreAudioServices { [weak self] in
            self?.presentSettingsIfMenuBarAppIsHiddenAfterDefaultLaunch(notification)
        }
    }

    /// Waits for Core Audio, then brings observation, media keys, and dynamic
    /// routing online. Safe to call from either the normal launch path or the
    /// end of first-run onboarding; repeat calls are ignored.
    func startCoreAudioServices(completion: (() -> Void)? = nil) {
        guard !didStartAudioServices, coreAudioStartupTask == nil else {
            completion?()
            return
        }

        coreAudioStartupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let isReady = await self.refreshCachedAudioState()
            guard !Task.isCancelled else { return }
            if isReady {
                self.startAudioServices()
            } else {
                self.recordRecoverableError(
                    CoreAudioStartupError.unavailable,
                    context: "Core Audio startup failed"
                )
            }
            self.refreshStatus()
            completion?()
            self.coreAudioStartupTask = nil
        }
    }

    func startAudioServices() {
        guard !didStartAudioServices else { return }
        didStartAudioServices = true
        hadSufficientStudioDisplays = cachedAudioState.detectedDisplays.count >= 2
        preparePairOnLaunch()
        mediaKeyVolumeController.start()
        audioManager.startObserving { [weak self] in
            Task { @MainActor in self?.scheduleAudioStateChange() }
        }
        handleAudioStateChange()
    }

    func currentRouterDriverAvailability(
        coreAudioIsReady: Bool = false
    ) -> RouterDriverAvailability {
        RouterDriverAvailability(
            installedOnDisk: DriverInstaller.isRouterDriverInstalledOnDisk(),
            loadedByCoreAudio: coreAudioIsReady && routerDriverManager.isInstalled
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
        if isInitialOnboardingInProgress {
            onboardingWindowController?.show()
            return false
        }
        guard !showMenuBarApp() else {
            return true
        }
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopApplicationRemovalMonitor()
        coreAudioStartupTask?.cancel()
        coreAudioReadinessGeneration += 1
        pendingAudioStateChangeTask?.cancel()
        dynamicRoutingRulesTask?.cancel()
        dynamicRoutingNotificationObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        dynamicRoutingNotificationObservers.removeAll()
        mediaKeyVolumeController.stop()
        audioManager.stopObserving()
    }

}
