import AppKit
import Darwin
import os
import ServiceManagement
#if NEARFIELD_DISTRIBUTION
import Sparkle
import UserNotifications
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    #if NEARFIELD_DISTRIBUTION
    private enum UpdateNotification {
        static let requestIdentifier = "nearfield-update-ready"
        static let categoryIdentifier = "nearfield-update"
        static let installActionIdentifier = "nearfield-install-and-relaunch"
        static let laterActionIdentifier = "nearfield-update-later"
    }
    #endif

    private enum CoreAudioAvailability: Equatable {
        case checking
        case available
        case unavailable
    }

    private let audioManager = StudioDisplayAudioManager()
    private let routerDriverManager = RouterAudioDriverManager()
    private let windowRouteResolver = WindowAudioRouteResolver()
    private lazy var testTonePlayer = TestTonePlayer()
    private let logger = Logger(subsystem: "com.kemuri.Nearfield", category: "AudioState")
    private var onboardingWindowController: OnboardingWindowController?
    #if !NEARFIELD_DISTRIBUTION
    private var waveLabWindowController: WaveLabWindowController?
    #endif
    private lazy var mediaKeyVolumeController = MediaKeyVolumeController(
        audioManager: audioManager,
        routerDriverManager: routerDriverManager
    )
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    #if NEARFIELD_DISTRIBUTION
    private var updaterController: SPUStandardUpdaterController?
    private var pendingUpdateInstallation: (() -> Void)?
    #endif
    private var isInstallingDriver = false
    private var audioStateSynchronizationDepth = 0
    private var proxyPreparedDisplayState: [DisplayOutputState]?
    private var pendingAudioStateChangeTask: Task<Void, Never>?
    private var dynamicRoutingRulesTask: Task<Void, Never>?
    private var dynamicRoutingNotificationObservers: [NSObjectProtocol] = []
    private var isDynamicRoutingSystemActive = true
    private var lastAppliedRouterRouteRules: String?
    private var hadSufficientStudioDisplays = false
    private var shouldReactivateVirtualOutputAfterDisplayReconnect = false
    private var lastRuntimeError: String?
    private var applicationRemovalMonitor: DispatchSourceFileSystemObject?
    private var didPromptForDriverUninstallAfterApplicationRemoval = false
    private var isInitialOnboardingInProgress = false
    private var coreAudioAvailability: CoreAudioAvailability = .checking
    private var cachedAudioState = NearfieldState(
        detectedDisplays: [],
        aggregateDeviceID: nil,
        isAggregateDefaultOutput: false
    )
    private var cachedRouterDriverAvailability = RouterDriverAvailability(
        installedOnDisk: DriverInstaller.isRouterDriverInstalledOnDisk()
    )
    private var cachedRouterDefaultOutput = false
    private var coreAudioReadinessGeneration = 0
    private var coreAudioStartupTask: Task<Void, Never>?
    private var didStartAudioServices = false

    private enum UninstallScope {
        case driversOnly
        case driversAndApp
    }

    private var isSynchronizingAudioState: Bool {
        audioStateSynchronizationDepth > 0
    }

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

    #if NEARFIELD_DISTRIBUTION
    private func startUpdaterIfEligible(checkImmediately: Bool) {
        guard updaterController == nil else { return }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard isInApplicationsDirectory(bundleURL) else { return }

        configureUpdateNotifications()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        updaterController = controller

        guard checkImmediately, controller.updater.automaticallyChecksForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    private func configureUpdateNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let installAction = UNNotificationAction(
            identifier: UpdateNotification.installActionIdentifier,
            title: "Install and Relaunch",
            options: [.foreground]
        )
        let laterAction = UNNotificationAction(
            identifier: UpdateNotification.laterActionIdentifier,
            title: "Later",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: UpdateNotification.categoryIdentifier,
                actions: [installAction, laterAction],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    /// What to do when a notification cannot be posted. The install-on-quit
    /// path can offer to install immediately; a scheduled reminder has nothing
    /// staged yet, so it defers to Sparkle's own update window.
    private enum UpdateNotificationFallback {
        case offerPendingInstall
        case sparkleUpdateWindow
    }

    private func presentUpdateNotification(version: String, fallback: UpdateNotificationFallback) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let canNotify: Bool
            switch settings.authorizationStatus {
            case .notDetermined:
                canNotify = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            case .authorized, .provisional, .ephemeral:
                canNotify = settings.alertSetting == .enabled
            case .denied:
                canNotify = false
            @unknown default:
                canNotify = false
            }

            guard canNotify else {
                applyUpdateNotificationFallback(fallback, version: version)
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Nearfield \(version) is ready"
            content.body = "Install the update now and relaunch Nearfield."
            content.categoryIdentifier = UpdateNotification.categoryIdentifier
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UpdateNotification.requestIdentifier,
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                applyUpdateNotificationFallback(fallback, version: version)
            }
        }
    }

    private func applyUpdateNotificationFallback(_ fallback: UpdateNotificationFallback, version: String) {
        switch fallback {
        case .offerPendingInstall:
            presentUpdateAlert(version: version)
        case .sparkleUpdateWindow:
            NSApp.activate(ignoringOtherApps: true)
            updaterController?.checkForUpdates(nil)
        }
    }

    private func presentUpdateAlert(version: String) {
        guard pendingUpdateInstallation != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Nearfield \(version) is ready"
        alert.informativeText = "Install the update now and relaunch Nearfield?"
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            installPendingUpdate()
        }
    }

    private func installPendingUpdate() {
        guard let install = pendingUpdateInstallation else {
            updaterController?.checkForUpdates(nil)
            return
        }
        dismissUpdateNotification()
        install()
    }

    private func handleUpdateNotificationAction(_ actionIdentifier: String) {
        switch actionIdentifier {
        case UpdateNotification.installActionIdentifier:
            installPendingUpdate()
        case UNNotificationDefaultActionIdentifier:
            dismissUpdateNotification()
            NSApp.activate(ignoringOtherApps: true)
            updaterController?.checkForUpdates(nil)
        default:
            break
        }
    }

    private func dismissUpdateNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [UpdateNotification.requestIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [UpdateNotification.requestIdentifier])
    }

    private func clearPendingUpdate() {
        pendingUpdateInstallation = nil
        dismissUpdateNotification()
        rebuildMenu()
    }
    #endif

    private func finishLaunching(notification: Notification) {
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
    private func startCoreAudioServices(completion: (() -> Void)? = nil) {
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

    private func startAudioServices() {
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

    private func currentRouterDriverAvailability(
        coreAudioIsReady: Bool = false
    ) -> RouterDriverAvailability {
        RouterDriverAvailability(
            installedOnDisk: DriverInstaller.isRouterDriverInstalledOnDisk(),
            loadedByCoreAudio: coreAudioIsReady && routerDriverManager.isInstalled
        )
    }

    private func refreshCachedAudioState(timeout: TimeInterval = 5) async -> Bool {
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

    private func invalidateCoreAudioReadiness() {
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

    private func configureMenu() {
        statusItem.button?.image = menuBarIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""
        menu.delegate = self
        applyMenuBarState()
    }

    private func menuBarIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "menubar", withExtension: "svg", subdirectory: "Icons") ??
            Bundle.module.url(forResource: "menubar", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "hifispeaker.2", accessibilityDescription: "Nearfield")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Nearfield"
        return image
    }

    private func moveToApplicationsIfNeeded() -> Bool {
        guard !ProcessInfo.processInfo.arguments.contains("--skip-move-prompt") else {
            return false
        }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard bundleURL.pathExtension == "app",
              !isInApplicationsDirectory(bundleURL) else {
            return false
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Nearfield to Applications?"
        alert.informativeText = "Nearfield works best from the Applications folder. Move it there before continuing setup?"
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        let destinationURL = URL(fileURLWithPath: "/Applications/Nearfield.app", isDirectory: true)
        do {
            try ApplicationMover.installBundle(from: bundleURL, to: destinationURL)
            try relaunchFromApplications(at: destinationURL)
            NSApp.terminate(nil)
            return true
        } catch {
            let failureAlert = NSAlert(error: error)
            failureAlert.messageText = "Nearfield could not be moved"
            failureAlert.informativeText = "You can move Nearfield.app to Applications manually. Setup will continue from the current location."
            failureAlert.runModal()
            return false
        }
    }

    private func isInApplicationsDirectory(_ bundleURL: URL) -> Bool {
        let parentURL = bundleURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return parentURL.path == applicationsURL.path
    }

    private func relaunchFromApplications(at appURL: URL) throws {
        guard NSWorkspace.shared.open(appURL) else {
            throw NSError(
                domain: "com.kemuri.Nearfield",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not launch Nearfield from Applications."]
            )
        }
    }

    private func startApplicationRemovalMonitorIfNeeded() {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard applicationRemovalMonitor == nil,
              isInApplicationsDirectory(bundleURL) else {
            return
        }

        let fileDescriptor = Darwin.open(bundleURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.delete, .rename],
            queue: .main
        )
        monitor.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleApplicationRemovalEvent(bundleURL: bundleURL)
            }
        }
        monitor.setCancelHandler {
            Darwin.close(fileDescriptor)
        }
        applicationRemovalMonitor = monitor
        monitor.resume()
    }

    private func stopApplicationRemovalMonitor() {
        applicationRemovalMonitor?.cancel()
        applicationRemovalMonitor = nil
    }

    private func handleApplicationRemovalEvent(bundleURL: URL) {
        guard !didPromptForDriverUninstallAfterApplicationRemoval else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            Task { @MainActor [weak self] in
                self?.promptForDriverUninstallIfApplicationWasRemoved(bundleURL: bundleURL)
            }
        }
    }

    private func promptForDriverUninstallIfApplicationWasRemoved(bundleURL: URL) {
        guard !didPromptForDriverUninstallAfterApplicationRemoval,
              !FileManager.default.fileExists(atPath: bundleURL.path) else {
            return
        }

        didPromptForDriverUninstallAfterApplicationRemoval = true
        stopApplicationRemovalMonitor()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Nearfield Drivers?"
        alert.informativeText = "Nearfield.app was removed from Applications. Do you also want to remove the Nearfield audio driver and virtual target devices from this Mac?"
        alert.addButton(withTitle: "Uninstall Drivers")
        alert.addButton(withTitle: "Keep Drivers")

        if alert.runModal() == .alertFirstButtonReturn {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.removeDriversAndTargets()
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.terminate(nil)
    }

    private func currentApplicationBundleURL() -> URL {
        Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func promptForUninstallScope() -> UninstallScope? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Nearfield?"
        alert.informativeText = "Choose whether to remove only the Nearfield virtual audio drivers, or remove the drivers and Nearfield.app from Applications."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Drivers Only")
        alert.addButton(withTitle: "Drivers & App")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return nil
        case .alertSecondButtonReturn:
            return .driversOnly
        case .alertThirdButtonReturn:
            return .driversAndApp
        default:
            return nil
        }
    }

    @discardableResult
    private func presentInitialOnboardingIfNeeded() -> Bool {
        guard !cachedRouterDriverAvailability.isInstalled else { return false }
        openOnboarding()
        return true
    }

    private func presentSettingsIfMenuBarAppIsHiddenAfterDefaultLaunch(_ notification: Notification) {
        guard !showMenuBarApp(),
              notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true else {
            return
        }
        openSettings()
    }

    private func refreshStatus() {
        onboardingWindowController?.reload()
    }

    private func preparePairOnLaunch() {
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

    private func configureRouterDriver(activate: Bool = true) throws {
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
            if let activationVolume = averageCapturedDisplayVolume(capturedDisplayState) {
                try routerDriverManager.setBalancedVolume(activationVolume, balance: currentBalance())
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

    private func performSynchronizedAudioUpdate(_ work: () throws -> Void) rethrows {
        audioStateSynchronizationDepth += 1
        defer { audioStateSynchronizationDepth -= 1 }
        try work()
    }

    private func handleAudioStateChange() {
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

    private func handleStudioDisplaysAvailable(state: NearfieldState, activateVirtualOutput: Bool) throws {
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

    private func handleStudioDisplaysUnavailable(state: NearfieldState) throws {
        dynamicRoutingRulesTask?.cancel()
        dynamicRoutingRulesTask = nil
        lastAppliedRouterRouteRules = nil

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

    private func scheduleAudioStateChange() {
        pendingAudioStateChangeTask?.cancel()
        pendingAudioStateChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.pendingAudioStateChangeTask = nil
            self?.handleAudioStateChange()
        }
    }

    private func prepareDisplaysForVirtualOutputActivation() throws -> [DisplayOutputState]? {
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

    private func averageCapturedDisplayVolume(_ displayState: [DisplayOutputState]?) -> Float32? {
        guard let displayState else { return nil }
        let values = displayState.compactMap(\.volume)
        guard !values.isEmpty else { return nil }
        return min(max(values.reduce(0, +) / Float32(values.count), 0), 1)
    }

    private func restoreDisplaysAfterProxyDeactivation() throws {
        guard let displayState = proxyPreparedDisplayState else { return }
        try audioManager.restoreDisplayOutputState(displayState)
        proxyPreparedDisplayState = nil
        saveProxyPreparedDisplayState(nil)
    }

    private enum AggregateCleanupScope: Equatable {
        case appOwned
        case allManaged
    }

    private func cleanupNearfieldTargetsIfNeeded(
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

    private func nearfieldVirtualOutputIsDefaultOutput(state: NearfieldState? = nil) -> Bool {
        let currentState = state ?? audioManager.currentState()
        return currentState.isAggregateDefaultOutput ||
            NearfieldAudioIdentifiers.virtualOutputUIDs.contains { uid in
                audioManager.isDefaultOutputDevice(uid: uid)
            }
    }

    private func nearfieldVirtualOutputIsAnyDefault(state: NearfieldState? = nil) -> Bool {
        let currentState = state ?? audioManager.currentState()
        return nearfieldVirtualOutputIsDefaultOutput(state: currentState) ||
            NearfieldAudioIdentifiers.virtualOutputUIDs.contains { uid in
                audioManager.isDefaultSystemOutputDevice(uid: uid)
            }
    }

    private func loadProxyPreparedDisplayState() -> [DisplayOutputState]? {
        guard let data = NearfieldPreferences.proxyPreparedDisplayStateData() else {
            return nil
        }
        return try? JSONDecoder().decode([DisplayOutputState].self, from: data)
    }

    private func saveProxyPreparedDisplayState(_ state: [DisplayOutputState]?) {
        guard let state else {
            NearfieldPreferences.setProxyPreparedDisplayStateData(nil)
            return
        }
        if let data = try? JSONEncoder().encode(state) {
            NearfieldPreferences.setProxyPreparedDisplayStateData(data)
        }
    }

    private func setMode(_ mode: NearfieldOutputMode) {
        NearfieldPreferences.setOutputMode(mode)
    }

    private func rebuildForConfigurationChange() {
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

    private func markAggregateSchemaCurrent() {
        NearfieldPreferences.markAggregateSchemaCurrent()
    }

    private func currentConfiguration() -> NearfieldConfiguration {
        NearfieldConfiguration(
            mode: currentMode(),
            leftDeviceUID: NearfieldPreferences.leftDeviceUID()
        )
    }

    private func currentMode() -> NearfieldOutputMode {
        NearfieldPreferences.outputMode()
    }

    private func currentBalance() -> Float32 {
        NearfieldPreferences.balance()
    }

    private func appRoutingEnabled() -> Bool {
        NearfieldPreferences.appRoutingEnabled()
    }

    private func currentRoutingRules() -> String {
        NearfieldPreferences.appRoutingRules()
    }

    private func currentRouterRoutingState() -> (enabled: Bool, rules: String) {
        guard appRoutingEnabled() else {
            return (false, "")
        }
        let rawRules = currentRoutingRules()
        return (true, windowRouteResolver.resolvedRules(from: rawRules))
    }

    private func applyCurrentRouterRouteRulesIfNeeded(force: Bool = false) throws {
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

    private func updateDynamicRoutingRulesLifecycle() {
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

    private func startDynamicRoutingRulesTask() {
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

    private func applyWindowRoutingFallbackRulesIfNeeded(rawRules: String) {
        let fallbackRules = windowRouteResolver.fallbackRulesWithoutProcessOverrides(from: rawRules)
        guard fallbackRules != lastAppliedRouterRouteRules else { return }
        do {
            try routerDriverManager.setRouteRules(fallbackRules)
            lastAppliedRouterRouteRules = fallbackRules
        } catch {
            recordRecoverableError(error, context: "App Audio Routing cleanup failed")
        }
    }

    private func stopDynamicRoutingRulesTask() {
        dynamicRoutingRulesTask?.cancel()
        dynamicRoutingRulesTask = nil
    }

    private func configureDynamicRoutingLifecycleNotifications() {
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

    @objc private func openSettings() {
        guard !isInitialOnboardingInProgress else {
            onboardingWindowController?.show()
            return
        }
        showOnboardingSettingsStage(showsPageIndicator: false)
    }

    @objc private func openOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(delegate: self)
        }
        onboardingWindowController?.showOnboardingSimulation()
    }

    #if !NEARFIELD_DISTRIBUTION
    @objc private func openOnboardingSettingsStage() {
        showOnboardingSettingsStage(showsPageIndicator: true)
    }
    #endif

    private func showOnboardingSettingsStage(showsPageIndicator: Bool) {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(delegate: self)
        }
        onboardingWindowController?.showSettingsStage(showsPageIndicator: showsPageIndicator)
    }

    #if !NEARFIELD_DISTRIBUTION
    @objc private func openWaveLab() {
        if waveLabWindowController == nil {
            waveLabWindowController = WaveLabWindowController()
        }
        waveLabWindowController?.show()
    }
    #endif

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showError(error)
        }
        refreshStatus()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        guard NearfieldRouterPolicy.shouldShowFullMenuBarMenu(
            isInitialOnboardingInProgress: isInitialOnboardingInProgress
        ) else {
            addQuitMenuItem()
            return
        }

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        #if NEARFIELD_DISTRIBUTION
        if let updaterController {
            let updatesItem = NSMenuItem(
                title: "Check for Updates...",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
            updatesItem.target = self
            updatesItem.isEnabled = updaterController.updater.canCheckForUpdates
            menu.addItem(updatesItem)
        }
        if pendingUpdateInstallation != nil {
            let installUpdateItem = NSMenuItem(
                title: "Install Update and Relaunch",
                action: #selector(installPendingUpdateFromMenu),
                keyEquivalent: ""
            )
            installUpdateItem.target = self
            menu.addItem(installUpdateItem)
        }
        #endif

        menu.addItem(.separator())

        #if !NEARFIELD_DISTRIBUTION
        let onboardingItem = NSMenuItem(title: "Onboarding", action: #selector(openOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        let setupItem = NSMenuItem(title: "Setup", action: #selector(openOnboardingSettingsStage), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        let waveLabItem = NSMenuItem(title: "Wave Lab", action: #selector(openWaveLab), keyEquivalent: "")
        waveLabItem.target = self
        menu.addItem(waveLabItem)
        #endif

        addQuitMenuItem()
    }

    #if NEARFIELD_DISTRIBUTION
    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    @objc private func installPendingUpdateFromMenu() {
        installPendingUpdate()
    }
    #endif

    private func addQuitMenuItem() {
        let quitItem = NSMenuItem(title: "Quit", action: #selector(confirmQuitHelper), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func confirmQuitHelper() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Nearfield Helper?"
        alert.informativeText = "Quitting the helper will probably result in degraded performance for Nearfield. It keeps routing and audio state in sync while you use the virtual output."
        alert.addButton(withTitle: "Quit Helper")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        NSApp.terminate(nil)
    }

    private func applyMenuBarState() {
        statusItem.isVisible = showMenuBarApp()
        statusItem.button?.isEnabled = true
        statusItem.menu = menu
        rebuildMenu()
    }

    private func showMenuBarApp() -> Bool {
        NearfieldPreferences.showMenuBarApp()
    }

    private func installAndActivateRouterDriver(_ request: DriverInstallRequest) {
        guard !isInstallingDriver else { return }
        let studioDisplayCount = cachedAudioState.detectedDisplays.count
        guard NearfieldRouterPolicy.shouldAttemptDriverInstall(
            studioDisplayCount: studioDisplayCount,
            allowsMissingStudioDisplays: request.allowsMissingStudioDisplays
        ) else {
            finishDriverInstallAttempt(disableAppRouting: request.disablesAppRoutingOnFailure)
            handleDriverInstallError(
                NearfieldError.notEnoughStudioDisplays(studioDisplayCount),
                presentsErrors: request.presentsErrors
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
                finishDriverInstallAttempt(disableAppRouting: request.disablesAppRoutingOnFailure)
                return
            }
        }
        isInstallingDriver = true
        refreshStatus()

        Task { [weak self] in
            guard let self else { return }
            do {
                let driverPath = try await Task.detached(priority: .userInitiated) {
                    try DriverInstaller().buildRouterDriver()
                }.value
                try await Task.detached(priority: .userInitiated) {
                    try DriverInstaller().installBuiltRouterDriver(at: driverPath)
                }.value
                self.invalidateCoreAudioReadiness()
                guard await self.waitForRouterDriverAfterCoreAudioRestart() else {
                    throw RouterAudioDriverError.notInstalled
                }
                try await self.configureRouterDriverAfterInstall(
                    allowsMissingStudioDisplays: request.allowsMissingStudioDisplays
                )
                _ = await self.refreshCachedAudioState()
            } catch {
                self.finishDriverInstallAttempt(
                    disableAppRouting: request.disablesAppRoutingOnFailure
                )
                self.handleDriverInstallError(error, presentsErrors: request.presentsErrors)
                return
            }
            self.finishDriverInstallAttempt(disableAppRouting: false)
        }
    }

    private func handleDriverInstallError(_ error: Error, presentsErrors: Bool) {
        if presentsErrors {
            showError(error)
        } else {
            recordRecoverableError(error, context: "Driver install failed")
        }
    }

    private func finishDriverInstallAttempt(disableAppRouting: Bool) {
        if disableAppRouting {
            NearfieldPreferences.setAppRoutingEnabled(false)
        }
        isInstallingDriver = false
        updateDynamicRoutingRulesLifecycle()
        refreshStatus()
    }

    private func configureRouterDriverAfterInstall(
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

    private func waitForRouterDriverAfterCoreAudioRestart(
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

    private func waitForSufficientStudioDisplaysAfterCoreAudioRestart(
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

    private func deactivateRouterDriver() {
        updateDynamicRoutingRulesLifecycle()
        do {
            if routerDriverManager.isInstalled {
                try routerDriverManager.setRoutingEnabled(false)
            }
        } catch {
            showError(error)
        }
    }

    private func confirmPrivilegedInstall(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ error: Error) {
        recordRecoverableError(error, context: "Audio update failed")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Nearfield could not update audio devices"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func recordRecoverableError(_ error: Error, context: String) {
        let message = "\(context): \(error.localizedDescription)"
        lastRuntimeError = message
        logger.error("\(message, privacy: .public)")
    }

    private func clearRecoverableError() {
        lastRuntimeError = nil
    }
}

#if NEARFIELD_DISTRIBUTION
extension AppDelegate: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        pendingUpdateInstallation = immediateInstallHandler
        rebuildMenu()
        presentUpdateNotification(version: item.displayVersionString, fallback: .offerPendingInstall)
        return true
    }
}

extension AppDelegate: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Let Sparkle present the update itself only when it already proposes
        // immediate focus. Otherwise we take over and post a gentle reminder
        // rather than pulling a menu bar app in front of the user's work.
        // Must stay side-effect free per SPUStandardUserDriverDelegate.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else {
            // We declined above, so this scheduled reminder is ours to show.
            presentUpdateNotification(
                version: update.displayVersionString,
                fallback: .sparkleUpdateWindow
            )
            return
        }
        dismissUpdateNotification()
        // Only take focus for a check the user actually asked for. Sparkle
        // guarantees handleShowingUpdate is true whenever userInitiated is.
        guard state.userInitiated else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        dismissUpdateNotification()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearPendingUpdate()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.categoryIdentifier == UpdateNotification.categoryIdentifier else {
            return
        }
        let actionIdentifier = response.actionIdentifier
        await handleUpdateNotificationAction(actionIdentifier)
    }
}
#endif

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}

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
    private func removeDriversAndTargets() async -> Bool {
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
