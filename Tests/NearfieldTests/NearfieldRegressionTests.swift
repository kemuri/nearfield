import AppKit
import CoreAudio
import SwiftUI
import XCTest
@testable import Nearfield

final class NearfieldRegressionTests: XCTestCase {
    func testTestTonePlayerDoesNotPrepareCoreAudioDuringInitialization() {
        let player = TestTonePlayer()

        XCTAssertFalse(player.isAudioGraphPrepared)
    }

    func testBalanceMathPreservesLouderSideAndReducesOppositeChannel() {
        let volumes = BalanceMath.channelVolumes(
            currentLeft: 0.4,
            currentRight: 0.8,
            balance: 0.25
        )

        XCTAssertEqual(volumes.left, 0.6, accuracy: 0.0001)
        XCTAssertEqual(volumes.right, 0.8, accuracy: 0.0001)
    }

    func testBalanceMathUsesMinimumBaseWhenDisplaysReportNoVolume() {
        let volumes = BalanceMath.channelVolumes(
            currentLeft: nil,
            currentRight: nil,
            balance: -0.5,
            minimumBaseVolume: 0.01
        )

        XCTAssertEqual(volumes.left, 0.01, accuracy: 0.0001)
        XCTAssertEqual(volumes.right, 0.005, accuracy: 0.0001)
    }

    func testRouterVolumeContinuityPreservesVirtualVolumeAcrossTransientDeviceSwitch() {
        var continuity = RouterVolumeContinuity()
        continuity.observe(0.6)

        let activationVolume = continuity.activationVolume(
            currentRouterVolume: nil,
            capturedDisplayVolume: 1
        )

        XCTAssertEqual(activationVolume, 0.6)
    }

    func testRouterVolumeContinuityUsesDisplayVolumeForFirstActivation() {
        let continuity = RouterVolumeContinuity()

        let activationVolume = continuity.activationVolume(
            currentRouterVolume: nil,
            capturedDisplayVolume: 0.4
        )

        XCTAssertEqual(activationVolume, 0.4)
    }

    func testRouterVolumeContinuityPrefersCurrentVirtualVolume() {
        var continuity = RouterVolumeContinuity()
        continuity.observe(0.6)

        let activationVolume = continuity.activationVolume(
            currentRouterVolume: 0.35,
            capturedDisplayVolume: 1
        )

        XCTAssertEqual(activationVolume, 0.35)
    }

    func testSettingsHeaderAnimationRunsAtOneThirdOnboardingSpeed() {
        XCTAssertEqual(
            NearfieldHeaderAnimationConfiguration.settings.animationSpeed,
            NearfieldHeaderAnimationConfiguration.onboarding.animationSpeed / 3,
            accuracy: 0.000_001
        )
    }

    func testRouterPolicyDoesNotReactivateForReconnectAlone() {
        XCTAssertFalse(
            NearfieldRouterPolicy.shouldActivateRouter(
                defaultOutputIsNearfield: false,
                displaysJustReconnected: true,
                shouldReactivateAfterReconnect: false
            )
        )
    }

    func testRouterPolicyReactivatesWhenNearfieldWasDefaultBeforeReconnect() {
        XCTAssertTrue(
            NearfieldRouterPolicy.shouldActivateRouter(
                defaultOutputIsNearfield: false,
                displaysJustReconnected: true,
                shouldReactivateAfterReconnect: true
            )
        )
    }

    func testRouterPolicyKeepsNearfieldActiveWhenAlreadyDefaultOutput() {
        XCTAssertTrue(
            NearfieldRouterPolicy.shouldActivateRouter(
                defaultOutputIsNearfield: true,
                displaysJustReconnected: false,
                shouldReactivateAfterReconnect: false
            )
        )
    }

    func testDriverInstallPolicySkipsConfigurationWithoutTwoStudioDisplays() {
        XCTAssertFalse(NearfieldRouterPolicy.shouldConfigureRouterAfterDriverInstall(studioDisplayCount: 0))
        XCTAssertFalse(NearfieldRouterPolicy.shouldConfigureRouterAfterDriverInstall(studioDisplayCount: 1))
    }

    func testDriverInstallPolicyConfiguresWhenTwoStudioDisplaysAreAvailable() {
        XCTAssertTrue(NearfieldRouterPolicy.shouldConfigureRouterAfterDriverInstall(studioDisplayCount: 2))
    }

    func testDriverInstallAttemptRequiresDisplaysWithoutExplicitOverride() {
        XCTAssertFalse(
            NearfieldRouterPolicy.shouldAttemptDriverInstall(
                studioDisplayCount: 0,
                allowsMissingStudioDisplays: false
            )
        )
        XCTAssertFalse(
            NearfieldRouterPolicy.shouldAttemptDriverInstall(
                studioDisplayCount: 1,
                allowsMissingStudioDisplays: false
            )
        )
    }

