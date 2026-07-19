import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum OnboardingLayout {
    static let scale: CGFloat = 1
    static let baseSize = NSSize(width: 307, height: 536)
    static let contentWidth = baseSize.width - 32
    static let ditherImageWidth = baseSize.width + 36.5
    static let expandedHeaderHeight: CGFloat = 345
    static let windowSize = NSSize(width: baseSize.width * scale, height: baseSize.height * scale)
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private final class ShortcutWindow: NSWindow {
        var shortcutHandler: ((NSEvent) -> Bool)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if shortcutHandler?(event) == true {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if shortcutHandler?(event) == true {
                return
            }
            super.keyDown(with: event)
        }
    }

    private enum Metrics {
        static let size = OnboardingLayout.windowSize
    }

    private let model: OnboardingModel
    private weak var hostingView: NSView?

    init(delegate: SettingsDelegate) {
        let model = OnboardingModel(delegate: delegate)
        self.model = model

        let contentRect = NSRect(origin: .zero, size: Metrics.size)
        let window = ShortcutWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        let fixedFrameSize = window.frameRect(forContentRect: contentRect).size
        window.minSize = fixedFrameSize
        window.maxSize = fixedFrameSize
        window.center()

        super.init(window: window)

        window.delegate = self
        if BuildConfiguration.debugToolsEnabled {
            window.shortcutHandler = { [weak self] event in
                self?.handleStepShortcut(event) ?? false
            }
        }

        let hostingView = NSHostingView(rootView: OnboardingRootView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: Metrics.size)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        self.hostingView = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        model.cancelInstallSimulation()
        // Stop the header animation so the helper doesn't keep rendering frames
        // for a window that's no longer on screen.
        model.headerPaused = true
        model.setWindowVisible(false)
        super.close()
    }

    func show(playsIntro: Bool = false) {
        reload()
        model.headerPaused = false
        model.setWindowVisible(true)
        let shouldFadeWindow = playsIntro || window?.isVisible != true
        if shouldFadeWindow {
            window?.alphaValue = 0
        } else {
            window?.alphaValue = 1
        }
        if playsIntro {
            model.beginIntroAnimation()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if playsIntro {
            animateWindowIntoFocus()
        } else if shouldFadeWindow {
            animateWindowFadeIn(duration: 0.18)
        }
        updateWindowLevel()
        updateWindowAppearance()
    }

    private func animateWindowFadeIn(duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.animator().alphaValue = 1
        }
    }

    private func animateWindowIntoFocus() {
        guard let window else { return }

        let finalFrame = window.frame
        let initialFrame = finalFrame.insetBy(dx: 4, dy: 4)
        window.setFrame(initialFrame, display: false)

        let blurFilter = CIFilter(name: "CIGaussianBlur")
        blurFilter?.name = "introWindowBlur"
        blurFilter?.setValue(14, forKey: kCIInputRadiusKey)

        if let hostingView {
            hostingView.wantsLayer = true
            hostingView.layer?.masksToBounds = true
            hostingView.layer?.filters = blurFilter.map { [$0] }
            let blurAnimation = CABasicAnimation(keyPath: "filters.introWindowBlur.inputRadius")
            blurAnimation.fromValue = 14
            blurAnimation.toValue = 0
            blurAnimation.duration = 0.72
            blurAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hostingView.layer?.add(blurAnimation, forKey: "introWindowBlur")
            blurFilter?.setValue(0, forKey: kCIInputRadiusKey)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.78) { [weak hostingView] in
                hostingView?.layer?.filters = nil
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.72
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        }
    }

    func showOnboardingSimulation() {
        model.showOnboardingSimulation()
        show(playsIntro: true)
    }

    func showSettingsStage(showsPageIndicator: Bool = true) {
        model.showSettingsStage(showsPageIndicator: showsPageIndicator)
        show()
    }

    func reload() {
        let wasInstallingDriver = model.isInstallingDriver
        model.refreshFromDelegate()
        updateWindowLevel()
        if model.isInstallingDriver, !wasInstallingDriver {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Pause the header animation whenever the window isn't actually on screen
    // (covered, minimized, on another Space, or closed) so it doesn't burn CPU.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        let isVisible = window.occlusionState.contains(.visible)
        model.headerPaused = !isVisible
        model.setWindowVisible(isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        model.headerPaused = true
        model.setWindowVisible(false)
    }

    private func handleStepShortcut(_ event: NSEvent) -> Bool {
        guard BuildConfiguration.debugToolsEnabled else { return false }
        let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard disallowedModifiers.isEmpty else {
            return false
        }
        let slowMotion = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 18:
            model.showStep(.welcome, slowMotion: slowMotion)
        case 19:
            model.showStep(.install, slowMotion: slowMotion)
        case 20:
            model.showStep(.settings, slowMotion: slowMotion)
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  characters.count == 1 else {
                return false
            }
            switch characters {
            case "h":
                model.toggleHeaderGraphic()
            case "l":
                model.toggleDebugColorSchemeOverride()
                updateWindowAppearance()
            case "a":
                guard model.step == .install else { return false }
                model.runInstallScenario(.smooth)
            case "s":
                guard model.step == .install else { return false }
                model.runInstallScenario(.permissionFailure)
            default:
                return false
            }
        }
        return true
    }

    private func updateWindowAppearance() {
        guard let override = model.debugColorSchemeOverride else {
            window?.appearance = nil
            return
        }
        window?.appearance = NSAppearance(named: override == .light ? .aqua : .darkAqua)
    }

    private func updateWindowLevel() {
        window?.level = model.isInstallingDriver ? .floating : .normal
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case install
    case settings
}

private enum OnboardingInstallStep: Int, CaseIterable {
    case environment
    case approveDriver
    case routingDriver
    case appRouting

    var activeTitle: String {
        switch self {
        case .environment: "Check Environment"
        case .approveDriver: "Approve Driver Install"
        case .routingDriver: "Install Routing Driver"
        case .appRouting: "Activate App Audio Routing"
        }
    }

    var completedTitle: String {
        switch self {
        case .environment: "Environment Check Passed"
        case .approveDriver: "Driver Install Approved"
        case .routingDriver: "Routing Driver Installed"
        case .appRouting: "App Audio Routing Activated"
        }
    }

    var activeDetail: String {
        switch self {
        case .environment:
            "Nearfield checks system permissions"
        case .approveDriver:
            "Nearfield requires admin privileges to install HAL\nDrivers"
        case .routingDriver:
            "Preparing the virtual output driver"
        case .appRouting:
            "Enabling App Audio Routing controls"
        }
    }
}

private struct OnboardingInstallError {
    let step: OnboardingInstallStep
    let title: String
    let message: String
}

private enum OnboardingInstallScenario {
    case smooth
    case permissionFailure
}

private enum OnboardingInstallStepState {
    case completed
    case active
    case failed(OnboardingInstallError)
    case pending
}

private struct SpatialRoutingApp: Identifiable, Equatable {
    var id: String { bundleIdentifier }
    var title: String
    var bundleIdentifier: String
    var routingBundleIdentifiers: [String]
    var icon: NSImage
    var isEnabled: Bool
    var activeChannel: SpatialRoutingChannel?
    var url: URL?
}

@MainActor
private final class OnboardingModel: ObservableObject {
    private enum Metrics {
        static let dummyInstallStepDurationNanoseconds: UInt64 = 2_500_000_000
        static let liveEnvironmentStepDelayNanoseconds: UInt64 = 1_000_000_000
        static let defaultStepTransitionDuration: Double = 0.34
        static let slowStepTransitionDuration: Double = 2.4
    }

    weak var delegate: SettingsDelegate?

    @Published var step: OnboardingStep = .welcome
    @Published var isInstallHovered = false
    @Published var headerPaused = false
    @Published var showsPageIndicator = true
    @Published var installProgressIndex = 0
    @Published var installError: OnboardingInstallError?
    @Published var openAtLogin = false
    @Published var showMenubarApp = true
    @Published var balance: Double = 0
    @Published var driverInstalled = false
    @Published var isInstallingDriver = false
    @Published var nearfieldDriverSelected = false
    @Published var appVersionText = "Version 0.1.0"
    @Published var studioDisplayCount = 0
    @Published var spatialRoutingEnabled = true
    @Published var spatialRoutingApps: [SpatialRoutingApp] = []
    @Published var selectedSpatialRoutingAppID: String?
    @Published var settingsScrollResetToken = 0
    @Published var showHeaderGraphic = true
    @Published var stepTransitionDuration = Metrics.defaultStepTransitionDuration
    @Published var debugColorSchemeOverride: ColorScheme?
    @Published var introAnimationToken = 0

    private var dummyInstallTask: Task<Void, Never>?
    private var pendingLiveInstallStartTask: Task<Void, Never>?
    private var liveInstallTask: Task<Void, Never>?
    private var liveInstallRequestedAt: Date?
    private var spatialRoutingActivityTask: Task<Void, Never>?
    private var isWindowVisible = false
    private var installScenario: OnboardingInstallScenario = .smooth
    private var allowsMissingStudioDisplaysForLiveInstall = false

    init(delegate: SettingsDelegate) {
        self.delegate = delegate
        refreshFromDelegate()
    }

    deinit {
        dummyInstallTask?.cancel()
        pendingLiveInstallStartTask?.cancel()
        liveInstallTask?.cancel()
        spatialRoutingActivityTask?.cancel()
    }

    func refreshFromDelegate() {
        guard let delegate else { return }
        openAtLogin = delegate.settingsOpenAtLogin()
        showMenubarApp = delegate.settingsShowMenuBarApp()
        balance = Double(delegate.settingsBalance())
        let installingDriver = delegate.settingsIsInstallingDriver()
        isInstallingDriver = installingDriver
        if !installingDriver {
            driverInstalled = delegate.settingsDriverInstalled()
            nearfieldDriverSelected = delegate.settingsNearfieldDriverSelected()
            studioDisplayCount = delegate.settingsDevices().count
        }
        appVersionText = delegate.settingsAppVersionText()
        spatialRoutingEnabled = delegate.settingsAppRoutingEnabled()
        syncSpatialRoutingApps(
            bundleIDs: delegate.settingsAppRoutingAppBundleIDs(),
            rawRules: delegate.settingsRoutingRules()
        )
        reconcileSpatialRoutingAliasesIfNeeded(rawRules: delegate.settingsRoutingRules())
        updateSpatialRoutingActivityRefresh()
        if shouldRefreshSpatialRoutingActivity {
            refreshSpatialRoutingActivity(animated: false)
        }
    }

    func showOnboardingSimulation() {
        cancelInstallSimulation()
        showsPageIndicator = true
        installError = nil
        installProgressIndex = 0
        showStep(.welcome, animated: false)
    }

    func beginIntroAnimation() {
        introAnimationToken += 1
    }

    func showSettingsStage(showsPageIndicator: Bool = true) {
        cancelInstallSimulation()
        self.showsPageIndicator = showsPageIndicator
        installError = nil
        installProgressIndex = OnboardingInstallStep.allCases.count
        showStep(.settings, animated: false)
    }

    func showStep(_ nextStep: OnboardingStep, animated: Bool = true, slowMotion: Bool = false) {
        if nextStep != .install {
            cancelInstallTasks()
        }
        stepTransitionDuration = slowMotion
            ? Metrics.slowStepTransitionDuration
            : Metrics.defaultStepTransitionDuration
        if nextStep == .settings && step != .settings {
            settingsScrollResetToken += 1
        }
        let change = {
            self.step = nextStep
            if nextStep == .settings {
                self.delegate?.settingsDidReachSettingsScreen()
            }
        }
        if animated {
            withAnimation(.smooth(duration: stepTransitionDuration)) {
                change()
            }
        } else {
            change()
        }
        updateSpatialRoutingActivityRefresh()
    }

    func toggleHeaderGraphic() {
        guard BuildConfiguration.debugToolsEnabled else { return }
        withAnimation(.smooth(duration: 0.22)) {
            showHeaderGraphic.toggle()
        }
    }

    func toggleDebugColorSchemeOverride() {
        guard BuildConfiguration.debugToolsEnabled else { return }
        withAnimation(.smooth(duration: 0.22)) {
            debugColorSchemeOverride = debugColorSchemeOverride == .light ? .dark : .light
        }
    }

    func setWindowVisible(_ isVisible: Bool) {
        isWindowVisible = isVisible
        updateSpatialRoutingActivityRefresh()
    }

    func startInstallFlow() {
        cancelInstallTasks()
        allowsMissingStudioDisplaysForLiveInstall = false
        installError = nil
        installProgressIndex = driverInstalled ? OnboardingInstallStep.appRouting.rawValue : 0
        showStep(.install)
        startLiveInstallAfterStepTransition()
    }

    func runInstallScenario(_ scenario: OnboardingInstallScenario) {
        guard BuildConfiguration.debugToolsEnabled else { return }
        installScenario = scenario
        cancelInstallSimulation()
        installError = nil
        installProgressIndex = 0
        showStep(.install)
        startDummyInstallSequence()
    }

    func retryCurrentInstallStep(allowsMissingStudioDisplays: Bool) {
        guard let installError else { return }
        if installError.step == .approveDriver {
            requestDriverInstallApproval()
            return
        }
        if installError.step == .environment {
            recheckLiveInstallEnvironment(
                allowsMissingStudioDisplays: allowsMissingStudioDisplays
            )
            return
        }
        if installError.step == .routingDriver, driverInstalled {
            retryLiveRouterConfiguration()
            return
        }
        cancelInstallSimulation()
        self.installError = nil
        installProgressIndex = installError.step.rawValue
        startDummyInstallSequence()
    }

    private func recheckLiveInstallEnvironment(allowsMissingStudioDisplays: Bool) {
        cancelInstallTasks()
        allowsMissingStudioDisplaysForLiveInstall = allowsMissingStudioDisplays
        installError = nil
        installProgressIndex = OnboardingInstallStep.environment.rawValue

        pendingLiveInstallStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let isCoreAudioReady = await self.delegate?.settingsRefreshAudioState() ?? false
            guard !Task.isCancelled else { return }
            self.pendingLiveInstallStartTask = nil
            self.refreshFromDelegate()
            guard isCoreAudioReady else {
                self.failLiveInstall(with: self.coreAudioUnavailableError(step: .environment))
                return
            }
            guard allowsMissingStudioDisplays || self.liveInstallCanCompleteConfiguration() else {
                self.failLiveInstall(with: self.studioDisplayRequirementError(step: .environment))
                return
            }

            withAnimation(.smooth(duration: 0.24)) {
                self.installProgressIndex = OnboardingInstallStep.approveDriver.rawValue
            }
        }
    }

    private func retryLiveRouterConfiguration() {
        cancelInstallTasks()
        installError = nil
        installProgressIndex = OnboardingInstallStep.routingDriver.rawValue

        pendingLiveInstallStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let isCoreAudioReady = await self.delegate?.settingsRefreshAudioState() ?? false
            guard !Task.isCancelled else { return }
            self.pendingLiveInstallStartTask = nil
            self.refreshFromDelegate()
            guard isCoreAudioReady else {
                self.failLiveInstall(with: self.coreAudioUnavailableError(step: .routingDriver))
                return
            }
            guard self.liveInstallCanCompleteConfiguration() else {
                self.failLiveInstall(with: self.studioDisplayRequirementError(step: .routingDriver))
                return
            }

            self.liveInstallRequestedAt = Date()
            self.delegate?.settingsApplyConfiguration()
            self.startLiveInstallSequence()
        }
    }

    func cancelInstallSimulation() {
        cancelInstallTasks()
    }

    private func cancelInstallTasks() {
        dummyInstallTask?.cancel()
        dummyInstallTask = nil
        pendingLiveInstallStartTask?.cancel()
        pendingLiveInstallStartTask = nil
        liveInstallTask?.cancel()
        liveInstallTask = nil
        liveInstallRequestedAt = nil
    }

    func installStepState(for step: OnboardingInstallStep) -> OnboardingInstallStepState {
        if let installError {
            if installError.step == step {
                return .failed(installError)
            }
            return step.rawValue < installError.step.rawValue ? .completed : .pending
        }
        if step.rawValue < installProgressIndex {
            return .completed
        }
        if step.rawValue == installProgressIndex && installProgressIndex < OnboardingInstallStep.allCases.count {
            return .active
        }
        return .pending
    }

    func pendingInstallStepOpacity(for step: OnboardingInstallStep) -> Double {
        let anchorStepIndex = installError?.step.rawValue ?? installProgressIndex
        let distance = max(1, step.rawValue - anchorStepIndex)
        return max(0.4, 1.0 - Double(distance) * 0.2)
    }

    func setOpenAtLogin(_ enabled: Bool) {
        openAtLogin = enabled
        delegate?.settingsSetOpenAtLogin(enabled)
        refreshFromDelegate()
    }

    func setShowMenubarApp(_ enabled: Bool) {
        showMenubarApp = enabled
        delegate?.settingsSetShowMenuBarApp(enabled)
        refreshFromDelegate()
    }

    func setBalance(_ value: Double) {
        let clamped = min(max(value, -1), 1)
        balance = clamped
        delegate?.settingsSetBalance(Float(clamped))
    }

    func balanceText() -> String {
        if abs(balance) < 0.03 {
            return "Center"
        }
        return balance < 0 ? "\(Int(abs(balance) * 100))% L" : "\(Int(balance * 100))% R"
    }

    func playTestSound() {
        delegate?.settingsPlayTestTone(.stereo)
    }

    func installDriver() {
        delegate?.settingsInstallDriver()
        refreshFromDelegate()
    }

    func removeDrivers() {
        delegate?.settingsRemoveEverything()
        refreshFromDelegate()
    }

    func setSpatialRoutingEnabled(_ enabled: Bool) {
        withAnimation(.smooth(duration: 0.26)) {
            spatialRoutingEnabled = enabled
            if !enabled {
                selectedSpatialRoutingAppID = nil
            }
        }
        delegate?.settingsSetAppRoutingEnabled(enabled)
        if enabled {
            persistSpatialRoutingAppBundleIDs()
        }
        refreshFromDelegate()
        updateSpatialRoutingActivityRefresh()
    }

    func selectSpatialRoutingApp(_ id: String) {
        selectedSpatialRoutingAppID = id
    }

    func setSpatialRoutingApp(_ id: String, enabled: Bool) {
        guard let index = spatialRoutingApps.firstIndex(where: { $0.id == id }) else { return }
        spatialRoutingApps[index].isEnabled = enabled
        let app = spatialRoutingApps[index]
        persistSpatialRoutingAppBundleIDs()
        persistSpatialRoutingApp(app)
    }

    func addSpatialRoutingApps() {
        let panel = NSOpenPanel()
        panel.title = "Add Application"
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }

        let existingPaths = Set(spatialRoutingApps.compactMap { $0.url?.standardizedFileURL.path })
        let newApps = panel.urls
            .filter { !existingPaths.contains($0.standardizedFileURL.path) }
            .compactMap { url -> SpatialRoutingApp? in
                guard let bundleIdentifier = Bundle(url: url)?.bundleIdentifier,
                      !spatialRoutingApps.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                    return nil
                }
                return SpatialRoutingApp(
                    title: Self.appTitle(url: url),
                    bundleIdentifier: bundleIdentifier,
                    routingBundleIdentifiers: Self.routingBundleIdentifiers(
                        for: url,
                        primaryBundleIdentifier: bundleIdentifier
                    ),
                    icon: Self.appIcon(url: url),
                    isEnabled: true,
                    activeChannel: nil,
                    url: url
                )
            }
        guard !newApps.isEmpty else { return }

        withAnimation(.smooth(duration: 0.26)) {
            spatialRoutingApps.append(contentsOf: newApps)
            selectedSpatialRoutingAppID = newApps.last?.id
        }
        persistSpatialRoutingAppBundleIDs()
        for app in newApps {
            persistSpatialRoutingApp(app)
        }
    }

    func removeSelectedSpatialRoutingApp() {
        guard !spatialRoutingApps.isEmpty else { return }
        let removeIndex = selectedSpatialRoutingAppID.flatMap { selectedID in
            spatialRoutingApps.firstIndex { $0.id == selectedID }
        } ?? spatialRoutingApps.indices.last
        guard let removeIndex else { return }

        let removedApp = spatialRoutingApps[removeIndex]
        withAnimation(.smooth(duration: 0.22)) {
            spatialRoutingApps.remove(at: removeIndex)
            if spatialRoutingApps.indices.contains(removeIndex) {
                selectedSpatialRoutingAppID = spatialRoutingApps[removeIndex].id
            } else {
                selectedSpatialRoutingAppID = spatialRoutingApps.last?.id
            }
        }
        persistSpatialRoutingAppBundleIDs()
        persistSpatialRoutingApp(removedApp, enabled: false)
    }

    var driverStatusTitle: String {
        if isInstallingDriver {
            return "Installing"
        }
        return driverInstalled ? "Installed" : "Missing"
    }

    var driverStatusSymbolName: String {
        if isInstallingDriver {
            return "arrow.triangle.2.circlepath"
        }
        return driverInstalled ? "checkmark.seal.fill" : "xmark.circle.fill"
    }

    var driverStatusColor: Color {
        if isInstallingDriver {
            return .blue
        }
        return driverInstalled ? .green : .yellow
    }

    var driverActionTitle: String {
        if isInstallingDriver {
            return "Installing"
        }
        return driverInstalled ? "Reinstall" : "Install"
    }

    private func startDummyInstallSequence() {
        dummyInstallTask = Task { @MainActor [weak self] in
            while let self,
                  !Task.isCancelled,
                  self.step == .install,
                  self.installError == nil,
                  self.installProgressIndex < OnboardingInstallStep.allCases.count {
                try? await Task.sleep(nanoseconds: Metrics.dummyInstallStepDurationNanoseconds)
                guard !Task.isCancelled, self.step == .install, self.installError == nil else { return }
                withAnimation(.smooth(duration: 0.24)) {
                    self.installProgressIndex += 1
                }
                if self.shouldFailInstallScenario(afterCompleting: self.installProgressIndex) {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled, self.step == .install, self.installError == nil else { return }
                    withAnimation(.smooth(duration: 0.24)) {
                        self.installError = self.error(for: self.installScenario)
                    }
                    self.dummyInstallTask = nil
                    return
                }
                if self.installProgressIndex == OnboardingInstallStep.allCases.count {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard !Task.isCancelled, self.step == .install, self.installError == nil else { return }
                    self.dummyInstallTask = nil
                    self.showStep(.settings)
                    return
                }
            }
        }
    }

    private func runLiveInstallFlow() {
        installError = nil
        installProgressIndex = driverInstalled ? OnboardingInstallStep.appRouting.rawValue : 0

        if driverInstalled {
            if nearfieldDriverSelected {
                installProgressIndex = OnboardingInstallStep.allCases.count
                showStep(.settings)
            } else {
                installProgressIndex = OnboardingInstallStep.routingDriver.rawValue
                delegate?.settingsApplyConfiguration()
                startLiveInstallSequence()
            }
            return
        }

        guard allowsMissingStudioDisplaysForLiveInstall || liveInstallCanCompleteConfiguration() else {
            failLiveInstall(with: studioDisplayRequirementError(step: .environment))
            return
        }

        withAnimation(.smooth(duration: 0.24)) {
            installProgressIndex = OnboardingInstallStep.approveDriver.rawValue
        }
    }

    private func startLiveInstallAfterStepTransition() {
        let transitionNanoseconds = UInt64(max(0, stepTransitionDuration) * 1_000_000_000)
        pendingLiveInstallStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: transitionNanoseconds)
            guard !Task.isCancelled, self.step == .install else { return }
            try? await Task.sleep(nanoseconds: Metrics.liveEnvironmentStepDelayNanoseconds)
            guard !Task.isCancelled, self.step == .install else { return }
            let isCoreAudioReady = await self.delegate?.settingsRefreshAudioState() ?? false
            guard !Task.isCancelled, self.step == .install else { return }
            self.pendingLiveInstallStartTask = nil
            self.refreshFromDelegate()
            guard isCoreAudioReady else {
                self.failLiveInstall(with: self.coreAudioUnavailableError(step: .environment))
                return
            }
            self.runLiveInstallFlow()
        }
    }

    func requestDriverInstallApproval() {
        guard step == .install else { return }
        refreshFromDelegate()
        guard !isInstallingDriver, liveInstallTask == nil else { return }

        installError = nil
        guard allowsMissingStudioDisplaysForLiveInstall || liveInstallCanCompleteConfiguration() else {
            failLiveInstall(with: studioDisplayRequirementError(step: .environment))
            return
        }

        withAnimation(.smooth(duration: 0.24)) {
            installProgressIndex = OnboardingInstallStep.approveDriver.rawValue
        }
        liveInstallRequestedAt = Date()
        delegate?.settingsInstallDriver(
            requiresConfirmation: false,
            presentsErrors: false,
            allowsMissingStudioDisplays: allowsMissingStudioDisplaysForLiveInstall
        )
        startLiveInstallSequence()
    }

    private func startLiveInstallSequence() {
        liveInstallTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = self.liveInstallRequestedAt ?? Date()
            self.installProgressIndex = max(self.installProgressIndex, OnboardingInstallStep.approveDriver.rawValue)

            while !Task.isCancelled, self.step == .install {
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }

                self.refreshFromDelegate()

                if self.isInstallingDriver {
                    withAnimation(.smooth(duration: 0.24)) {
                        self.installProgressIndex = max(self.installProgressIndex, OnboardingInstallStep.routingDriver.rawValue)
                    }
                    continue
                }

                if NearfieldActivationPolicy.shouldCompleteOnboardingAfterDriverInstall(
                    driverInstalled: self.driverInstalled,
                    routerSelected: self.nearfieldDriverSelected,
                    studioDisplayCount: self.studioDisplayCount,
                    allowsMissingStudioDisplays: self.allowsMissingStudioDisplaysForLiveInstall
                ) {
                    withAnimation(.smooth(duration: 0.24)) {
                        self.installProgressIndex = OnboardingInstallStep.allCases.count
                    }
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard !Task.isCancelled else { return }
                    self.liveInstallTask = nil
                    self.liveInstallRequestedAt = nil
                    self.showStep(.settings)
                    return
                }

                if self.driverInstalled {
                    if !self.liveInstallCanCompleteConfiguration() {
                        self.failLiveInstall(
                            with: self.studioDisplayRequirementError(step: .routingDriver)
                        )
                        return
                    }
                    self.failLiveInstall(
                        with: OnboardingInstallError(
                            step: .routingDriver,
                            title: "Could Not Select Nearfield",
                            message: "Nearfield was installed, but macOS did not switch to the Nearfield output."
                        )
                    )
                    return
                }

                if Date().timeIntervalSince(startedAt) > 1.2 {
                    self.failLiveInstall(
                        with: OnboardingInstallError(
                            step: .approveDriver,
                            title: "Permissions Not Granted",
                            message: "Admin permissions needed to install HAL Driver"
                        )
                    )
                    return
                }
            }
        }
    }

    private func liveInstallCanCompleteConfiguration() -> Bool {
        NearfieldActivationPolicy.shouldConfigureRouterAfterDriverInstall(
            studioDisplayCount: studioDisplayCount
        )
    }

    private func studioDisplayRequirementError(step: OnboardingInstallStep) -> OnboardingInstallError {
        return OnboardingInstallError(
            step: step,
            title: "Studio Displays Required",
            message: NearfieldError.notEnoughStudioDisplays(studioDisplayCount).localizedDescription
        )
    }

    private func coreAudioUnavailableError(step: OnboardingInstallStep) -> OnboardingInstallError {
        OnboardingInstallError(
            step: step,
            title: "Core Audio Is Not Responding",
            message: "Quit and reopen Nearfield after Core Audio has restarted, then try again."
        )
    }

    private func failLiveInstall(with error: OnboardingInstallError) {
        withAnimation(.smooth(duration: 0.24)) {
            installProgressIndex = error.step.rawValue
            installError = error
        }
        liveInstallTask = nil
        liveInstallRequestedAt = nil
    }

    private func startSpatialRoutingActivityRefresh() {
        guard spatialRoutingActivityTask == nil else { return }
        spatialRoutingActivityTask?.cancel()
        spatialRoutingActivityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self {
                    self.refreshSpatialRoutingActivity()
                } else {
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopSpatialRoutingActivityRefresh() {
        spatialRoutingActivityTask?.cancel()
        spatialRoutingActivityTask = nil
    }

    private func updateSpatialRoutingActivityRefresh() {
        guard shouldRefreshSpatialRoutingActivity else {
            stopSpatialRoutingActivityRefresh()
            clearSpatialRoutingActivity()
            return
        }
        startSpatialRoutingActivityRefresh()
    }

    private var shouldRefreshSpatialRoutingActivity: Bool {
        isWindowVisible &&
            step == .settings &&
            spatialRoutingEnabled &&
            !spatialRoutingApps.isEmpty
    }

    private func clearSpatialRoutingActivity() {
        guard spatialRoutingApps.contains(where: { $0.activeChannel != nil }) else { return }
        var nextApps = spatialRoutingApps
        for index in nextApps.indices {
            nextApps[index].activeChannel = nil
        }
        spatialRoutingApps = nextApps
    }

    private func refreshSpatialRoutingActivity(animated: Bool = true) {
        guard let delegate else { return }

        var nextApps = spatialRoutingApps
        var changed = false
        for index in nextApps.indices {
            let app = nextApps[index]
            let nextChannel = spatialRoutingEnabled && app.isEnabled
                ? delegate.settingsSpatialRoutingChannel(
                    for: app.bundleIdentifier,
                    routingBundleIdentifiers: app.routingBundleIdentifiers
                )
                : nil

            if nextApps[index].activeChannel != nextChannel {
                nextApps[index].activeChannel = nextChannel
                changed = true
            }
        }

        guard changed else { return }
        let update = {
            self.spatialRoutingApps = nextApps
        }
        if animated {
            withAnimation(.smooth(duration: 0.18)) {
                update()
            }
        } else {
            update()
        }
    }

    private func shouldFailInstallScenario(afterCompleting completedStepCount: Int) -> Bool {
        switch installScenario {
        case .smooth:
            return false
        case .permissionFailure:
            return completedStepCount == OnboardingInstallStep.approveDriver.rawValue
        }
    }

    private func error(for scenario: OnboardingInstallScenario) -> OnboardingInstallError {
        switch scenario {
        case .smooth:
            OnboardingInstallError(
                step: .approveDriver,
                title: "Install Interrupted",
                message: "The driver install could not be completed."
            )
        case .permissionFailure:
            OnboardingInstallError(
                step: .approveDriver,
                title: "Permission Required",
                message: "Admin approval was denied. Retry to approve the driver install."
            )
        }
    }

    private func syncSpatialRoutingApps(bundleIDs storedBundleIDs: [String]?, rawRules: String) {
        let rules = AppRoutingRules.parse(rawRules)
        let routedBundleIDs = Set(rules.map(\.bundleID))
        let storedIDs = storedBundleIDs ?? []
        let orderedIDs = storedBundleIDs == nil
            ? rules.map(\.bundleID)
            : storedIDs + rules.map(\.bundleID).filter { !storedIDs.contains($0) }
        var appsByID: [String: SpatialRoutingApp] = [:]
        for app in spatialRoutingApps {
            appsByID[app.bundleIdentifier] = app
        }

        for bundleID in orderedIDs where appsByID[bundleID] == nil {
            appsByID[bundleID] = Self.spatialRoutingApp(bundleIdentifier: bundleID)
        }
        let knownAliasBundleIDs = Set(appsByID.values.flatMap { app in
            app.routingBundleIdentifiers.filter { $0 != app.bundleIdentifier }
        })

        let uniqueOrderedIDs = orderedIDs.reduce(into: [String]()) { result, id in
            if !result.contains(id), !knownAliasBundleIDs.contains(id), storedBundleIDs == nil || storedIDs.contains(id) {
                result.append(id)
            }
        }

        let nextApps = uniqueOrderedIDs.compactMap { id -> SpatialRoutingApp? in
            guard var app = appsByID[id] else { return nil }
            if !routedBundleIDs.isEmpty || storedBundleIDs != nil {
                app.isEnabled = !routedBundleIDs.isDisjoint(with: Set(app.routingBundleIdentifiers))
            }
            return app
        }

        if spatialRoutingApps != nextApps {
            spatialRoutingApps = nextApps
        }
        if let selectedSpatialRoutingAppID,
           !spatialRoutingApps.contains(where: { $0.id == selectedSpatialRoutingAppID }) {
            self.selectedSpatialRoutingAppID = spatialRoutingApps.last?.id
        }
    }

    private func reconcileSpatialRoutingAliasesIfNeeded(rawRules: String) {
        guard let delegate else { return }
        let parsedRules = AppRoutingRules.parse(rawRules)
        var nextRules = rawRules

        for app in spatialRoutingApps where app.isEnabled {
            guard parsedRules.contains(where: {
                $0.bundleID == app.bundleIdentifier &&
                    AppRoutingRules.isWindowScopedDestination($0.destination)
            }) else {
                continue
            }
            nextRules = AppRoutingRules.settingApp(
                primaryBundleID: app.bundleIdentifier,
                aliasBundleIDs: app.routingBundleIdentifiers.filter { $0 != app.bundleIdentifier },
                enabled: true,
                in: nextRules
            )
        }

        if nextRules != rawRules {
            delegate.settingsSetRoutingRules(nextRules)
        }
    }

    private func persistSpatialRoutingAppBundleIDs() {
        delegate?.settingsSetAppRoutingAppBundleIDs(spatialRoutingApps.map(\.bundleIdentifier))
    }

    private func persistSpatialRoutingApp(_ app: SpatialRoutingApp, enabled: Bool? = nil) {
        guard let delegate else { return }
        let nextRules = AppRoutingRules.settingApp(
            primaryBundleID: app.bundleIdentifier,
            aliasBundleIDs: app.routingBundleIdentifiers.filter { $0 != app.bundleIdentifier },
            enabled: enabled ?? app.isEnabled,
            in: delegate.settingsRoutingRules()
        )
        delegate.settingsSetRoutingRules(nextRules)
        refreshFromDelegate()
    }

    private static func spatialRoutingApp(bundleIdentifier: String) -> SpatialRoutingApp {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        return SpatialRoutingApp(
            title: url.map { appTitle(url: $0) } ?? bundleIdentifier,
            bundleIdentifier: bundleIdentifier,
            routingBundleIdentifiers: url.map {
                routingBundleIdentifiers(for: $0, primaryBundleIdentifier: bundleIdentifier)
            } ?? ([bundleIdentifier] + AppRoutingAliases.aliasBundleIDs(for: bundleIdentifier)).uniquePreservingOrder(),
            icon: url.map { appIcon(url: $0) } ?? fallbackAppIcon(),
            isEnabled: true,
            activeChannel: nil,
            url: url
        )
    }

    private static func appTitle(url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func appIcon(url: URL) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 24, height: 24)
        return image
    }

    private static func routingBundleIdentifiers(
        for appURL: URL,
        primaryBundleIdentifier: String
    ) -> [String] {
        let bundleExtensions = Set(["app", "xpc"])
        var bundleIdentifiers = [primaryBundleIdentifier]
        let searchRoots = [
            appURL.appendingPathComponent("Contents/Frameworks"),
            appURL.appendingPathComponent("Contents/Helpers"),
            appURL.appendingPathComponent("Contents/XPCServices"),
            appURL.appendingPathComponent("Contents/PlugIns"),
            appURL.appendingPathComponent("Contents/Library/LoginItems")
        ]

        for root in searchRoots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard bundleExtensions.contains(url.pathExtension.lowercased()) else { continue }
                if let bundleIdentifier = Bundle(url: url)?.bundleIdentifier {
                    bundleIdentifiers.append(bundleIdentifier)
                }
                enumerator.skipDescendants()
            }
        }

        bundleIdentifiers.append(contentsOf: AppRoutingAliases.aliasBundleIDs(for: primaryBundleIdentifier))
        return bundleIdentifiers.uniquePreservingOrder()
    }

    private static func fallbackAppIcon() -> NSImage {
        let image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        image.size = NSSize(width: 24, height: 24)
        return image
    }
}

