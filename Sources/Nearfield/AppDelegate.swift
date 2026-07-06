import AppKit
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
        static let appRoutingRules = "appRoutingRules"
        static let appRoutingAppBundleIDs = "appRoutingAppBundleIDs"
        static let latestAggregateSchemaVersion = 12
    }

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
    private lazy var settingsWindowController = SettingsWindowController(delegate: self)
    private var onboardingWindowController: OnboardingWindowController?
    private var waveLabWindowController: WaveLabWindowController?
    private lazy var mediaKeyVolumeController = MediaKeyVolumeController(audioManager: audioManager)
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
    private var lastAppliedRouterRouteRules: String?
    private var hadSufficientStudioDisplays = false
    private var lastRuntimeError: String?

    override init() {
        super.init()
    }

    private var isSynchronizingAudioState: Bool {
        audioStateSynchronizationDepth > 0
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        proxyPreparedDisplayState = loadProxyPreparedDisplayState()
        hadSufficientStudioDisplays = audioManager.currentState().detectedDisplays.count >= 2
        configureMenu()
        if moveToApplicationsIfNeeded() {
            return
        }
        finishLaunching()
    }

    private func finishLaunching() {
        preparePairOnLaunch()
        mediaKeyVolumeController.start()
        refreshStatus()
        audioManager.startObserving { [weak self] in
            Task { @MainActor in self?.scheduleAudioStateChange() }
        }
        handleAudioStateChange()
        if BuildConfiguration.debugToolsEnabled && ProcessInfo.processInfo.arguments.contains("--wave-lab") {
            openWaveLab()
        } else if BuildConfiguration.debugToolsEnabled && ProcessInfo.processInfo.arguments.contains("--show-onboarding") {
            openOnboarding()
        } else {
            presentInitialOnboardingIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingAudioStateChangeTask?.cancel()
        dynamicRoutingRulesTask?.cancel()
        mediaKeyVolumeController.stop()
        audioManager.stopObserving()
    }

    private func configureMenu() {
        statusItem.button?.image = menuBarIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""
        menu.delegate = self
        statusItem.menu = menu
        applyMenuBarVisibility()
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

    private func presentInitialOnboardingIfNeeded() {
        guard !routerDriverManager.isInstalled else { return }
        openOnboarding()
    }

    private func refreshStatus() {
        settingsWindowController.reload()
        onboardingWindowController?.reload()
    }

    private func preparePairOnLaunch() {
        let state = audioManager.currentState()
        let shouldActivateVirtualOutput = routerDriverManager.isRouterDefaultOutput() ||
            state.isAggregateDefaultOutput
        guard state.detectedDisplays.count >= 2 else {
            return
        }

        do {
            try performSynchronizedAudioUpdate {
                if routerDriverManager.isInstalled {
                    try configureRouterDriver(activate: shouldActivateVirtualOutput)
                } else if state.aggregateDeviceID == nil ||
                    UserDefaults.standard.integer(forKey: DefaultsKey.aggregateSchemaVersion) < DefaultsKey.latestAggregateSchemaVersion {
                    try audioManager.rebuildAggregate(configuration: currentConfiguration())
                    markAggregateSchemaCurrent()
                }
            }
        } catch {
            recordRecoverableError(error, context: "Launch audio setup failed")
        }
    }

    @objc private func cleanupAggregates() {
        do {
            try performSynchronizedAudioUpdate {
                let shouldActivateVirtualOutput = routerDriverManager.isRouterDefaultOutput() ||
                    audioManager.currentState().isAggregateDefaultOutput
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
        if routerDriverManager.supportsDriverOwnedTargetAggregate() {
            try removeAppOwnedTargetAggregateIfNeeded()
        } else if audioManager.currentState().aggregateDeviceID == nil {
            try audioManager.rebuildAggregate(configuration: currentConfiguration())
            markAggregateSchemaCurrent()
        }

        let routeRules = effectiveRoutingRules()
        let targetDeviceUIDs = try audioManager.orderedStudioDisplayUIDs(configuration: currentConfiguration())
        try routerDriverManager.configureRouterOutput(
            targetDeviceUIDs: targetDeviceUIDs,
            mode: currentMode(),
            fallbackTargetOutputUID: audioManager.aggregateUID,
            displayName: "Nearfield",
            routingEnabled: appRoutingEnabled(),
            routeRules: routeRules
        )
        lastAppliedRouterRouteRules = routeRules
        try routerDriverManager.setBalance(currentBalance())
        if activate {
            try prepareDisplaysForVirtualOutputActivation()
            try routerDriverManager.selectRouterAsDefaultOutput()
        } else {
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

        let state = audioManager.currentState()
        let hasSufficientDisplays = state.detectedDisplays.count >= 2
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
        let shouldActivateVirtualOutput = activateVirtualOutput ||
            routerDriverManager.isRouterDefaultOutput() ||
            state.isAggregateDefaultOutput

        try performSynchronizedAudioUpdate {
            if routerDriverManager.isInstalled {
                try configureRouterDriver(activate: shouldActivateVirtualOutput)
            } else if activateVirtualOutput ||
                state.aggregateDeviceID == nil ||
                UserDefaults.standard.integer(forKey: DefaultsKey.aggregateSchemaVersion) < DefaultsKey.latestAggregateSchemaVersion {
                try audioManager.rebuildAggregate(configuration: currentConfiguration())
                markAggregateSchemaCurrent()
            } else if !shouldActivateVirtualOutput {
                try restoreDisplaysAfterProxyDeactivation()
            }
        }
    }

    private func handleStudioDisplaysUnavailable(state: NearfieldState) throws {
        dynamicRoutingRulesTask?.cancel()
        dynamicRoutingRulesTask = nil
        lastAppliedRouterRouteRules = nil

        let shouldMoveToFallback = routerDriverManager.isRouterDefaultOutput() ||
            state.isAggregateDefaultOutput
        if shouldMoveToFallback {
            try audioManager.selectFallbackOutputAsDefault()
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

    private func prepareDisplaysForVirtualOutputActivation() throws {
        if proxyPreparedDisplayState == nil {
            let displayState = try audioManager.captureDisplayOutputState()
            proxyPreparedDisplayState = displayState
            saveProxyPreparedDisplayState(displayState)
        }
        try audioManager.prepareDisplaysForProxyOutput()
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
                    try audioManager.rebuildAggregate(configuration: currentConfiguration())
                    markAggregateSchemaCurrent()
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
        guard let storedRules = UserDefaults.standard.string(forKey: DefaultsKey.appRoutingRules) else {
            return WindowAudioRouteResolver.defaultRoutingRules
        }
        return storedRules
    }

    private func effectiveRoutingRules() -> String {
        windowRouteResolver.resolvedRules(from: currentRoutingRules())
    }

    private func applyCurrentRouterRouteRulesIfNeeded(force: Bool = false) throws {
        guard appRoutingEnabled(), routerDriverManager.isInstalled else { return }
        let resolvedRules = effectiveRoutingRules()
        guard force || resolvedRules != lastAppliedRouterRouteRules else { return }
        if force {
            try routerDriverManager.setRoutingEnabled(true)
        }
        try routerDriverManager.setRouteRules(resolvedRules)
        lastAppliedRouterRouteRules = resolvedRules
    }

    private func updateDynamicRoutingRulesLifecycle() {
        let shouldRun = appRoutingEnabled() &&
            routerDriverManager.isInstalled &&
            audioManager.currentState().detectedDisplays.count >= 2 &&
            windowRouteResolver.hasWindowScopedRoute(in: currentRoutingRules())
        if shouldRun {
            startDynamicRoutingRulesTask()
        } else {
            dynamicRoutingRulesTask?.cancel()
            dynamicRoutingRulesTask = nil
        }
    }

    private func startDynamicRoutingRulesTask() {
        guard dynamicRoutingRulesTask == nil else { return }
        dynamicRoutingRulesTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try self?.applyCurrentRouterRouteRulesIfNeeded()
                } catch {
                    self?.recordRecoverableError(error, context: "App routing refresh failed")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    @objc private func openSettings() {
        showOnboardingSettingsStage(showsPageIndicator: false)
    }

    @objc private func openOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(delegate: self)
        }
        onboardingWindowController?.showOnboardingSimulation()
    }

    @objc private func openOnboardingSettingsStage() {
        showOnboardingSettingsStage(showsPageIndicator: true)
    }

    private func showOnboardingSettingsStage(showsPageIndicator: Bool) {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(delegate: self)
        }
        onboardingWindowController?.showSettingsStage(showsPageIndicator: showsPageIndicator)
    }

    @objc private func openWaveLab() {
        if waveLabWindowController == nil {
            waveLabWindowController = WaveLabWindowController()
        }
        waveLabWindowController?.show()
    }

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
        if let simulatedStatus = currentSimulatedStatus(), simulatedStatus != .off {
            return statusContent(for: simulatedStatus)
        }

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
                return ("App Routing Active", "Router driver is selected with routing rules enabled.", "point.3.connected.trianglepath.dotted", .systemGreen)
            }
            return ("Nearfield Ready", "Audio driver active. macOS volume controls are enabled.", "checkmark.circle.fill", .systemGreen)
        }
        return ("Not Selected", "Select Nearfield or reinstall the audio driver.", "exclamationmark.circle.fill", .systemYellow)
    }

    private func currentSimulatedStatus() -> SimulatedStatus? {
        guard BuildConfiguration.debugToolsEnabled else {
            return nil
        }
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

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if BuildConfiguration.debugToolsEnabled {
            menu.addItem(.separator())

            let onboardingItem = NSMenuItem(title: "Onboarding", action: #selector(openOnboarding), keyEquivalent: "")
            onboardingItem.target = self
            menu.addItem(onboardingItem)

            let setupItem = NSMenuItem(title: "Setup", action: #selector(openOnboardingSettingsStage), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)

            let waveLabItem = NSMenuItem(title: "Wave Lab", action: #selector(openWaveLab), keyEquivalent: "")
            waveLabItem.target = self
            menu.addItem(waveLabItem)
        }

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

    private func applyMenuBarVisibility() {
        statusItem.isVisible = showMenuBarApp()
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

    private func installAndActivateRouterDriver(disableAppRoutingOnCancelOrFailure: Bool = false) {
        guard !isInstallingDriver else { return }
        NSApp.activate(ignoringOtherApps: true)
        let isReinstall = routerDriverManager.isInstalled
        guard confirmPrivilegedInstall(
            title: isReinstall ? "Reinstall Nearfield Driver?" : "Install Nearfield Driver?",
            message: "Nearfield will install NearfieldAudioDevice.driver into /Library/Audio/Plug-Ins/HAL. macOS should ask for an administrator password before installing it."
        ) else {
            if disableAppRoutingOnCancelOrFailure {
                UserDefaults.standard.set(false, forKey: DefaultsKey.appRoutingEnabled)
            }
            updateDynamicRoutingRulesLifecycle()
            refreshStatus()
            return
        }
        isInstallingDriver = true
        refreshStatus()

        Task { [weak self] in
            guard let self else { return }
            do {
                let driverPath = try await Task.detached(priority: .userInitiated) {
                    try DriverInstaller().buildRouterDriver()
                }.value
                try DriverInstaller().installBuiltRouterDriver(at: driverPath)
                guard await self.routerDriverManager.waitUntilInstalled() else {
                    throw RouterAudioDriverError.notInstalled
                }
                try self.performSynchronizedAudioUpdate {
                    try self.restoreDisplaysAfterProxyDeactivation()
                    try self.configureRouterDriver()
                }
            } catch {
                if disableAppRoutingOnCancelOrFailure {
                    UserDefaults.standard.set(false, forKey: DefaultsKey.appRoutingEnabled)
                }
                self.showError(error)
            }
            self.isInstallingDriver = false
            self.updateDynamicRoutingRulesLifecycle()
            self.refreshStatus()
        }
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

extension AppDelegate: SettingsWindowControllerDelegate {
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
        applyMenuBarVisibility()
        refreshStatus()
    }

    func settingsDriverInstalled() -> Bool {
        routerDriverManager.isInstalled
    }

    func settingsIsInstallingDriver() -> Bool {
        isInstallingDriver
    }

    func settingsAppRoutingEnabled() -> Bool {
        appRoutingEnabled()
    }

    func settingsSetAppRoutingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.appRoutingEnabled)
        if enabled {
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
                ? "Current output: Nearfield - app routing enabled"
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
                    try prepareDisplaysForVirtualOutputActivation()
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

    func settingsInstallDriver() {
        guard !isInstallingDriver else { return }
        installAndActivateRouterDriver()
        refreshStatus()
    }

    func settingsRemoveEverything() {
        dynamicRoutingRulesTask?.cancel()
        dynamicRoutingRulesTask = nil
        lastAppliedRouterRouteRules = nil
        NearfieldPreferences.clearAppRoutingEnabled()
        do {
            try performSynchronizedAudioUpdate {
                try restoreDisplaysAfterProxyDeactivation()
                if routerDriverManager.isRouterDefaultOutput() ||
                    audioManager.isDefaultOutputDevice(uid: "ProxyAudioDevice_UID") ||
                    audioManager.isDefaultSystemOutputDevice(uid: "ProxyAudioDevice_UID") ||
                    audioManager.isDefaultOutputDevice(uid: "StudioPairRouterAudioDevice_UID") ||
                    audioManager.isDefaultSystemOutputDevice(uid: "StudioPairRouterAudioDevice_UID") ||
                    audioManager.isDefaultOutputDevice(uid: RouterAudioDriverManager.routerDeviceUID) ||
                    audioManager.isDefaultSystemOutputDevice(uid: RouterAudioDriverManager.routerDeviceUID) ||
                    audioManager.currentState().isAggregateDefaultOutput {
                    try audioManager.selectFallbackOutputAsDefault()
                }
                try audioManager.cleanupAllNearfieldAggregates()
                try DriverInstaller().removeDriverAndRestartCoreAudio()
                try DriverInstaller().removeRouterDriverAndRestartCoreAudio()
                proxyPreparedDisplayState = nil
                saveProxyPreparedDisplayState(nil)
            }
            clearRecoverableError()
        } catch {
            showError(error)
        }
        refreshStatus()
    }

    func settingsPlayTestTone(_ channel: TestToneChannel) {
        do {
            try testTonePlayer.play(channel: channel)
        } catch {
            showError(error)
        }
    }
}