    func testDriverInstallAttemptAllowsExplicitMissingDisplayOverride() {
        XCTAssertTrue(
            NearfieldRouterPolicy.shouldAttemptDriverInstall(
                studioDisplayCount: 0,
                allowsMissingStudioDisplays: true
            )
        )
    }

    func testForcedInstallCanFinishWithValidatedDriverBeforeCoreAudioActivation() {
        XCTAssertTrue(
            NearfieldRouterPolicy.shouldCompleteDriverInstallWithoutActivation(
                currentDriverIsInstalledOnDisk: true,
                allowsMissingStudioDisplays: true
            )
        )
        XCTAssertFalse(
            NearfieldRouterPolicy.shouldCompleteDriverInstallWithoutActivation(
                currentDriverIsInstalledOnDisk: false,
                allowsMissingStudioDisplays: true
            )
        )
        XCTAssertFalse(
            NearfieldRouterPolicy.shouldCompleteDriverInstallWithoutActivation(
                currentDriverIsInstalledOnDisk: true,
                allowsMissingStudioDisplays: false
            )
        )
    }

    func testDriverInstallRequestsEncodeOnlySupportedContexts() {
        XCTAssertTrue(DriverInstallRequest.userInitiated.requiresConfirmation)
        XCTAssertTrue(DriverInstallRequest.userInitiated.presentsErrors)
        XCTAssertFalse(DriverInstallRequest.userInitiated.disablesAppRoutingOnFailure)
        XCTAssertFalse(DriverInstallRequest.userInitiated.allowsMissingStudioDisplays)

        XCTAssertTrue(DriverInstallRequest.enablingAppRouting.disablesAppRoutingOnFailure)

        let onboardingRequest = DriverInstallRequest.onboarding(allowsMissingStudioDisplays: true)
        XCTAssertFalse(onboardingRequest.requiresConfirmation)
        XCTAssertFalse(onboardingRequest.presentsErrors)
        XCTAssertFalse(onboardingRequest.disablesAppRoutingOnFailure)
        XCTAssertTrue(onboardingRequest.allowsMissingStudioDisplays)
    }

    func testDriverInstallProgressWaitsForAuthorizationBeforeAdvancing() {
        XCTAssertEqual(DriverInstallPhase.preparation.onboardingStep, .approveDriver)
        XCTAssertEqual(
            DriverInstallPhase.authorizationAndInstallation.onboardingStep,
            .approveDriver
        )
        XCTAssertEqual(DriverInstallPhase.activation.onboardingStep, .routingDriver)
        XCTAssertEqual(DriverInstallPhase.configuration.onboardingStep, .routingDriver)
    }

    func testRoutingDriverFailuresAreNotReportedAsPermissionFailures() {
        let stages: [DriverInstallFailureStage] = [
            .installation,
            .activation,
            .configuration
        ]

        for stage in stages {
            let error = DriverInstallFailure(
                stage: stage,
                message: "Underlying failure"
            ).onboardingError

            XCTAssertEqual(error.step, .routingDriver)
            XCTAssertNotEqual(error.title, "Permissions Not Granted")
        }

        let authorizationError = DriverInstallFailure(
            stage: .authorization,
            message: "Administrator approval was cancelled."
        ).onboardingError
        XCTAssertEqual(authorizationError.step, .approveDriver)
        XCTAssertEqual(authorizationError.title, "Permissions Not Granted")

        let preparationError = DriverInstallFailure(
            stage: .preparation,
            message: "Could not prepare the driver."
        ).onboardingError
        XCTAssertEqual(preparationError.step, .approveDriver)
        XCTAssertEqual(preparationError.title, "Could Not Prepare Driver")
    }

    func testRoutingDriverStepWarnsThatInstallationCanTakeAWhile() {
        XCTAssertTrue(
            OnboardingInstallStep.routingDriver.activeDetail.contains(
                "This step can take a while."
            )
        )
    }

    func testPrivilegedInstallerRecognizesAuthorizationCancellation() {
        XCTAssertEqual(
            DriverInstaller.privilegedInstallError(
                errorNumber: -128,
                message: "User canceled."
            ),
            .authorizationCancelled
        )
        XCTAssertEqual(
            DriverInstaller.privilegedInstallError(
                errorNumber: -1,
                message: "Install command failed."
            ),
            .installFailed("Install command failed.")
        )
    }

    func testOnboardingCompletesForInstalledDriverWhenMissingDisplaysWereExplicitlyAllowed() {
        XCTAssertTrue(
            NearfieldRouterPolicy.shouldCompleteOnboardingAfterDriverInstall(
                driverInstalled: true,
                routerSelected: false,
                allowsMissingStudioDisplays: true
            )
        )
    }