private struct OnboardingRootView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                OnboardingGraphicHeader(
                    height: headerHeight,
                    activePageIndex: model.step.rawValue,
                    showsGraphic: model.showHeaderGraphic,
                    transitionDuration: model.stepTransitionDuration,
                    showsPageIndicator: model.showsPageIndicator,
                    normalConfiguration: model.step == .settings ? .settings : .onboarding,
                    hoverActive: model.isInstallHovered && model.step == .welcome,
                    paused: model.headerPaused
                )

                if let subheadlineText {
                    HeaderSubheadline(text: subheadlineText, fontSize: subheadlineFontSize)
                        .padding(.top, 16)
                        .padding(.leading, 16)
                        .frame(width: OnboardingLayout.baseSize.width, alignment: .leading)
                        .hidden()
                }

                ZStack(alignment: .topLeading) {
                    switch model.step {
                    case .welcome:
                        WelcomeOnboardingView(model: model)
                            .transition(contentTransition)
                    case .install:
                        InstallOnboardingView(model: model)
                            .transition(contentTransition)
                    case .settings:
                        SettingsOnboardingView(model: model)
                            .transition(contentTransition)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }

            HeaderCopyOverlay(
                copy: headerCopy,
                transitionDuration: model.stepTransitionDuration,
                introAnimationToken: model.introAnimationToken
            )
            .allowsHitTesting(false)
        }
        .frame(width: OnboardingLayout.baseSize.width, height: OnboardingLayout.baseSize.height, alignment: .top)
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .ignoresSafeArea()
        .animation(.smooth(duration: model.stepTransitionDuration), value: model.step)
        .animation(.smooth(duration: 0.22), value: model.showHeaderGraphic)
        .preferredColorScheme(model.debugColorSchemeOverride)
        .scaleEffect(OnboardingLayout.scale, anchor: .topLeading)
        .frame(
            width: OnboardingLayout.windowSize.width,
            height: OnboardingLayout.windowSize.height,
            alignment: .topLeading
        )
    }

    private var headerTitle: String {
        switch model.step {
        case .welcome:
            "Nearfield"
        case .install:
            "Installing Drivers"
        case .settings:
            "Settings"
        }
    }

    private var headerHeight: CGFloat {
        switch model.step {
        case .welcome:
            OnboardingLayout.expandedHeaderHeight
        case .install, .settings:
            120
        }
    }

    private var headerTitleSize: CGFloat {
        switch model.step {
        case .welcome:
            35.235
        case .install, .settings:
            24
        }
    }

    private var headerTitleTop: CGFloat {
        let titleHeight: CGFloat = headerTitleSize < 30 ? 29 : 42
        return headerHeight - 16 - titleHeight
    }

    private var subheadlineText: String? {
        switch model.step {
        case .welcome:
            "Transform your studio displays into\nstereo audio monitors"
        case .install:
            "Nearfield works as a virtual HAL Driver,\nproviding the best native experience"
        case .settings:
            nil
        }
    }

    private var subheadlineFontSize: CGFloat {
        switch model.step {
        case .welcome:
            16
        case .install:
            12
        case .settings:
            12
        }
    }

    private var subheadlineTop: CGFloat {
        headerHeight + 16
    }

    private var headerCopy: HeaderCopyContent {
        HeaderCopyContent(
            title: headerTitle,
            titleSize: headerTitleSize,
            titleTop: headerTitleTop,
            subheadlineText: subheadlineText,
            subheadlineFontSize: subheadlineFontSize,
            subheadlineTop: subheadlineTop
        )
    }

    private var contentTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .bottom)),
            removal: .opacity
        )
    }
}

