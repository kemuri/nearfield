import AppKit
import Darwin
import os
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum DefaultsKey {
        static let outputMode = "outputMode"
        static let leftDeviceUID = "leftDeviceUID"
        static let balance = "balance"
        static let simulatedStatus = "simulatedStatus"
        static let advancedExpanded = "advancedExpanded"
        static let showMenuBarApp = "showMenuBarApp"
        static let aggregateSchemaVersion = "aggregateSchemaVersion"
        static let proxyPreparedDisplayState = "proxyPreparedDisplayState"
        static let appRoutingEnabled = NearfieldPreferences.appRoutingEnabledKey
        static let appRoutingRules = NearfieldPreferences.appRoutingRulesKey
        static let appRoutingAppBundleIDs = NearfieldPreferences.appRoutingAppBundleIDsKey
        static let latestAggregateSchemaVersion = 12
    }

    private static let virtualOutputUIDs = [
        "ProxyAudioDevice_UID",
        "StudioPairRouterAudioDevice_UID",
        RouterAudioDriverManager.routerDeviceUID,
        RouterAudioDriverManager.driverTargetAggregateUID,
        "com.kemuri.Nearfield.TargetAggregate"
    ]

    private enum SimulatedStatus: String, CaseIterable {
        case off
        case ready
        case missingDisplays
        case driverMissing
        case installing
        case notSelected

        var title: String {
            switch self {
            case .off: "Use Live State"
            case .ready: "Ready"
            case .missingDisplays: "Displays Missing"
            case .driverMissing: "Driver Missing"
            case .installing: "Installing"
            case .notSelected: "Not Selected"
            }
        }

        var symbolName: String {
            switch self {
            case .off: "dot.radiowaves.left.and.right"
            case .ready: "checkmark.circle.fill"
            case .missingDisplays: "display.trianglebadge.exclamationmark"
            case .driverMissing: "xmark.circle.fill"
            case .installing: "arrow.triangle.2.circlepath.circle.fill"
            case .notSelected: "exclamationmark.circle.fill"
            }
        }
    }

    private let audioManager = StudioDisplayAudioManager()
    private let routerDriverManager = RouterAudioDriverManager()
    private let windowRouteResolver = WindowAudioRouteResolver()
    private let testTonePlayer = TestTonePlayer()
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
    private lazy var balanceMenuView = MenuBalanceRowView(
        value: settingsBalance(),
        isEnabled: false,
        onChange: { [weak self] balance in
            self?.settingsSetBalance(balance)
        }
    )

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

    private enum UninstallScope {
        case driversOnly
        case driversAndApp
    }

    override init() {
        super.init()
    }

    private var isSynchronizingAudioState: Bool {
        audioStateSynchronizationDepth > 0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        proxyPreparedDisplayState = loadProxyPreparedDisplayState()
        hadSufficientStudioDisplays = audioManager.currentState().detectedDisplays.count >= 2
        isInitialOnboardingInProgress = !routerDriverManager.isInstalled
        configureMenu()
        if moveToApplicationsIfNeeded() {
            return
        }
        finishLaunching(notification: notification)
    }

    private func finishLaunching(notification: Notification) {
        configureDynamicRoutingLifecycleNotifications()
        preparePairOnLaunch()
        mediaKeyVolumeController.start()
        refreshStatus()
        audioManager.startObserving { [weak self] in
            Task { @MainActor in self?.scheduleAudioStateChange() }
        }
        startApplicationRemovalMonitorIfNeeded()
        handleAudioStateChange()
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
        if presentInitialOnboardingIfNeeded() {
            return
        }
        presentSettingsIfMenuBarAppIsHiddenAfterDefaultLaunch(notification)
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
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: bundleURL, to: destinationURL)
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
        alert.addButton(withTitle: "Drivers Only")
        alert.addButton(withTitle: "Drivers & App")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .driversOnly
        case .alertSecondButtonReturn:
            return .driversAndApp
        default:
            return nil
        }
    }

    @discardableResult
    private func presentInitialOnboardingIfNeeded() -> Bool {
        guard !routerDriverManager.isInstalled else { return false }
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
        let state = audioManager.currentState()
        let shouldActivateVirtualOutput = nearfieldVirtualOutputIsDefaultOutput(state: state)
        guard state.detectedDisplays.count >= 2 else {
            return
        }

        do {
            try performSynchronizedAudioUpdate {
                if routerDriverManager.isInstalled {
                    try configureRouterDriver(activate: shouldActivateVirtualOutput)
                } else {
                    try cleanupStaleNearfieldTargetsIfNeeded(state: state)
                }
            }
        } catch {
            recordRecoverableError(error, context: "Launch audio setup failed")
        }
    }

    @objc private func cleanupAggregates() {
        do {
            try performSynchronizedAudioUpdate {
                let shouldActivateVirtualOutput = nearfieldVirtualOutputIsDefaultOutput()
                try audioManager.cleanupPublicAggregates()
                if routerDriverManager.isInstalled {
                    markAggregateSchemaCurrent()
                    try configureRouterDriver(activate: shouldActivateVirtualOutput)
                }
            }
        } catch {
            showError(error)
        }
        refreshStatus()
    }

    private func configureRouterDriver(activate: Bool = true) throws {
        try removeAppOwnedTargetAggregateIfNeeded()

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
        guard !isSynchronizingAudioState else {
            refreshStatus()
            return
        }
        guard !isInstallingDriver else {
            refreshStatus()
            return
        }

        let state = audioManager.currentState()
        let hasSufficientDisplays = NearfieldActivationPolicy.shouldPublishRouter(
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
        let shouldActivateVirtualOutput = NearfieldActivationPolicy.shouldActivateRouter(
            defaultOutputIsNearfield: nearfieldVirtualOutputIsDefaultOutput(state: state),
            displaysJustReconnected: activateVirtualOutput,
            shouldReactivateAfterReconnect: shouldReactivateVirtualOutputAfterDisplayReconnect
        )
        shouldReactivateVirtualOutputAfterDisplayReconnect = false

        try performSynchronizedAudioUpdate {
            if routerDriverManager.isInstalled {
                try configureRouterDriver(activate: shouldActivateVirtualOutput)
            } else {
                try cleanupStaleNearfieldTargetsIfNeeded(state: state)
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

    private func removeAppOwnedTargetAggregateIfNeeded(state: NearfieldState? = nil) throws {
        let currentState = state ?? audioManager.currentState()
        let schemaNeedsCleanup = UserDefaults.standard.integer(forKey: DefaultsKey.aggregateSchemaVersion) < DefaultsKey.latestAggregateSchemaVersion
        guard currentState.aggregateDeviceID != nil || schemaNeedsCleanup else {
            return
        }
        try audioManager.cleanupAllNearfieldAggregates()
        markAggregateSchemaCurrent()
    }

    private func cleanupStaleNearfieldTargetsIfNeeded(state: NearfieldState? = nil) throws {
        let currentState = state ?? audioManager.currentState()
        let schemaNeedsCleanup = UserDefaults.standard.integer(forKey: DefaultsKey.aggregateSchemaVersion) < DefaultsKey.latestAggregateSchemaVersion
        guard currentState.aggregateDeviceID != nil ||
                schemaNeedsCleanup ||
                audioManager.hasManagedNearfieldAggregates() else {
            return
        }
        try audioManager.cleanupAllNearfieldAggregates()
        markAggregateSchemaCurrent()
    }

    private func nearfieldVirtualOutputIsDefaultOutput(state: NearfieldState? = nil) -> Bool {
        let currentState = state ?? audioManager.currentState()
        return currentState.isAggregateDefaultOutput ||
            Self.virtualOutputUIDs.contains { uid in
                audioManager.isDefaultOutputDevice(uid: uid)
            }
    }

    private func nearfieldVirtualOutputIsAnyDefault(state: NearfieldState? = nil) -> Bool {
        let currentState = state ?? audioManager.currentState()
        return nearfieldVirtualOutputIsDefaultOutput(state: currentState) ||
            Self.virtualOutputUIDs.contains { uid in
                audioManager.isDefaultSystemOutputDevice(uid: uid)
            }
    }

    private func loadProxyPreparedDisplayState() -> [DisplayOutputState]? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.proxyPreparedDisplayState) else {
            return nil
        }
        return try? JSONDecoder().decode([DisplayOutputState].self, from: data)
    }

    private func saveProxyPreparedDisplayState(_ state: [DisplayOutputState]?) {
        guard let state else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.proxyPreparedDisplayState)
            return
        }
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.proxyPreparedDisplayState)
        }
    }

    private func setMode(_ mode: NearfieldOutputMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: DefaultsKey.outputMode)
    }

    private func rebuildForConfigurationChange() {
        do {
            try performSynchronizedAudioUpdate {
                try restoreDisplaysAfterProxyDeactivation()
                if routerDriverManager.isInstalled {
                    try configureRouterDriver()
                } else {
                    try cleanupStaleNearfieldTargetsIfNeeded()
                    try audioManager.setDisplayBalance(currentBalance(), leftDeviceUID: currentConfiguration().leftDeviceUID)
                }
            }
        } catch {
            showError(error)
        }
        refreshStatus()
    }

    private func markAggregateSchemaCurrent() {
        UserDefaults.standard.set(DefaultsKey.latestAggregateSchemaVersion, forKey: DefaultsKey.aggregateSchemaVersion)
    }

    private func currentConfiguration() -> NearfieldConfiguration {
        NearfieldConfiguration(
            mode: currentMode(),
            leftDeviceUID: UserDefaults.standard.string(forKey: DefaultsKey.leftDeviceUID)
        )
    }

    private func currentMode() -> NearfieldOutputMode {
        guard let rawValue = UserDefaults.standard.string(forKey: DefaultsKey.outputMode),
              let mode = NearfieldOutputMode(rawValue: rawValue) else {
            return .stereo
        }
        return mode
    }

    private func currentBalance() -> Float32 {
        Float32(UserDefaults.standard.float(forKey: DefaultsKey.balance))
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
            audioManager.currentState().detectedDisplays.count >= 2 &&
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

    private func statusRowContent() -> (title: String, detail: String, symbolName: String, tintColor: NSColor) {
        #if !NEARFIELD_DISTRIBUTION
        if let simulatedStatus = currentSimulatedStatus(), simulatedStatus != .off {
            return statusContent(for: simulatedStatus)
        }
        #endif

        if isInstallingDriver {
            return ("Installing", "Configuring the Nearfield audio driver.", "arrow.triangle.2.circlepath.circle.fill", .systemBlue)
        }

        let state = audioManager.currentState()
        if state.detectedDisplays.count < 2 {
            return ("Displays Missing", "Connect two Studio Displays to create Nearfield.", "exclamationmark.triangle.fill", .systemYellow)
        }
        if let lastRuntimeError {
            return ("Needs Attention", lastRuntimeError, "exclamationmark.triangle.fill", .systemOrange)
        }
        guard routerDriverManager.isInstalled else {
            return ("Driver Not Installed", "Install the audio driver to enable Nearfield.", "xmark.circle.fill", .systemRed)
        }
        if routerDriverManager.isRouterDefaultOutput() {
            if appRoutingEnabled() {
                return ("App Audio Routing Active", "Nearfield is selected with App Audio Routing enabled.", "point.3.connected.trianglepath.dotted", .systemGreen)
            }
            return ("Nearfield Ready", "Audio driver active. macOS volume controls are enabled.", "checkmark.circle.fill", .systemGreen)
        }
        return ("Not Selected", "Select Nearfield or reinstall the audio driver.", "exclamationmark.circle.fill", .systemYellow)
    }

    private func currentSimulatedStatus() -> SimulatedStatus? {
        guard let rawValue = UserDefaults.standard.string(forKey: DefaultsKey.simulatedStatus) else {
            return nil
        }
        return SimulatedStatus(rawValue: rawValue)
    }

    private func setSimulatedStatus(_ status: SimulatedStatus) {
        if status == .off {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.simulatedStatus)
        } else {
            UserDefaults.standard.set(status.rawValue, forKey: DefaultsKey.simulatedStatus)
        }
        refreshStatus()
        rebuildMenu()
    }

    private func statusContent(for status: SimulatedStatus) -> (title: String, detail: String, symbolName: String, tintColor: NSColor) {
        switch status {
        case .off:
            return statusRowContent()
        case .ready:
            return ("Nearfield Ready", "Simulated: audio driver active with volume controls enabled.", status.symbolName, .systemGreen)
        case .missingDisplays:
            return ("Displays Missing", "Simulated: connect two Studio Displays to create Nearfield.", status.symbolName, .systemYellow)
        case .driverMissing:
            return ("Driver Not Installed", "Simulated: reinstall drivers to restore volume control.", status.symbolName, .systemRed)
        case .installing:
            return ("Installing", "Simulated: configuring the Nearfield audio driver.", status.symbolName, .systemBlue)
        case .notSelected:
            return ("Not Selected", "Simulated: select Nearfield or reinstall the audio driver.", status.symbolName, .systemYellow)
        }
    }

    private func isAdvancedExpanded() -> Bool {
        UserDefaults.standard.bool(forKey: DefaultsKey.advancedExpanded)
    }

    private func toggleAdvanced() {
        UserDefaults.standard.set(!isAdvancedExpanded(), forKey: DefaultsKey.advancedExpanded)
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        guard NearfieldActivationPolicy.shouldShowFullMenuBarMenu(
            isInitialOnboardingInProgress: isInitialOnboardingInProgress
        ) else {
            addQuitMenuItem()
            return
        }

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

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

    private func viewMenuItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func advancedPanelView() -> NSView {
        let selectedSimulation = currentSimulatedStatus() ?? .off
        return MenuAdvancedPanelView(
            actions: [
                .init(
                    title: "Swap Assignment",
                    symbolName: "arrow.left.arrow.right",
                    isEnabled: audioManager.studioDisplayDevices().count >= 2 && !isInstallingDriver,
                    handler: { [weak self] in
                        self?.menu.cancelTracking()
                        self?.swapAssignmentFromMenu()
                    }
                ),
                .init(
                    title: routerDriverManager.isInstalled ? "Reinstall Driver" : "Install Driver",
                    symbolName: "point.3.connected.trianglepath.dotted",
                    isEnabled: !isInstallingDriver,
                    handler: { [weak self] in
                        self?.menu.cancelTracking()
                        self?.settingsInstallDriver()
                    }
                ),
                .init(
                    title: "Uninstall",
                    symbolName: "trash",
                    isEnabled: !isInstallingDriver,
                    handler: { [weak self] in
                        self?.menu.cancelTracking()
                        self?.removeEverythingFromMenu()
                    }
                )
            ],
            simulatedStateOptions: SimulatedStatus.allCases.map { status in
                .init(
                    title: status.title,
                    symbolName: status.symbolName,
                    isSelected: selectedSimulation == status,
                    handler: { [weak self] in
                        self?.setSimulatedStatus(status)
                    }
                )
            }
        )
    }

    private func applyMenuBarState() {
        statusItem.isVisible = showMenuBarApp()
        statusItem.button?.isEnabled = true
        statusItem.menu = menu
        rebuildMenu()
    }

    private func showMenuBarApp() -> Bool {
        guard UserDefaults.standard.object(forKey: DefaultsKey.showMenuBarApp) != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: DefaultsKey.showMenuBarApp)
    }

    @objc private func swapAssignmentFromMenu() {
        let devices = Array(audioManager.studioDisplayDevices().prefix(2))
        guard devices.count >= 2 else { return }
        let currentLeftUID = UserDefaults.standard.string(forKey: DefaultsKey.leftDeviceUID) ?? devices[0].uid
        let nextLeftUID = devices.first(where: { $0.uid != currentLeftUID })?.uid ?? devices[1].uid
        UserDefaults.standard.set(nextLeftUID, forKey: DefaultsKey.leftDeviceUID)
        rebuildForConfigurationChange()
    }

    @objc private func removeEverythingFromMenu() {
        settingsRemoveEverything()
    }

    private func installAndActivateRouterDriver(
        disableAppRoutingOnCancelOrFailure: Bool = false,
        requiresConfirmation: Bool = true,
        presentsErrors: Bool = true,
        allowsMissingStudioDisplays: Bool = false
    ) {
        guard !isInstallingDriver else { return }
        let studioDisplayCount = audioManager.currentState().detectedDisplays.count
        guard NearfieldActivationPolicy.shouldAttemptDriverInstall(
            studioDisplayCount: studioDisplayCount,
            allowsMissingStudioDisplays: allowsMissingStudioDisplays
        ) else {
            finishDriverInstallAttempt(disableAppRouting: disableAppRoutingOnCancelOrFailure)
            handleDriverInstallError(
                NearfieldError.notEnoughStudioDisplays(studioDisplayCount),
                presentsErrors: presentsErrors
            )
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let isReinstall = routerDriverManager.isInstalled
        if requiresConfirmation {
            guard confirmPrivilegedInstall(
                title: isReinstall ? "Reinstall Nearfield Driver?" : "Install Nearfield Driver?",
                message: "Nearfield will install NearfieldAudioDevice.driver into /Library/Audio/Plug-Ins/HAL. macOS should ask for an administrator password before installing it."
            ) else {
                finishDriverInstallAttempt(disableAppRouting: disableAppRoutingOnCancelOrFailure)
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
                guard await RouterAudioDriverManager.waitUntilInstalled() else {
                    throw RouterAudioDriverError.notInstalled
                }
                try await self.configureRouterDriverAfterInstall(
                    allowsMissingStudioDisplays: allowsMissingStudioDisplays
                )
            } catch {
                self.finishDriverInstallAttempt(disableAppRouting: disableAppRoutingOnCancelOrFailure)
                self.handleDriverInstallError(error, presentsErrors: presentsErrors)
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
            UserDefaults.standard.set(false, forKey: DefaultsKey.appRoutingEnabled)
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
        guard NearfieldActivationPolicy.shouldConfigureRouterAfterDriverInstall(studioDisplayCount: studioDisplayCount) else {
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

    private func waitForSufficientStudioDisplaysAfterCoreAudioRestart(
        timeout: TimeInterval = 10,
        interval: TimeInterval = 0.25
    ) async -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        audioManager.invalidateCachedDevices()
        var latestCount = audioManager.currentState().detectedDisplays.count
        while latestCount < 2, Date() < deadline {
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

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}

extension AppDelegate: SettingsDelegate {
    func settingsDevices() -> [AudioDevice] {
        audioManager.studioDisplayDevices()
    }

    func settingsMode() -> NearfieldOutputMode {
        currentMode()
    }

    func settingsLeftDeviceUID() -> String? {
        UserDefaults.standard.string(forKey: DefaultsKey.leftDeviceUID)
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
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.showMenuBarApp)
        applyMenuBarState()
        refreshStatus()
    }

    func settingsDidReachSettingsScreen() {
        guard isInitialOnboardingInProgress else { return }
        isInitialOnboardingInProgress = false
        applyMenuBarState()
    }

    func settingsDriverInstalled() -> Bool {
        routerDriverManager.isInstalled
    }

    func settingsIsInstallingDriver() -> Bool {
        isInstallingDriver
    }

    func settingsNearfieldDriverSelected() -> Bool {
        routerDriverManager.isRouterDefaultOutput()
    }

    func settingsAppRoutingEnabled() -> Bool {
        appRoutingEnabled()
    }

    func settingsSetAppRoutingEnabled(_ enabled: Bool) {
        if enabled {
            UserDefaults.standard.set(true, forKey: DefaultsKey.appRoutingEnabled)
            if routerDriverManager.isInstalled {
                do {
                    try performSynchronizedAudioUpdate {
                        try restoreDisplaysAfterProxyDeactivation()
                        try configureRouterDriver()
                    }
                } catch {
                    UserDefaults.standard.set(false, forKey: DefaultsKey.appRoutingEnabled)
                    showError(error)
                }
            } else {
                installAndActivateRouterDriver(disableAppRoutingOnCancelOrFailure: true)
            }
        } else {
            UserDefaults.standard.set(false, forKey: DefaultsKey.appRoutingEnabled)
            deactivateRouterDriver()
        }
        updateDynamicRoutingRulesLifecycle()
        refreshStatus()
    }

    func settingsAppRoutingAppBundleIDs() -> [String]? {
        guard UserDefaults.standard.object(forKey: DefaultsKey.appRoutingAppBundleIDs) != nil else {
            return nil
        }
        return UserDefaults.standard.stringArray(forKey: DefaultsKey.appRoutingAppBundleIDs) ?? []
    }

    func settingsSetAppRoutingAppBundleIDs(_ bundleIDs: [String]) {
        UserDefaults.standard.set(bundleIDs, forKey: DefaultsKey.appRoutingAppBundleIDs)
        refreshStatus()
    }

    func settingsSpatialRoutingChannel(
        for bundleIdentifier: String,
        routingBundleIdentifiers: [String]
    ) -> SpatialRoutingChannel? {
        guard appRoutingEnabled(), routerDriverManager.isInstalled else {
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
        UserDefaults.standard.set(rules, forKey: DefaultsKey.appRoutingRules)
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
        if let lastRuntimeError {
            return lastRuntimeError
        }
        if routerDriverManager.isRouterDefaultOutput() {
            return appRoutingEnabled()
                ? "Current output: Nearfield - App Audio Routing enabled"
                : "Current output: Nearfield"
        }
        if routerDriverManager.isInstalled {
            return "Current output: router driver installed but not selected"
        }
        if audioManager.currentState().isAggregateDefaultOutput {
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
        UserDefaults.standard.float(forKey: DefaultsKey.balance)
    }

    func settingsSetBalance(_ balance: Float) {
        let clamped = min(max(balance, -1), 1)
        UserDefaults.standard.set(clamped, forKey: DefaultsKey.balance)
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
        UserDefaults.standard.set(uid, forKey: DefaultsKey.leftDeviceUID)
        refreshStatus()
    }

    func settingsApplyConfiguration() {
        rebuildForConfigurationChange()
    }

    func settingsInstallDriver(
        requiresConfirmation: Bool,
        presentsErrors: Bool,
        allowsMissingStudioDisplays: Bool
    ) {
        guard !isInstallingDriver else { return }
        installAndActivateRouterDriver(
            requiresConfirmation: requiresConfirmation,
            presentsErrors: presentsErrors,
            allowsMissingStudioDisplays: allowsMissingStudioDisplays
        )
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
        let shouldRestorePhysicalDefault = nearfieldVirtualOutputIsAnyDefault()
        do {
            try performSynchronizedAudioUpdate {
                try restoreDisplaysAfterProxyDeactivation()
                if shouldRestorePhysicalDefault {
                    _ = try audioManager.selectFallbackOutputAsDefault()
                }
            }
            try await Task.detached(priority: .userInitiated) {
                try DriverInstaller().removeAllInstalledDriversAndRestartCoreAudio()
            }.value
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