    func testOnboardingStillRequiresConfiguredRouterWithoutExplicitOverride() {
        XCTAssertFalse(
            NearfieldRouterPolicy.shouldCompleteOnboardingAfterDriverInstall(
                driverInstalled: true,
                routerSelected: false,
                allowsMissingStudioDisplays: false
            )
        )
        XCTAssertTrue(
            NearfieldRouterPolicy.shouldCompleteOnboardingAfterDriverInstall(
                driverInstalled: true,
                routerSelected: false,
                allowsMissingStudioDisplays: true
            )
        )
    }

    func testRouterPublicationRequiresTwoStudioDisplays() {
        XCTAssertFalse(NearfieldRouterPolicy.shouldPublishRouter(studioDisplayCount: 0))
        XCTAssertFalse(NearfieldRouterPolicy.shouldPublishRouter(studioDisplayCount: 1))
        XCTAssertTrue(NearfieldRouterPolicy.shouldPublishRouter(studioDisplayCount: 2))
    }

    func testRouterDriverAvailabilityDistinguishesDiskAndCoreAudioState() {
        XCTAssertEqual(
            RouterDriverAvailability(installedOnDisk: false, loadedByCoreAudio: false),
            .missing
        )
        XCTAssertEqual(
            RouterDriverAvailability(installedOnDisk: true, loadedByCoreAudio: false),
            .installedOnDisk
        )
        XCTAssertEqual(
            RouterDriverAvailability(installedOnDisk: true, loadedByCoreAudio: true),
            .loaded
        )
        XCTAssertTrue(RouterDriverAvailability.loaded.isInstalled)
        XCTAssertTrue(RouterDriverAvailability.loaded.isLoaded)
        XCTAssertFalse(RouterDriverAvailability.installedOnDisk.isLoaded)
    }

    func testOpenApplicationPolicyShowsOnboardingUntilExplicitlyCompleted() {
        XCTAssertEqual(
            NearfieldLaunchPolicy.openApplicationPresentation(
                hasCompletedOnboarding: false,
                isLoginItemLaunch: false
            ),
            .onboarding
        )
        XCTAssertEqual(
            NearfieldLaunchPolicy.openApplicationPresentation(
                hasCompletedOnboarding: false,
                isLoginItemLaunch: true
            ),
            .onboarding
        )
    }

    func testOpenApplicationPolicyShowsSettingsForManualLaunchButNotLoginItemLaunch() {
        XCTAssertEqual(
            NearfieldLaunchPolicy.openApplicationPresentation(
                hasCompletedOnboarding: true,
                isLoginItemLaunch: false
            ),
            .settings
        )
        XCTAssertEqual(
            NearfieldLaunchPolicy.openApplicationPresentation(
                hasCompletedOnboarding: true,
                isLoginItemLaunch: true
            ),
            .none
        )
    }

    func testMissingCurrentDriverRequiresOnboardingEvenWhenCompletionPersisted() {
        XCTAssertFalse(
            NearfieldLaunchPolicy.requiresOnboarding(
                hasCompletedOnboarding: true,
                currentDriverIsInstalled: true
            )
        )
        XCTAssertTrue(
            NearfieldLaunchPolicy.requiresOnboarding(
                hasCompletedOnboarding: true,
                currentDriverIsInstalled: false
            )
        )
        XCTAssertTrue(
            NearfieldLaunchPolicy.requiresOnboarding(
                hasCompletedOnboarding: false,
                currentDriverIsInstalled: true
            )
        )
    }

    func testReopenPolicyAlwaysProvidesAWindow() {
        XCTAssertEqual(
            NearfieldLaunchPolicy.reopenPresentation(hasCompletedOnboarding: false),
            .onboarding
        )
        XCTAssertEqual(
            NearfieldLaunchPolicy.reopenPresentation(hasCompletedOnboarding: true),
            .settings
        )
    }

    func testStatusItemLeftClickFocusesOnboardingThenReturnsToContextMenu() {
        XCTAssertEqual(
            NearfieldLaunchPolicy.statusItemAction(
                hasCompletedOnboarding: false,
                explicitlyRequestsContextMenu: false
            ),
            .primaryWindow
        )
        XCTAssertEqual(
            NearfieldLaunchPolicy.statusItemAction(
                hasCompletedOnboarding: true,
                explicitlyRequestsContextMenu: false
            ),
            .contextMenu
        )
        XCTAssertEqual(
            NearfieldLaunchPolicy.statusItemAction(
                hasCompletedOnboarding: false,
                explicitlyRequestsContextMenu: true
            ),
            .contextMenu
        )
    }

    func testFullMenuBarMenuRemainsHiddenUntilInitialOnboardingReachesSettings() {
        XCTAssertFalse(
            NearfieldRouterPolicy.shouldShowFullMenuBarMenu(isInitialOnboardingInProgress: true)
        )
        XCTAssertTrue(
            NearfieldRouterPolicy.shouldShowFullMenuBarMenu(isInitialOnboardingInProgress: false)
        )
    }