private struct HeaderCopyContent: Equatable {
    var title: String
    var titleSize: CGFloat
    var titleTop: CGFloat
    var subheadlineText: String?
    var subheadlineFontSize: CGFloat
    var subheadlineTop: CGFloat

    var titleHeight: CGFloat {
        titleSize < 30 ? 29 : 42
    }

    func replacingMetrics(with other: HeaderCopyContent) -> HeaderCopyContent {
        HeaderCopyContent(
            title: title,
            titleSize: other.titleSize,
            titleTop: other.titleTop,
            subheadlineText: subheadlineText,
            subheadlineFontSize: other.subheadlineFontSize,
            subheadlineTop: other.subheadlineTop
        )
    }
}

private struct HeaderCopyOverlay: View {
    let copy: HeaderCopyContent
    let transitionDuration: Double
    let introAnimationToken: Int

    @State private var displayedCopy: HeaderCopyContent?
    @State private var outgoingCopy: HeaderCopyContent?
    @State private var incomingOpacity = 1.0
    @State private var outgoingOpacity = 0.0
    @State private var cleanupWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let outgoingCopy {
                HeaderCopyLayer(
                    copy: outgoingCopy,
                    introAnimationToken: introAnimationToken,
                    playsIntro: false
                )
                    .opacity(outgoingOpacity)
            }

