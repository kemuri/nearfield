import CoreAudio
import SwiftUI
import XCTest
@testable import Nearfield

final class NearfieldRegressionTests: XCTestCase {
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

    func testSettingsHeaderAnimationRunsAtOneThirdOnboardingSpeed() {
        XCTAssertEqual(
            NearfieldHeaderAnimationConfiguration.settings.animationSpeed,
            NearfieldHeaderAnimationConfiguration.onboarding.animationSpeed / 3,
            accuracy: 0.000_001
        )
    }

    func testActivationPolicyDoesNotReactivateForReconnectAlone() {
        XCTAssertFalse(
            NearfieldActivationPolicy.shouldActivateRouter(
                defaultOutputIsNearfield: false,
                displaysJustReconnected: true,
                shouldReactivateAfterReconnect: false
            )
        )
    }

    func testActivationPolicyReactivatesWhenNearfieldWasDefaultBeforeReconnect() {
        XCTAssertTrue(
            NearfieldActivationPolicy.shouldActivateRouter(
                defaultOutputIsNearfield: false,
                displaysJustReconnected: true,
                shouldReactivateAfterReconnect: true
            )
        )
    }

    func testActivationPolicyKeepsNearfieldActiveWhenAlreadyDefaultOutput() {
        XCTAssertTrue(
            NearfieldActivationPolicy.shouldActivateRouter(
                defaultOutputIsNearfield: true,
                displaysJustReconnected: false,
                shouldReactivateAfterReconnect: false
            )
        )
    }

    func testDriverInstallPolicySkipsConfigurationWithoutTwoStudioDisplays() {
        XCTAssertFalse(NearfieldActivationPolicy.shouldConfigureRouterAfterDriverInstall(studioDisplayCount: 0))
        XCTAssertFalse(NearfieldActivationPolicy.shouldConfigureRouterAfterDriverInstall(studioDisplayCount: 1))
    }

    func testDriverInstallPolicyConfiguresWhenTwoStudioDisplaysAreAvailable() {
        XCTAssertTrue(NearfieldActivationPolicy.shouldConfigureRouterAfterDriverInstall(studioDisplayCount: 2))
    }

    func testRouterPublicationRequiresTwoStudioDisplays() {
        XCTAssertFalse(NearfieldActivationPolicy.shouldPublishRouter(studioDisplayCount: 0))
        XCTAssertFalse(NearfieldActivationPolicy.shouldPublishRouter(studioDisplayCount: 1))
        XCTAssertTrue(NearfieldActivationPolicy.shouldPublishRouter(studioDisplayCount: 2))
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

    func testDebugBuildConfigurationEnablesDebugTools() {
        XCTAssertFalse(BuildConfiguration.isDistribution)
        XCTAssertTrue(BuildConfiguration.debugToolsEnabled)
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
}