    func testAccessoryApplicationMenuUsesCommandQ() {
        XCTAssertEqual(NearfieldApplicationMenuConfiguration.quitTitle, "Quit Nearfield")
        XCTAssertEqual(NearfieldApplicationMenuConfiguration.quitKeyEquivalent, "q")
        XCTAssertTrue(
            NearfieldApplicationMenuConfiguration.quitModifierMask.contains(.command)
        )
    }

    func testStudioDisplayConnectionStatusDescribesAvailability() {
        XCTAssertFalse(StudioDisplayConnectionStatus(connectedCount: 0).isConnected)
        XCTAssertEqual(StudioDisplayConnectionStatus(connectedCount: 0).title, "Not Connected")
        XCTAssertEqual(StudioDisplayConnectionStatus(connectedCount: 0).detail, "No Studio Displays connected")
        XCTAssertEqual(StudioDisplayConnectionStatus(connectedCount: 1).detail, "1 of 2 Studio Displays connected")
        XCTAssertTrue(StudioDisplayConnectionStatus(connectedCount: 2).isConnected)
        XCTAssertEqual(StudioDisplayConnectionStatus(connectedCount: 2).title, "Connected")
        XCTAssertEqual(StudioDisplayConnectionStatus(connectedCount: 2).detail, "2 Studio Displays connected")
    }

    func testRouterCapabilityRequiresDriverOwnedTargetAggregate() {
        XCTAssertTrue(
            RouterAudioDriverManager.supportsDriverOwnedTargetAggregate(
                in: "routing, driverOwnedTargetAggregate"
            )
        )
        XCTAssertFalse(RouterAudioDriverManager.supportsDriverOwnedTargetAggregate(in: "routeRules="))
        XCTAssertFalse(RouterAudioDriverManager.supportsDriverOwnedTargetAggregate(in: nil))
    }

    func testDisplayOrderingUsesSelectedLeftDisplay() {
        let first = AudioDevice(id: 1, uid: "display-a", name: "Studio Display A", outputChannelCount: 2)
        let second = AudioDevice(id: 2, uid: "display-b", name: "Studio Display B", outputChannelCount: 2)
        let third = AudioDevice(id: 3, uid: "display-c", name: "Studio Display C", outputChannelCount: 2)

        let ordered = StudioDisplayAudioManager.orderedDisplays(
            from: [first, second, third],
            leftDeviceUID: second.uid
        )

        XCTAssertEqual(ordered, [second, first])
    }

    @MainActor
    func testRouteRulesNormalizeDestinationsAndDropMalformedRules() {
        let resolver = WindowAudioRouteResolver()

        let resolved = resolver.resolvedRules(from: " com.spotify.client = LEFT ; malformed ; com.example.App = muted\ncom.browser = RIGHT ")

        XCTAssertEqual(resolved, "com.spotify.client=left; com.example.App=muted; com.browser=right")
    }

    @MainActor
    func testEmptyRouteRulesStayEmpty() {
        let resolver = WindowAudioRouteResolver()

        XCTAssertEqual(resolver.resolvedRules(from: ""), "")
    }

    @MainActor
    func testWindowScopedAliasRulesUseParentAppWindowScope() {
        let resolver = WindowAudioRouteResolver()

        XCTAssertTrue(resolver.hasWindowScopedRoute(in: "com.example.Helper=window:com.example.App"))
        XCTAssertEqual(
            resolver.resolvedRules(from: "com.example.Helper=window:com.example.App"),
            "com.example.Helper=pair"
        )
    }

    @MainActor
    func testWindowScopedRouteDetection() {
        let resolver = WindowAudioRouteResolver()

        XCTAssertTrue(resolver.hasWindowScopedRoute(in: "app.zen-browser.zen=screen"))
        XCTAssertFalse(resolver.hasWindowScopedRoute(in: "com.spotify.client=pair; com.example=left"))
    }

    @MainActor
    func testWindowScopedRunningGateIgnoresMissingApps() {
        let resolver = WindowAudioRouteResolver()

        XCTAssertFalse(resolver.hasRunningWindowScopedRoute(in: "com.example.DoesNotExist=window"))
        XCTAssertFalse(resolver.hasRunningWindowScopedRoute(in: "com.example.DoesNotExist=window:com.example.MissingHost"))
        XCTAssertFalse(resolver.hasRunningWindowScopedRoute(in: "com.example.DoesNotExist=pair"))
    }

    @MainActor
    func testWindowScopedFallbackRulesRemoveProcessOverrides() {
        let resolver = WindowAudioRouteResolver()

        XCTAssertEqual(
            resolver.fallbackRulesWithoutProcessOverrides(
                from: "com.spotify.client=left; com.apple.Safari=window; com.apple.WebKit.GPU=window:com.apple.Safari"
            ),
            "com.spotify.client=left; com.apple.Safari=pair; com.apple.WebKit.GPU=pair"
        )
    }