            HeaderCopyLayer(
                copy: displayedCopy ?? copy,
                introAnimationToken: introAnimationToken,
                playsIntro: (displayedCopy ?? copy).title == "Nearfield"
            )
                .opacity(incomingOpacity)
        }
        .frame(width: OnboardingLayout.baseSize.width, height: OnboardingLayout.baseSize.height, alignment: .topLeading)
        .onAppear {
            displayedCopy = copy
            incomingOpacity = 1
            outgoingOpacity = 0
        }
        .onChange(of: copy) { _, newCopy in
            animate(to: newCopy)
        }
        .onDisappear {
            cleanupWorkItem?.cancel()
        }
    }

    private func animate(to newCopy: HeaderCopyContent) {
        let previousCopy = displayedCopy ?? copy
        let duration = max(0.28, transitionDuration)
        cleanupWorkItem?.cancel()

        outgoingCopy = previousCopy
        displayedCopy = newCopy.replacingMetrics(with: previousCopy)
        incomingOpacity = previousCopy == newCopy ? 1 : 0
        outgoingOpacity = previousCopy == newCopy ? 0 : 1

        DispatchQueue.main.async {
            withAnimation(.smooth(duration: duration)) {
                outgoingCopy = previousCopy.replacingMetrics(with: newCopy)
                displayedCopy = newCopy
            }
            withAnimation(.easeInOut(duration: max(0.12, duration * 0.54)).delay(duration * 0.14)) {
                incomingOpacity = 1
                outgoingOpacity = 0
            }
        }

        let cleanup = DispatchWorkItem {
            outgoingCopy = nil
            displayedCopy = newCopy
            incomingOpacity = 1
            outgoingOpacity = 0
        }
        cleanupWorkItem = cleanup
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.12, execute: cleanup)
    }
}

