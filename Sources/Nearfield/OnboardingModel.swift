import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case install
    case settings
}

enum OnboardingInstallStep: Int, CaseIterable {
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
            "Preparing the virtual output driver\nThis step can take a while."
        case .appRouting:
            "Enabling App Audio Routing controls"
        }
    }
}

struct OnboardingInstallError: Equatable {
    let step: OnboardingInstallStep
    let title: String
    let message: String
}

extension DriverInstallFailure {
    var onboardingError: OnboardingInstallError {
        switch stage {
        case .authorization:
            OnboardingInstallError(
                step: .approveDriver,
                title: "Permissions Not Granted",
                message: message
            )
        case .preparation:
            OnboardingInstallError(
                step: .approveDriver,
                title: "Could Not Prepare Driver",
                message: message
            )
        case .installation:
            OnboardingInstallError(
                step: .routingDriver,
                title: "Could Not Install Driver",
                message: message
            )
        case .activation:
            OnboardingInstallError(
                step: .routingDriver,
                title: "Driver Did Not Become Available",
                message: message
            )
        case .configuration:
            OnboardingInstallError(
                step: .routingDriver,
                title: "Could Not Configure Nearfield",
                message: message
            )
        }
    }
}

extension DriverInstallPhase {
    var onboardingStep: OnboardingInstallStep {
        switch self {
        case .preparation, .authorizationAndInstallation:
            .approveDriver
        case .activation, .configuration:
            .routingDriver
        }
    }
}

enum OnboardingInstallScenario {
    case smooth
    case permissionFailure
}

enum OnboardingInstallStepState {
    case completed
    case active
    case failed(OnboardingInstallError)
    case pending
}

struct SpatialRoutingApp: Identifiable, Equatable {
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
final class OnboardingModel: ObservableObject {
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
    @Published var driverInstallState: DriverInstallState = .idle
    @Published var nearfieldDriverSelected = false
    @Published var appVersionText = "Version 0.1.0"
    @Published var studioDisplayCount = 0
    @Published var coreAudioAvailability: CoreAudioAvailability = .checking
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
        driverInstallState = delegate.settingsDriverInstallState()
        if !installingDriver {
            driverInstalled = delegate.settingsDriverInstalled()
            nearfieldDriverSelected = delegate.settingsNearfieldDriverSelected()
            studioDisplayCount = delegate.settingsDevices().count
            coreAudioAvailability = delegate.settingsCoreAudioAvailability()
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
        retryLiveInstall(.environment(allowsMissingStudioDisplays: allowsMissingStudioDisplays))
    }

    private func retryLiveRouterConfiguration() {
        retryLiveInstall(.routerConfiguration)
    }

    private enum LiveInstallRetry {
        case environment(allowsMissingStudioDisplays: Bool)
        case routerConfiguration

        var step: OnboardingInstallStep {
            switch self {
            case .environment:
                return .environment
            case .routerConfiguration:
                return .routingDriver
            }
        }
    }

    private func retryLiveInstall(_ retry: LiveInstallRetry) {
        cancelInstallTasks()
        if case .environment(let allowsMissingStudioDisplays) = retry {
            allowsMissingStudioDisplaysForLiveInstall = allowsMissingStudioDisplays
        }
        installError = nil
        installProgressIndex = retry.step.rawValue

        pendingLiveInstallStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let isCoreAudioReady = await self.delegate?.settingsRefreshAudioState() ?? false
            guard !Task.isCancelled else { return }
            self.pendingLiveInstallStartTask = nil
            self.refreshFromDelegate()
            let canFinishForcedInstallWithoutCoreAudio =
                NearfieldRouterPolicy.shouldCompleteOnboardingAfterDriverInstall(
                    driverInstalled: self.driverInstalled,
                    routerSelected: self.nearfieldDriverSelected,
                    allowsMissingStudioDisplays: self.allowsMissingStudioDisplaysForLiveInstall
                )
            guard isCoreAudioReady || canFinishForcedInstallWithoutCoreAudio else {
                self.failLiveInstall(with: self.coreAudioUnavailableError(step: retry.step))
                return
            }
            if canFinishForcedInstallWithoutCoreAudio {
                self.runLiveInstallFlow()
                return
            }

            switch retry {
            case .environment(let allowsMissingStudioDisplays):
                guard allowsMissingStudioDisplays || self.liveInstallCanCompleteConfiguration() else {
                    self.failLiveInstall(with: self.studioDisplayRequirementError(step: retry.step))
                    return
                }
                self.runLiveInstallFlow()
            case .routerConfiguration:
                guard self.liveInstallCanCompleteConfiguration() else {
                    self.failLiveInstall(with: self.studioDisplayRequirementError(step: retry.step))
                    return
                }
                self.liveInstallRequestedAt = Date()
                self.delegate?.settingsResetDriverInstallState()
                self.delegate?.settingsApplyConfiguration()
                self.startLiveInstallSequence()
            }
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

    var canSwapChannels: Bool {
        studioDisplayCount >= 2 && !isInstallingDriver
    }

    func swapChannels() {
        delegate?.settingsSwapAssignment()
        refreshFromDelegate()
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
            if NearfieldRouterPolicy.shouldCompleteOnboardingAfterDriverInstall(
                driverInstalled: driverInstalled,
                routerSelected: nearfieldDriverSelected,
                allowsMissingStudioDisplays: allowsMissingStudioDisplaysForLiveInstall
            ) {
                installProgressIndex = OnboardingInstallStep.allCases.count
                showStep(.settings)
                return
            }

            guard liveInstallCanCompleteConfiguration() else {
                failLiveInstall(with: studioDisplayRequirementError(step: .environment))
                return
            }

            installProgressIndex = OnboardingInstallStep.routingDriver.rawValue
            delegate?.settingsApplyConfiguration()
            startLiveInstallSequence()
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
            .onboarding(
                allowsMissingStudioDisplays: allowsMissingStudioDisplaysForLiveInstall
            )
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
                    let activeStep: OnboardingInstallStep
                    if case .installing(let phase) = self.driverInstallState {
                        activeStep = phase.onboardingStep
                    } else {
                        activeStep = .approveDriver
                    }
                    withAnimation(.smooth(duration: 0.24)) {
                        self.installProgressIndex = max(
                            self.installProgressIndex,
                            activeStep.rawValue
                        )
                    }
                    continue
                }

                if case .failed(let failure) = self.driverInstallState {
                    self.failLiveInstall(with: failure.onboardingError)
                    return
                }

                if NearfieldRouterPolicy.shouldCompleteOnboardingAfterDriverInstall(
                    driverInstalled: self.driverInstalled,
                    routerSelected: self.nearfieldDriverSelected,
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

                if Date().timeIntervalSince(startedAt) > 5,
                   self.driverInstallState == .idle {
                    self.failLiveInstall(
                        with: OnboardingInstallError(
                            step: .routingDriver,
                            title: "Driver Install Did Not Start",
                            message: "Nearfield could not start the driver installer. Try again."
                        )
                    )
                    return
                }
            }
        }
    }

    private func liveInstallCanCompleteConfiguration() -> Bool {
        NearfieldRouterPolicy.shouldConfigureRouterAfterDriverInstall(
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