    func testBuildConfigurationMatchesSwiftPMConfiguration() {
        #if NEARFIELD_DISTRIBUTION
        XCTAssertTrue(BuildConfiguration.isDistribution)
        XCTAssertFalse(BuildConfiguration.debugToolsEnabled)
        #else
        XCTAssertFalse(BuildConfiguration.isDistribution)
        XCTAssertTrue(BuildConfiguration.debugToolsEnabled)
        #endif
    }

    func testAppRoutingRulesUpsertAndPreserveOtherRules() {
        let rawRules = "com.spotify.client=pair; com.apple.Safari=left"

        let enabledRules = AppRoutingRules.settingApp(
            bundleID: "com.apple.Safari",
            enabled: true,
            in: rawRules
        )

        XCTAssertEqual(enabledRules, "com.spotify.client=pair; com.apple.Safari=window")

        let disabledRules = AppRoutingRules.settingApp(
            bundleID: "com.apple.Safari",
            enabled: false,
            in: enabledRules
        )

        XCTAssertEqual(disabledRules, "com.spotify.client=pair")
    }

    func testAppRoutingRulesWriteHelperAliasesForAddedApps() {
        let rules = AppRoutingRules.settingApp(
            primaryBundleID: "com.example.App",
            aliasBundleIDs: ["com.example.App.helper", "com.example.App.helper"],
            enabled: true,
            in: "com.other=left"
        )

        XCTAssertEqual(
            rules,
            "com.other=left; com.example.App=window; com.example.App.helper=window:com.example.App"
        )
    }

    func testSafariRoutingRulesIncludeWebKitHelperAliases() {
        let rules = AppRoutingRules.settingApp(
            primaryBundleID: "com.apple.Safari",
            aliasBundleIDs: [],
            enabled: true,
            in: "com.other=left"
        )

        let parsedRules = AppRoutingRules.parse(rules)
        XCTAssertTrue(parsedRules.contains(AppRoutingRule(bundleID: "com.apple.Safari", destination: "window")))
        XCTAssertTrue(parsedRules.contains(AppRoutingRule(bundleID: "com.apple.WebKit.WebContent", destination: "window:com.apple.Safari")))
        XCTAssertTrue(parsedRules.contains(AppRoutingRule(bundleID: "com.apple.WebKit.GPU", destination: "window:com.apple.Safari")))
        XCTAssertTrue(parsedRules.contains(AppRoutingRule(bundleID: "com.apple.WebKit.Networking", destination: "window:com.apple.Safari")))
    }

    func testDisablingSafariRoutingClearsWebKitHelperAliases() {
        let enabledRules = AppRoutingRules.settingApp(
            primaryBundleID: "com.apple.Safari",
            aliasBundleIDs: [],
            enabled: true,
            in: "com.other=left"
        )

        let disabledRules = AppRoutingRules.settingApp(
            primaryBundleID: "com.apple.Safari",
            aliasBundleIDs: [],
            enabled: false,
            in: enabledRules
        )

        XCTAssertEqual(disabledRules, "com.other=left")
    }

    func testDriverPathParsingUsesLastMatchingBuildOutputLine() throws {
        let output = """
        building router driver
        /tmp/ignored.txt
          /tmp/build/NearfieldAudioDevice.driver

        """

        let path = try DriverInstaller.driverPath(
            fromBuildOutput: output,
            expectedSuffix: "NearfieldAudioDevice.driver"
        )

        XCTAssertEqual(path, "/tmp/build/NearfieldAudioDevice.driver")
    }

    func testDriverPathParsingRejectsMissingBundlePath() {
        XCTAssertThrowsError(
            try DriverInstaller.driverPath(
                fromBuildOutput: "build completed without final bundle path",
                expectedSuffix: "NearfieldAudioDevice.driver"
            )
        )
    }

    func testDriverRemovalPathsCoverCurrentAndLegacyBundlesOnce() {
        let paths = DriverInstaller.installedDriverRemovalPaths()

        XCTAssertEqual(paths.count, Set(paths).count)
        XCTAssertTrue(paths.contains("/Library/Audio/Plug-Ins/HAL/NearfieldAudioDevice.driver"))
        XCTAssertTrue(paths.contains("/Library/Audio/Plug-Ins/HAL/StudioPairRouterAudioDevice.driver"))
        XCTAssertTrue(paths.contains("/Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver"))
        XCTAssertTrue(paths.contains("/Library/Audio/Plug-Ins/HAL/NearfieldAudioDevice.driver.nearfield-installing"))
        XCTAssertTrue(paths.contains("/Library/Audio/Plug-Ins/HAL/StudioPairRouterAudioDevice.driver.studiopair-installing"))
        XCTAssertTrue(paths.contains("/Library/Audio/Plug-Ins/HAL/ProxyAudioDevice.driver.nearfield-installing"))
    }