private struct HeaderCopyLayer: View {
    let copy: HeaderCopyContent
    let introAnimationToken: Int
    var playsIntro = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if copy.title == "Nearfield" {
                IntroReveal(token: introAnimationToken, delay: 0.08, yOffset: 8, isEnabled: playsIntro) {
                    NearfieldLogoMark()
                        .frame(width: 30.264, height: 27.711)
                }
                .offset(x: 18.868, y: 236.144)
            }

            if playsIntro && copy.title == "Nearfield" {
                AnimatedHeaderTitle(
                    text: copy.title,
                    fontSize: copy.titleSize,
                    height: copy.titleHeight,
                    token: introAnimationToken
                )
                .offset(x: 16, y: copy.titleTop)
            } else {
                Text(copy.title)
                    .font(.system(size: copy.titleSize, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(height: copy.titleHeight, alignment: .leading)
                    .offset(x: 16, y: copy.titleTop)
            }

            if let subheadlineText = copy.subheadlineText {
                IntroReveal(token: introAnimationToken, delay: 0.36, yOffset: 8, isEnabled: playsIntro) {
                    HeaderSubheadline(text: subheadlineText, fontSize: copy.subheadlineFontSize)
                        .frame(width: OnboardingLayout.baseSize.width - 32, alignment: .leading)
                }
                .offset(x: 16, y: copy.subheadlineTop)
            }
        }
        .frame(width: OnboardingLayout.baseSize.width, height: OnboardingLayout.baseSize.height, alignment: .topLeading)
    }
}

private struct AnimatedHeaderTitle: View {
    let text: String
    let fontSize: CGFloat
    let height: CGFloat
    let token: Int

    @State private var revealedLetterCount = 0

    private var characters: [String] {
        text.map(String.init)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                Text(character)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(.white)
                    .opacity(index < revealedLetterCount ? 1 : 0)
                    .blur(radius: index < revealedLetterCount ? 0 : 7)
                    .offset(y: index < revealedLetterCount ? 0 : 50)
            }
        }
        .frame(height: height, alignment: .leading)
        .accessibilityLabel(text)
        .onAppear(perform: runAnimation)
        .onChange(of: token) { _, _ in
            runAnimation()
        }
    }

    private func runAnimation() {
        revealedLetterCount = 0
        for index in characters.indices {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14 + Double(index) * 0.046) {
                withAnimation(.smooth(duration: 0.3)) {
                    revealedLetterCount = max(revealedLetterCount, index + 1)
                }
            }
        }
    }
}

private struct IntroReveal<Content: View>: View {
    let token: Int
    let delay: Double
    let duration: Double
    let yOffset: CGFloat
    let isEnabled: Bool
    let content: Content

    @State private var isVisible = false

    init(
        token: Int,
        delay: Double,
        duration: Double = 0.26,
        yOffset: CGFloat = 10,
        isEnabled: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.token = token
        self.delay = delay
        self.duration = duration
        self.yOffset = yOffset
        self.isEnabled = isEnabled
        self.content = content()
    }

    var body: some View {
        content
            .opacity(isEnabled ? (isVisible ? 1 : 0) : 1)
            .blur(radius: isEnabled ? (isVisible ? 0 : 7) : 0)
            .offset(y: isEnabled ? (isVisible ? 0 : yOffset) : 0)
            .onAppear(perform: runAnimation)
            .onChange(of: token) { _, _ in
                runAnimation()
            }
    }

    private func runAnimation() {
        guard isEnabled else {
            isVisible = true
            return
        }
        isVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.smooth(duration: duration)) {
                isVisible = true
            }
        }
    }
}

private struct HeaderSubheadline: View {
    let text: String
    let fontSize: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .regular))
            .foregroundStyle(Color.white.opacity(0.4))
            .lineSpacing(0)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.smooth(duration: 0.26), value: fontSize)
    }
}

private struct WelcomeOnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            IntroReveal(token: model.introAnimationToken, delay: 0.48, duration: 0.24, yOffset: 12) {
                Button("Install") {
                    model.startInstallFlow()
                }
                .buttonStyle(WelcomeInstallButtonStyle())
                .focusable(false)
                .onHover { model.isInstallHovered = $0 }
            }
            .padding(.leading, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WelcomeInstallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 70, height: 30)
            .background(
                Color(red: 0.1882352978, green: 0.1882352978, blue: 0.1882352978)
                    .opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct InstallOnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 4) {
                ForEach(OnboardingInstallStep.allCases, id: \.rawValue) { step in
                    InstallStepRow(
                        step: step,
                        state: model.installStepState(for: step),
                        pendingOpacity: model.pendingInstallStepOpacity(for: step),
                        requestAccess: model.requestDriverInstallApproval,
                        retry: model.retryCurrentInstallStep
                    )
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .animation(.smooth(duration: 0.24), value: model.installProgressIndex)
            .animation(.smooth(duration: 0.24), value: model.installError?.step.rawValue)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct InstallStepRow: View {
    let step: OnboardingInstallStep
    let state: OnboardingInstallStepState
    let pendingOpacity: Double
    let requestAccess: () -> Void
    let retry: (Bool) -> Void

    var body: some View {
        Group {
            switch state {
            case .completed:
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(nsColor: .systemGreen))
                        .frame(width: 16, height: 16)
                    Text(step.completedTitle)
                        .installTitleStyle(color: .secondary)
                    Spacer()
                }
                .frame(height: 35)
            case .active:
                HStack(alignment: .top, spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.activeTitle)
                            .installTitleStyle(color: .primary)
                        Text(step.activeDetail)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        if step == .approveDriver {
                            InstallPermissionButton(title: "Request Access", action: requestAccess)
                                .padding(.top, 7)
                        }
                    }
                    Spacer()
                }
                .padding(.top, 11)
                .frame(height: activeRowHeight, alignment: .top)
            case .failed(let error):
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .frame(width: 16, height: 16)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error.title)
                            .installTitleStyle(color: .primary)
                        Text(error.message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        if step == .approveDriver {
                            InstallPermissionButton(title: "Request Again", width: 123) {
                                retry(false)
                            }
                                .padding(.top, 7)
                        }
                    }
                    Spacer()
                    if step != .approveDriver {
                        Button {
                            retry(commandModifierIsPressed)
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help(retryHelpText)
                    }
                }
                .padding(.top, 10)
                .frame(height: step == .approveDriver ? 101 : 75, alignment: .top)
            case .pending:
                HStack {
                    Text(step.activeTitle)
                        .installTitleStyle(color: .primary)
                    Spacer()
                }
                .frame(height: 32)
                .opacity(pendingOpacity)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: OnboardingLayout.contentWidth, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var commandModifierIsPressed: Bool {
        NSApp.currentEvent?.modifierFlags.contains(.command) == true ||
            NSEvent.modifierFlags.contains(.command)
    }

    private var retryHelpText: String {
        if step == .environment {
            return "Recheck Studio Displays. Hold Command to continue without them."
        }
        return "Retry current step"
    }

    private var rowBackground: Color {
        switch state {
        case .active, .failed:
            Theme.activeRowBackground
        case .completed:
            Theme.completedRowBackground
        case .pending:
            Theme.pendingRowBackground.opacity(pendingOpacity)
        }
    }

    private var activeRowHeight: CGFloat {
        if step == .approveDriver {
            return 124
        }
        return step.activeDetail.contains("\n") ? 65 : 54
    }
}