    func testDriverDiskStateRejectsLegacyAndMalformedCurrentDrivers() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("NearfieldDriverStateTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        XCTAssertEqual(DriverInstaller.routerDriverDiskState(in: rootURL), .missing)

        let legacyURL = rootURL.appendingPathComponent(
            "ProxyAudioDevice.driver",
            isDirectory: true
        )
        try fileManager.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        XCTAssertEqual(DriverInstaller.routerDriverDiskState(in: rootURL), .legacy)

        let currentURL = rootURL.appendingPathComponent(
            "NearfieldAudioDevice.driver",
            isDirectory: true
        )
        try fileManager.createDirectory(at: currentURL, withIntermediateDirectories: true)
        XCTAssertEqual(DriverInstaller.routerDriverDiskState(in: rootURL), .invalidCurrent)
    }

    func testDriverDiskStateAcceptsOnlyValidCurrentDriverBundle() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("NearfieldDriverStateTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let driverURL = rootURL.appendingPathComponent(
            "NearfieldAudioDevice.driver",
            isDirectory: true
        )
        try makeTestBundle(
            at: driverURL,
            bundleIdentifier: "com.kemuri.Nearfield.AudioDevice",
            executableName: "NearfieldAudioDevice"
        )

        XCTAssertEqual(DriverInstaller.routerDriverDiskState(in: rootURL), .current)
    }

    func testDriverDiskStateRejectsCurrentFilenameWithWrongBundleIdentifier() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("NearfieldDriverStateTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let driverURL = rootURL.appendingPathComponent(
            "NearfieldAudioDevice.driver",
            isDirectory: true
        )
        try makeTestBundle(
            at: driverURL,
            bundleIdentifier: "com.example.NotNearfield",
            executableName: "NearfieldAudioDevice"
        )

        XCTAssertEqual(DriverInstaller.routerDriverDiskState(in: rootURL), .invalidCurrent)
    }

    func testDriverDiskStateRevalidatesReplacementAtTheSamePath() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("NearfieldDriverStateTests-\(UUID().uuidString)", isDirectory: true)
        let driverURL = rootURL.appendingPathComponent(
            "NearfieldAudioDevice.driver",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try makeTestBundle(
            at: driverURL,
            bundleIdentifier: "com.example.StaleDriver",
            executableName: "NearfieldAudioDevice"
        )
        XCTAssertEqual(DriverInstaller.routerDriverDiskState(in: rootURL), .invalidCurrent)

        try fileManager.removeItem(at: driverURL)
        try makeTestBundle(
            at: driverURL,
            bundleIdentifier: "com.kemuri.Nearfield.AudioDevice",
            executableName: "NearfieldAudioDevice"
        )

        XCTAssertEqual(DriverInstaller.routerDriverDiskState(in: rootURL), .current)
    }

    func testDriverDiskWaitFindsDelayedInstallation() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("NearfieldDriverWaitTests-\(UUID().uuidString)", isDirectory: true)
        let stagedURL = rootURL.appendingPathComponent("Staged.driver", isDirectory: true)
        let installedURL = rootURL.appendingPathComponent(
            "NearfieldAudioDevice.driver",
            isDirectory: true
        )
        defer {
            try? fileManager.removeItem(at: rootURL)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try makeTestBundle(
            at: stagedURL,
            bundleIdentifier: "com.kemuri.Nearfield.AudioDevice",
            executableName: "NearfieldAudioDevice"
        )

        let delayedInstall = Task.detached {
            try? await Task.sleep(nanoseconds: 50_000_000)
            try? FileManager.default.copyItem(at: stagedURL, to: installedURL)
        }
        let didFindDriver = await DriverInstaller.waitForCurrentRouterDriverOnDisk(
            in: rootURL,
            timeout: 1,
            interval: 0.01
        )
        await delayedInstall.value

        XCTAssertTrue(didFindDriver)
    }

    func testAppRoutingRulesDefaultToEmptyForFreshInstall() {
        let suiteName = "NearfieldTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(NearfieldPreferences.appRoutingRules(in: defaults), "")
    }

    func testAppRoutingRulesPreserveStoredPreference() {
        let suiteName = "NearfieldTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("com.example.App=window", forKey: NearfieldPreferences.appRoutingRulesKey)

        XCTAssertEqual(NearfieldPreferences.appRoutingRules(in: defaults), "com.example.App=window")
    }

    func testCleanupPreferenceClearsAppRoutingFlag() {
        let suiteName = "NearfieldTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set(true, forKey: NearfieldPreferences.appRoutingEnabledKey)
        NearfieldPreferences.clearAppRoutingEnabled(in: defaults)

        XCTAssertFalse(NearfieldPreferences.appRoutingEnabled(in: defaults))
    }

    func testPreferencesProvideDefaultsAndRoundTripConfiguration() {
        let suiteName = "NearfieldTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(NearfieldPreferences.outputMode(in: defaults), .stereo)
        XCTAssertTrue(NearfieldPreferences.showMenuBarApp(in: defaults))
        XCTAssertNil(NearfieldPreferences.leftDeviceUID(in: defaults))

        NearfieldPreferences.setOutputMode(.mono, in: defaults)
        NearfieldPreferences.setShowMenuBarApp(false, in: defaults)
        NearfieldPreferences.setLeftDeviceUID("display-left", in: defaults)
        NearfieldPreferences.setBalance(-0.25, in: defaults)
        NearfieldPreferences.setAppRoutingAppBundleIDs(["com.example.App"], in: defaults)

        XCTAssertEqual(NearfieldPreferences.outputMode(in: defaults), .mono)
        XCTAssertFalse(NearfieldPreferences.showMenuBarApp(in: defaults))
        XCTAssertEqual(NearfieldPreferences.leftDeviceUID(in: defaults), "display-left")
        XCTAssertEqual(NearfieldPreferences.balance(in: defaults), -0.25, accuracy: 0.0001)
        XCTAssertEqual(
            NearfieldPreferences.appRoutingAppBundleIDs(in: defaults),
            ["com.example.App"]
        )
    }

    func testOnboardingCompletionIsExplicitAndVersioned() {
        let suiteName = "NearfieldTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertFalse(NearfieldPreferences.hasCompletedOnboarding(in: defaults))

        NearfieldPreferences.markOnboardingCompleted(in: defaults)

        XCTAssertTrue(NearfieldPreferences.hasCompletedOnboarding(in: defaults))
        XCTAssertEqual(
            defaults.integer(forKey: NearfieldPreferences.onboardingCompletionVersionKey),
            NearfieldPreferences.latestOnboardingCompletionVersion
        )

        NearfieldPreferences.resetOnboardingCompletion(in: defaults)

        XCTAssertFalse(NearfieldPreferences.hasCompletedOnboarding(in: defaults))
        XCTAssertNil(
            defaults.object(forKey: NearfieldPreferences.onboardingCompletionVersionKey)
        )
    }

    func testOnboardingMigrationRequiresCurrentDriverAndPriorSetupEvidence() {
        let suiteName = "NearfieldTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        NearfieldPreferences.migrateOnboardingCompletionIfNeeded(
            currentDriverIsInstalled: true,
            in: defaults
        )
        XCTAssertFalse(NearfieldPreferences.hasCompletedOnboarding(in: defaults))

        NearfieldPreferences.markAggregateSchemaCurrent(in: defaults)
        NearfieldPreferences.migrateOnboardingCompletionIfNeeded(
            currentDriverIsInstalled: false,
            in: defaults
        )
        XCTAssertFalse(NearfieldPreferences.hasCompletedOnboarding(in: defaults))

        NearfieldPreferences.migrateOnboardingCompletionIfNeeded(
            currentDriverIsInstalled: true,
            in: defaults
        )
        XCTAssertTrue(NearfieldPreferences.hasCompletedOnboarding(in: defaults))
    }

    func testApplicationMoverReplacesExistingBundleAfterStagingCopy() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("NearfieldTests-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("Downloaded.app", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("Nearfield.app", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        try fileManager.createDirectory(at: sourceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: sourceURL.appendingPathComponent("version"))
        try Data("old".utf8).write(to: destinationURL.appendingPathComponent("version"))

        try ApplicationMover.installBundle(
            from: sourceURL,
            to: destinationURL,
            fileManager: fileManager
        )

        XCTAssertEqual(
            try String(contentsOf: destinationURL.appendingPathComponent("version"), encoding: .utf8),
            "new"
        )
        XCTAssertTrue(fileManager.fileExists(atPath: sourceURL.path))
        XCTAssertFalse(
            try fileManager.contentsOfDirectory(atPath: rootURL.path)
                .contains { $0.contains("nearfield-installing") || $0.contains("nearfield-backup") }
        )
    }

    func testApplicationMoverPreservesExistingBundleWhenStagingFails() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("NearfieldTests-\(UUID().uuidString)", isDirectory: true)
        let missingSourceURL = rootURL.appendingPathComponent("Missing.app", isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("Nearfield.app", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: rootURL)
        }

        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let versionURL = destinationURL.appendingPathComponent("version")
        try Data("old".utf8).write(to: versionURL)

        XCTAssertThrowsError(
            try ApplicationMover.installBundle(
                from: missingSourceURL,
                to: destinationURL,
                fileManager: fileManager
            )
        )
        XCTAssertEqual(try String(contentsOf: versionURL, encoding: .utf8), "old")
    }

    private func makeTestBundle(
        at bundleURL: URL,
        bundleIdentifier: String,
        executableName: String
    ) throws {
        let fileManager = FileManager.default
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleExecutable": executableName,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let executableURL = macOSURL.appendingPathComponent(executableName)
        try Data("#!/bin/sh\n".utf8).write(to: executableURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
    }

    #if !NEARFIELD_DISTRIBUTION
    @MainActor
    func testWaveLabExporterEmitsConfiguration() {
        let source = WaveLabExporter.swiftSource(for: .onboarding)

        // Shape of the emitted literal.
        XCTAssertTrue(source.contains("static let onboarding = NearfieldHeaderAnimationConfiguration("))
        XCTAssertTrue(source.contains("primaryWave: HeaderSineWaveConfiguration("))
        XCTAssertTrue(source.contains("secondaryWave: HeaderSineWaveConfiguration("))
        XCTAssertTrue(source.contains("noise: HeaderNoiseConfiguration("))

        // The default onboarding config: soft-light blend, blur strong on the left.
        XCTAssertTrue(source.contains("waveBlendMode: .softLight"))
        XCTAssertTrue(source.contains("blurStrongOnLeft: true"))
        XCTAssertTrue(source.contains("progressiveBlurExponent:"))

        // Noise options and the render effect are all emitted so the pasted
        // config still compiles.
        XCTAssertTrue(source.contains("animated: true"))
        XCTAssertTrue(source.contains("monochrome: false"))
        XCTAssertTrue(source.contains("monochromeIsWhite: true"))
        XCTAssertTrue(source.contains("blendMode: .softLight"))
        XCTAssertTrue(source.contains("effect: .none"))

        // Base color is emitted as an sRGB component literal.
        XCTAssertTrue(source.contains("baseColor: Color(red: "))
    }

    @MainActor
    func testWaveLabExporterReflectsTweakedValues() {
        var config = NearfieldHeaderAnimationConfiguration.onboarding
        config.blurStrongOnLeft = false
        config.waveBlendMode = .screen
        config.progressiveBlurSegments = 11
        config.effect = .glitch
        config.noise.monochrome = true
        config.noise.monochromeIsWhite = false

        let source = WaveLabExporter.swiftSource(for: config)

        XCTAssertTrue(source.contains("blurStrongOnLeft: false"))
        XCTAssertTrue(source.contains("waveBlendMode: .screen"))
        XCTAssertTrue(source.contains("progressiveBlurSegments: 11"))
        XCTAssertTrue(source.contains("effect: .glitch"))
        XCTAssertTrue(source.contains("monochrome: true"))
        XCTAssertTrue(source.contains("monochromeIsWhite: false"))
    }

    @MainActor
    func testWaveLabPresetImporterRoundTripsExportedConfiguration() throws {
        var config = NearfieldHeaderAnimationConfiguration.onboarding
        config.baseColor = Color(red: 0.1200, green: 0.3400, blue: 0.5600)
        config.animationSpeed = 0.777
        config.loopResetInterval = 12_345
        config.waveBlendMode = .screen
        config.primaryWave.color = Color(red: 0.1000, green: 0.2000, blue: 0.3000)
        config.primaryWave.opacity = 0.321
        config.primaryWave.lineWidth = 19.5
        config.primaryWave.phaseOffset = -1.25
        config.secondaryWave.color = Color(red: 0.9000, green: 0.8000, blue: 0.7000)
        config.secondaryWave.opacity = 0.654
        config.secondaryWave.lineWidth = 11.25
        config.secondaryWave.phaseOffset = 2.5
        config.progressiveBlurSegments = 11
        config.maximumProgressiveBlurRadius = 22.5
        config.progressiveBlurExponent = 1.75
        config.blurStrongOnLeft = false
        config.noise.opacity = 0.123
        config.noise.density = 4321
        config.noise.minimumDotSize = 0.75
        config.noise.maximumDotSize = 2.25
        config.noise.framesPerSecond = 9
        config.noise.animated = false
        config.noise.monochrome = true
        config.noise.monochromeIsWhite = false
        config.noise.blendMode = .overlay
        config.effect = .glitch
        config.effectSettings = WaveLabEffectSettings(
            greyscaleAmount: 0.5,
            pixelBlockSize: 8,
            ditherContrast: 2.25,
            ditherCellSize: 4.5,
            ditherLevels: 5,
            glitchAmount: 12.5,
            glitchSliceCount: 7,
            glitchSliceDisplacement: 33,
            glitchSpeed: 1.75
        )

        let source = WaveLabExporter.swiftSource(for: config)
        let imported = try WaveLabPresetImporter.configuration(from: source)

        XCTAssertEqual(WaveLabExporter.swiftSource(for: imported), source)
    }

    @MainActor
    func testWaveLabPresetImporterAcceptsSourceStyleWhiteWaveColors() throws {
        let exported = WaveLabExporter.swiftSource(for: NearfieldHeaderAnimationConfiguration.onboarding)
        let sourceStyle = exported.replacingOccurrences(
            of: "color: Color(red: 1.0000, green: 1.0000, blue: 1.0000)",
            with: "color: .white"
        )

        let imported = try WaveLabPresetImporter.configuration(from: sourceStyle)

        XCTAssertEqual(WaveLabExporter.swiftSource(for: imported), exported)
    }
    #endif
}