private struct InstallPermissionButton: View {
    let title: String
    var width: CGFloat = 132
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(InstallPermissionButtonStyle(width: width))
            .focusable(false)
    }
}

private struct InstallPermissionButtonStyle: ButtonStyle {
    let width: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: width, height: 24)
            .background(
                Color(nsColor: .systemBlue)
                    .opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct SettingsOnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @State private var showsTopFade = false

    var body: some View {
        ZStack(alignment: .top) {
            ScrollViewReader { scrollProxy in
                    ScrollView {
                        ScrollOffsetObserver { offset in
                            updateTopFadeVisibility(offset)
                        }
                        .frame(width: 0, height: 0)

                        Color.clear
                            .frame(height: 0)
                            .id("settingsTop")

                        VStack(alignment: .leading, spacing: 8) {
                            StudioDisplayStatusPill(
                                status: StudioDisplayConnectionStatus(
                                    connectedCount: model.studioDisplayCount
                                )
                            )
                            .frame(width: OnboardingLayout.contentWidth)

                            SettingsGroup {
                                ToggleSettingRow(
                                    title: "Open at login",
                                    isOn: Binding(
                                        get: { model.openAtLogin },
                                        set: { model.setOpenAtLogin($0) }
                                    )
                                )
                                SettingsDivider()
                                ToggleSettingRow(
                                    title: "Show Menubar App",
                                    detail: "Open Nearfield to show this screen again.",
                                    isOn: Binding(
                                        get: { model.showMenubarApp },
                                        set: { model.setShowMenubarApp($0) }
                                    ),
                                    height: 64
                                )
                            }

                            SettingsSection(title: "Sound") {
                                SettingsGroup {
                                    BalanceSettingRow(model: model)
                                    SettingsDivider()
                                    ActionSettingRow(title: "Test Sound", buttonTitle: "Play") {
                                        model.playTestSound()
                                    }
                                    SettingsDivider()
                                    ActionSettingRow(title: "Arrangement", buttonTitle: "Swap Channels") {}
                                }
                            }

                            SpatialRoutingGroup(model: model)

                            SettingsSection(title: "Driver") {
                                SettingsGroup {
                                    DriverStatusRow(model: model)
                                    SettingsDivider()
                                    ActionSettingRow(
                                        title: "Uninstall Nearfield",
                                        buttonTitle: "Uninstall",
                                        destructive: true
                                    ) {
                                        model.removeDrivers()
                                    }
                                }
                            }

                            Text(model.appVersionText)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .frame(width: OnboardingLayout.contentWidth)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 20)
                    }
                    .coordinateSpace(name: "settingsScroll")
                    .onAppear {
                        scrollProxy.scrollTo("settingsTop", anchor: .top)
                    }
                    .onChange(of: model.settingsScrollResetToken) { _, _ in
                        scrollProxy.scrollTo("settingsTop", anchor: .top)
                    }
            }

            ProgressiveTopFade(isVisible: showsTopFade)
                .allowsHitTesting(false)
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
    }

    private func updateTopFadeVisibility(_ offset: CGFloat) {
        if offset > 12, !showsTopFade {
            showsTopFade = true
        } else if offset <= 1, showsTopFade {
            showsTopFade = false
        }
    }
}

private struct OnboardingGraphicHeader: View {
    let height: CGFloat
    let activePageIndex: Int
    let showsGraphic: Bool
    let transitionDuration: Double
    let showsPageIndicator: Bool
    let normalConfiguration: NearfieldHeaderAnimationConfiguration
    var hoverActive: Bool = false
    var paused: Bool = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsGraphic {
                // Keep the wave render surface fixed; step changes mask it by
                // shrinking the outer header frame below.
                InterpolatedHeaderAnimation(
                    progress: hoverActive ? 1 : 0,
                    normal: normalConfiguration,
                    hover: .onboardingHover,
                    paused: paused
                )
                .frame(
                    width: OnboardingLayout.ditherImageWidth,
                    height: OnboardingLayout.expandedHeaderHeight
                )
                .clipped()
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.35), value: hoverActive)
            }
        }
        .frame(width: OnboardingLayout.baseSize.width, height: height)
        .overlay(alignment: .topTrailing) {
            if showsPageIndicator {
                PageIndicator(activeIndex: activePageIndex, transitionDuration: transitionDuration)
                    .padding(.top, 16)
                    .padding(.trailing, 16)
            }
        }
        .clipped()
    }
}

private struct PageIndicator: View {
    let activeIndex: Int
    let transitionDuration: Double

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.primary.opacity(index == activeIndex ? 1 : 0.5))
                    .frame(width: index == activeIndex ? 12 : 4, height: 4)
                    .animation(.smooth(duration: max(0.18, transitionDuration * 0.65)), value: activeIndex)
            }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(height: 14)
                    .padding(.leading, 8)
                    .padding(.top, 8)
            } else {
                Color.clear.frame(height: 4)
            }
            content
        }
        .frame(width: OnboardingLayout.contentWidth, alignment: .leading)
    }
}

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(width: OnboardingLayout.contentWidth)
        .background(Theme.groupBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct NativeSettingsSwitch: NSViewRepresentable {
    @Binding var isOn: Bool
    var isEnabled = true

    func makeNSView(context: Context) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .mini
        control.target = context.coordinator
        control.action = #selector(Coordinator.valueChanged(_:))
        return control
    }

    func updateNSView(_ nsView: NSSwitch, context: Context) {
        let nextState: NSControl.StateValue = isOn ? .on : .off
        if nsView.state != nextState {
            nsView.state = nextState
        }
        nsView.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isOn: $isOn)
    }

    final class Coordinator: NSObject {
        private let isOn: Binding<Bool>

        init(isOn: Binding<Bool>) {
            self.isOn = isOn
        }

        @objc @MainActor func valueChanged(_ sender: NSSwitch) {
            isOn.wrappedValue = sender.state == .on
        }
    }
}

private struct CompactSettingsSwitch: View {
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        NativeSettingsSwitch(isOn: $isOn, isEnabled: isEnabled)
            .frame(width: 50, height: 30)
            .scaleEffect(0.72, anchor: .center)
            .frame(width: 36, height: 22)
    }
}

private struct ToggleSettingRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var height: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .settingsTitleStyle()
                Spacer(minLength: 8)
                CompactSettingsSwitch(isOn: $isOn)
            }

            if let detail {
                Text(detail)
                    .settingsDetailStyle()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, detail == nil ? 9 : 10)
        .frame(minHeight: height, alignment: .center)
    }
}

private struct ActionSettingRow: View {
    let title: String
    var detail: String?
    let buttonTitle: String
    var destructive = false
    var height: CGFloat = 42
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 12) {
                Text(title)
                    .settingsTitleStyle()
                Spacer(minLength: 8)
                Button(buttonTitle, action: action)
                    .controlSize(.small)
                    .foregroundStyle(destructive ? .red : .primary)
            }

            if let detail {
                Text(detail)
                    .settingsDetailStyle()
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, detail == nil ? 8 : 10)
        .frame(minHeight: detail == nil ? height : max(height, 58), alignment: .center)
    }
}

private struct BalanceSettingRow: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Balance")
                    .settingsTitleStyle()
                Spacer()
                Text(model.balanceText())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                Image(systemName: "l.circle.fill")
                    .balanceSideIconStyle()

                NativeBalanceSlider(
                    value: Binding(
                        get: { model.balance },
                        set: { model.setBalance($0) }
                    )
                )
                .frame(height: 30)

                Image(systemName: "r.circle.fill")
                    .balanceSideIconStyle()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 66)
    }
}

private struct SpatialRoutingGroup: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        SettingsSection {
            SettingsGroup {
                SpatialRoutingHeaderRow(
                    isOn: Binding(
                        get: { model.spatialRoutingEnabled },
                        set: { model.setSpatialRoutingEnabled($0) }
                    )
                )

                if model.spatialRoutingEnabled {
                    ForEach(model.spatialRoutingApps) { app in
                        SettingsDivider()
                        SpatialRoutingAppRow(
                            app: app,
                            isSelected: model.selectedSpatialRoutingAppID == app.id,
                            isOn: Binding(
                                get: { app.isEnabled },
                                set: { model.setSpatialRoutingApp(app.id, enabled: $0) }
                            ),
                            select: { model.selectSpatialRoutingApp(app.id) }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    SettingsDivider()
                    SpatialRoutingFooterRow(
                        canRemove: !model.spatialRoutingApps.isEmpty,
                        add: model.addSpatialRoutingApps,
                        remove: model.removeSelectedSpatialRoutingApp
                    )
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.26), value: model.spatialRoutingEnabled)
            .animation(.smooth(duration: 0.22), value: model.spatialRoutingApps.count)
        }
    }
}

private struct SpatialRoutingHeaderRow: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 12) {
                Text("App Audio Routing")
                    .settingsTitleStyle()
                Spacer(minLength: 8)
                CompactSettingsSwitch(isOn: $isOn)
            }

            Text("Route apps by window location.")
                .settingsDetailStyle()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 76, alignment: .center)
    }
}

private struct SpatialRoutingAppRow: View {
    let app: SpatialRoutingApp
    let isSelected: Bool
    @Binding var isOn: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 16) {
                    SpatialRoutingAppIcon(icon: app.icon, channel: app.activeChannel)

                    Text(app.title)
                        .settingsTitleStyle(color: isSelected ? .primary : .secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 50)

            CompactSettingsSwitch(isOn: $isOn)
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .frame(height: 50)
    }
}

private struct SpatialRoutingAppIcon: View {
    let icon: NSImage
    let channel: SpatialRoutingChannel?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)

            if let channel {
                SpatialRoutingChannelBadge(channel: channel)
                    .offset(x: 3, y: 3)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
            }
        }
        .frame(width: 32, height: 32)
        .animation(.smooth(duration: 0.18), value: channel)
    }
}

private struct SpatialRoutingChannelBadge: View {
    let channel: SpatialRoutingChannel

    var body: some View {
        Image(systemName: channel.symbolName)
            .font(.system(size: 10, weight: .semibold))
            .symbolRenderingMode(.palette)
            .frame(width: 12, height: 12)
            .foregroundStyle(
                Color(nsColor: .alternateSelectedControlTextColor),
                Color(nsColor: .controlAccentColor)
            )
            .background {
                Circle()
                    .fill(Color(nsColor: .controlAccentColor))
                    .overlay {
                        Circle()
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }
                    .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 1.2, x: 0, y: 0.6)
            }
            .accessibilityLabel(channel.accessibilityLabel)
    }
}

private struct SpatialRoutingFooterRow: View {
    let canRemove: Bool
    let add: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: add) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Add application")

            Rectangle()
                .fill(Theme.separator)
                .frame(width: 1, height: 18)

            Button(action: remove) {
                Image(systemName: "minus")
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 30, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .help("Remove selected application")

            Spacer()
        }
        .padding(.leading, 8)
        .frame(height: 40)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 12,
                bottomTrailingRadius: 12,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Theme.groupBackground)
        }
    }
}

private struct NativeBalanceSlider: NSViewRepresentable {
    @Binding var value: Double

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: -1, maxValue: 1, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.numberOfTickMarks = 11
        slider.allowsTickMarkValuesOnly = false
        slider.tickMarkPosition = .below
        slider.sliderType = .linear
        slider.altIncrementValue = 0.05
        return slider
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        if abs(nsView.doubleValue - value) > 0.0001 {
            nsView.doubleValue = value
        }
        nsView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    final class Coordinator: NSObject {
        private let value: Binding<Double>

        init(value: Binding<Double>) {
            self.value = value
        }

        @objc @MainActor func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }
    }
}

private struct DriverStatusRow: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isInstallingDriver {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: model.driverStatusSymbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(model.driverStatusColor)
                    .frame(width: 16, height: 16)
            }

            Text(model.driverStatusTitle)
                .settingsTitleStyle()

            Spacer()

            Button(model.driverActionTitle) {
                model.installDriver()
            }
            .controlSize(.small)
            .disabled(model.isInstallingDriver)
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
    }
}

private struct StudioDisplayStatusPill: View {
    let status: StudioDisplayConnectionStatus

    private var statusColor: Color {
        status.isConnected ? .green : .yellow
    }

    private var statusSymbolName: String {
        status.isConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: statusSymbolName)
                .font(.system(size: 11, weight: .medium))
            Text(status.detail)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(statusColor)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.horizontal, 12)
    }
}

private struct ProgressiveTopFade: View {
    let isVisible: Bool

    var body: some View {
        LinearGradient(
            colors: [
                Theme.background.opacity(0.98),
                Theme.background.opacity(0.72),
                Theme.background.opacity(0.22),
                Theme.background.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .opacity(isVisible ? 1 : 0)
        .frame(height: 74)
    }
}

private struct ScrollOffsetObserver: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollOffsetObserverView {
        let view = ScrollOffsetObserverView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: ScrollOffsetObserverView, context: Context) {
        context.coordinator.onChange = onChange
        nsView.coordinator = context.coordinator
        nsView.installObserverIfPossible()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    final class Coordinator: @unchecked Sendable {
        var onChange: (CGFloat) -> Void
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (CGFloat) -> Void) {
            self.onChange = onChange
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        @MainActor
        func attach(from view: NSView) {
            guard let scrollView = view.enclosingScrollView,
                  scrollView !== self.scrollView else {
                updateOffset()
                return
            }

            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }

            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateOffset()
                }
            }
            updateOffset()
        }

        @MainActor
        func updateOffset() {
            let offset = max(0, scrollView?.contentView.bounds.origin.y ?? 0)
            onChange(offset)
        }
    }
}

private final class ScrollOffsetObserverView: NSView {
    weak var coordinator: ScrollOffsetObserver.Coordinator?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installObserverIfPossible()
    }

    func installObserverIfPossible() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            coordinator?.attach(from: self)
        }
    }
}

private enum Theme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let groupBackground = Color(nsColor: .labelColor).opacity(0.035)
    static let activeRowBackground = Color(nsColor: .labelColor).opacity(0.08)
    static let completedRowBackground = Color(nsColor: .labelColor).opacity(0.035)
    static let pendingRowBackground = Color(nsColor: .labelColor).opacity(0.055)
    static let separator = Color(nsColor: .separatorColor)
}

private extension Text {
    func installTitleStyle(color: Color) -> some View {
        font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    func settingsTitleStyle(color: Color = .primary) -> some View {
        font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    func settingsDetailStyle() -> some View {
        font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}

private extension Image {
    func balanceSideIconStyle() -> some View {
        font(.system(size: 10, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: 12, height: 24)
    }
}
