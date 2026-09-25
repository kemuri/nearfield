import CoreAudio
import Security
import XCTest
@testable import Nearfield

final class RouterDriverProtocolTests: XCTestCase {
    private func settings(
        rules: String = "com.apple.Safari=left",
        processRoutes: [Int32: String] = [:]
    ) -> RouterDriverSettings {
        RouterDriverSettings(
            deviceName: "Nearfield",
            targetDevices: ["left-display", "right-display"],
            mode: .stereo,
            routingEnabled: true,
            routeRules: rules,
            processRoutes: processRoutes
        )
    }

    func testFirstSettingsSendEverything() {
        let changes = settings(processRoutes: [101: "left"]).changes(since: nil)

        XCTAssertEqual(changes["deviceName"] as? String, "Nearfield")
        XCTAssertEqual(changes["targetDevices"] as? [String], ["left-display", "right-display"])
        XCTAssertEqual(changes["targetMode"] as? String, "stereo")
        XCTAssertEqual(changes["routingEnabled"] as? Bool, true)
        XCTAssertEqual(changes["routeRules"] as? String, "com.apple.Safari=left")
        XCTAssertEqual(changes["processRoutes"] as? [String: String], ["101": "left"])
    }

    func testUnchangedSettingsSendNothing() {
        XCTAssertTrue(settings().changes(since: settings()).isEmpty)
    }

    func testOnlyChangedSettingsAreSent() {
        let previous = settings()
        var next = previous
        next.processRoutes = [202: "right"]

        let changes = next.changes(since: previous)

        XCTAssertEqual(Set(changes.keys), ["processRoutes"])
        XCTAssertEqual(changes["processRoutes"] as? [String: String], ["202": "right"])

        next = previous
        next.mode = .mono
        XCTAssertEqual(Set(next.changes(since: previous).keys), ["targetMode"])
    }

    func testResolvedRulesSplitIntoSavedRulesAndProcessRoutes() {
        let split = RouterRouteRules.split("pid:101=left; com.apple.Safari=Right; PID:202=pair; pid:0=left; pid:x=left")

        XCTAssertEqual(split.rules, "com.apple.Safari=Right; pid:0=left; pid:x=left")
        XCTAssertEqual(split.processRoutes, [101: "left", 202: "pair"])
    }

    func testStatusParsesDriverDictionary() throws {
        let status = try XCTUnwrap(RouterDriverStatus(dictionary: [
            "protocolVersion": 1,
            "instance": NSNumber(value: Int64(1_234_567_890_123)),
            "driverVersion": "1.1.0",
            "capabilities": ["settingsDictionary", "statusNotifications"],
            "ready": true,
            "targetDevices": ["left-display", "right-display"],
            "targetMode": "stereo",
            "hidden": false,
            "outputRunning": true,
            "sampleRate": 48_000.0,
            "latencyMilliseconds": 21.5,
            "writerVerification": "verified",
            "hostProcessID": 4321,
            "counters": ["underruns": 3, "halRequests": 12]
        ]))

        XCTAssertEqual(status.instance, 1_234_567_890_123)
        XCTAssertEqual(status.driverVersion, "1.1.0")
        XCTAssertEqual(status.capabilities, ["settingsDictionary", "statusNotifications"])
        XCTAssertTrue(status.outputRunning)
        XCTAssertEqual(status.sampleRate, 48_000)
        XCTAssertEqual(status.latencyMilliseconds, 21.5)
        XCTAssertEqual(status.underruns, 3)
        XCTAssertEqual(status.halRequests, 12)
        XCTAssertEqual(status.writerVerification, "verified")
        XCTAssertEqual(status.hostProcessID, 4321)
        XCTAssertTrue(status.isReady(deviceUIDs: ["left-display", "right-display"], mode: .stereo))
    }

    func testStatusReadinessRequiresExactTargetsOrderAndMode() throws {
        let status = try XCTUnwrap(RouterDriverStatus(dictionary: [
            "protocolVersion": 1,
            "ready": true,
            "targetDevices": ["left-display", "right-display"],
            "targetMode": "stereo"
        ]))

        XCTAssertFalse(status.isReady(deviceUIDs: ["right-display", "left-display"], mode: .stereo))
        XCTAssertFalse(status.isReady(deviceUIDs: ["left-display", "right-display"], mode: .mono))
        XCTAssertFalse(status.isReady(deviceUIDs: ["left-display"], mode: .stereo))

        var notReady = status
        notReady.ready = false
        XCTAssertFalse(notReady.isReady(deviceUIDs: ["left-display", "right-display"], mode: .stereo))
    }

    func testStatusWithoutProtocolVersionIsRejected() {
        XCTAssertNil(RouterDriverStatus(dictionary: ["ready": true]))
    }
}

final class AudioDeviceSelectionTests: XCTestCase {
    private let usb = kAudioDeviceTransportTypeUSB
    private let builtIn = kAudioDeviceTransportTypeBuiltIn

    private func device(
        _ uid: String,
        name: String,
        transport: UInt32,
        model: String = "",
        aggregate: Bool = false,
        outputs: UInt32 = 2
    ) -> AudioDevice {
        AudioDevice(
            id: AudioObjectID(abs(uid.hashValue % 10_000)),
            uid: uid,
            name: name,
            outputChannelCount: outputs,
            transportType: transport,
            modelUID: model,
            isAggregate: aggregate
        )
    }

    func testStudioDisplaysAreDetectedByConnectionTypeAndModel() {
        let display = device(
            "AppleUSBAudioEngine:Apple Inc.:Studio Display:1111:6,7",
            name: "Studio Display Speakers",
            transport: usb,
            model: "Studio Display:05AC:1114"
        )
        let renamed = device("usb-1", name: "Desk Left", transport: usb, model: "Studio Display:05AC:1114")
        let byProductID = device("usb-2", name: "Desk Right", transport: usb, model: "Unknown:05AC:1114")

        XCTAssertTrue(StudioDisplayDetection.isStudioDisplaySpeaker(display))
        XCTAssertTrue(StudioDisplayDetection.isStudioDisplaySpeaker(renamed))
        XCTAssertTrue(StudioDisplayDetection.isStudioDisplaySpeaker(byProductID))
    }

    func testDevicesNamedStudioDisplayAreNotEnoughOnTheirOwn() {
        let aggregate = device(
            "com.kemuri.Nearfield.DriverTargetAggregate",
            name: "Studio Display Pair",
            transport: kAudioDeviceTransportTypeAggregate,
            aggregate: true
        )
        let virtual = device("virtual", name: "Studio Display Speakers", transport: kAudioDeviceTransportTypeVirtual)
        let microphone = device("mic", name: "Studio Display Microphone", transport: usb, outputs: 0)
        let otherUSB = device("usb-dac", name: "USB DAC", transport: usb, model: "DAC:1234:5678")

        XCTAssertFalse(StudioDisplayDetection.isStudioDisplaySpeaker(aggregate))
        XCTAssertFalse(StudioDisplayDetection.isStudioDisplaySpeaker(virtual))
        XCTAssertFalse(StudioDisplayDetection.isStudioDisplaySpeaker(microphone))
        XCTAssertFalse(StudioDisplayDetection.isStudioDisplaySpeaker(otherUSB))
    }

    func testFallbackPrefersPreviousOutputThenBuiltInSpeakers() {
        let display = device("display", name: "Studio Display Speakers", transport: usb, model: "Studio Display:05AC:1114")
        let headphones = device("dac", name: "USB DAC", transport: usb)
        // Localized names must not matter: connection type identifies the speakers.
        let speakers = device("BuiltInSpeakerDevice", name: "Haut-parleurs du MacBook Pro", transport: builtIn)
        let devices = [display, headphones, speakers]

        XCTAssertEqual(FallbackOutput.choose(from: devices, preferredUID: "dac") { _ in true }, headphones)
        XCTAssertEqual(FallbackOutput.choose(from: devices, preferredUID: "gone") { _ in true }, speakers)
        XCTAssertEqual(FallbackOutput.choose(from: devices, preferredUID: nil) { _ in true }, speakers)
    }

    func testFallbackUsesAnyRealOutputButNeverVirtualOrIneligibleDevices() {
        let display = device("display", name: "Studio Display Speakers", transport: usb, model: "Studio Display:05AC:1114")
        let nearfield = device(NearfieldAudioIdentifiers.routerDeviceUID, name: "Nearfield", transport: kAudioDeviceTransportTypeVirtual)
        let aggregate = device("aggregate", name: "Aggregate", transport: kAudioDeviceTransportTypeAggregate, aggregate: true)
        let airPods = device("airpods", name: "AirPods", transport: kAudioDeviceTransportTypeBluetooth)

        XCTAssertEqual(
            FallbackOutput.choose(from: [display, nearfield, aggregate, airPods], preferredUID: nil) { _ in true },
            airPods
        )
        // A display left at full volume for Nearfield is not eligible.
        XCTAssertNil(FallbackOutput.choose(from: [display, nearfield, aggregate], preferredUID: "display") { _ in false })
        XCTAssertEqual(
            FallbackOutput.choose(from: [display, nearfield], preferredUID: nil) { _ in true },
            display
        )
    }

    func testApplicationsFolderIncludesTheUsersApplicationsFolder() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        XCTAssertTrue(ApplicationLocation.isInApplicationsFolder(
            URL(fileURLWithPath: "/Applications/Nearfield.app"), homeDirectory: home
        ))
        XCTAssertTrue(ApplicationLocation.isInApplicationsFolder(
            URL(fileURLWithPath: "/Users/test/Applications/Nearfield.app"), homeDirectory: home
        ))
        XCTAssertFalse(ApplicationLocation.isInApplicationsFolder(
            URL(fileURLWithPath: "/Users/test/Downloads/Nearfield.app"), homeDirectory: home
        ))
        XCTAssertFalse(ApplicationLocation.isInApplicationsFolder(
            URL(fileURLWithPath: "/Applications/Utilities/Nearfield.app"), homeDirectory: home
        ))
    }

    func testBundledDriverRequirementAcceptsOnlyTheSameTeamsDriver() throws {
        let driverPath = "/Applications/Nearfield.app/Contents/Resources/Drivers/NearfieldAudioDevice.driver"
        guard FileManager.default.fileExists(atPath: driverPath),
              let team = Self.teamIdentifier(ofCodeAt: driverPath) else {
            throw XCTSkip("A Developer ID signed Nearfield.app is not installed.")
        }

        XCTAssertNoThrow(try DriverInstaller.verifySignature(
            atPath: driverPath,
            requirement: DriverInstaller.driverRequirement(teamIdentifier: team)
        ))
        XCTAssertThrowsError(try DriverInstaller.verifySignature(
            atPath: driverPath,
            requirement: DriverInstaller.driverRequirement(teamIdentifier: "AAAAAAAAAA")
        ))
    }

    private static func teamIdentifier(ofCodeAt path: String) -> String? {
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else {
            return nil
        }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

@MainActor
final class ChangeSignalTests: XCTestCase {
    func testChangeBeforeWaitReturnsImmediately() async throws {
        let signal = ChangeSignal()
        signal.fire()

        try await signal.wait(timeout: nil)
    }

    func testFireWakesWaiter() async throws {
        let signal = ChangeSignal()
        let waiter = Task { @MainActor in try await signal.wait(timeout: nil) }
        await Task.yield()
        signal.fire()

        try await waiter.value
    }

    func testWaitEndsAtTimeoutWithoutChange() async throws {
        let signal = ChangeSignal()
        let start = ProcessInfo.processInfo.systemUptime

        try await signal.wait(timeout: 20_000_000)

        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - start, 0.015)
    }

    func testCancelledWaitThrows() async {
        let signal = ChangeSignal()
        let waiter = Task { @MainActor in try await signal.wait(timeout: nil) }
        await Task.yield()
        waiter.cancel()

        do {
            try await waiter.value
            XCTFail("A cancelled wait should throw.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

@MainActor
final class WindowRouteFollowerTests: XCTestCase {
    final class Published {
        var rules: [String] = []
    }

    func testPublishesOnlyWhenResolvedRulesChange() async throws {
        let published = Published()
        let follower = WindowRouteFollower { rules in published.rules.append(rules) }
        follower.update(runningApplications: [], displayTargets: [], rawRules: "com.apple.Safari=left")
        follower.start()
        follower.checkNow()
        follower.checkNow()
        try await waitForPublished(published, count: 1)

        follower.update(runningApplications: [], displayTargets: [], rawRules: "com.apple.Safari=right")
        try await waitForPublished(published, count: 2)
        follower.checkNow()
        follower.stop()
        try await Task.sleep(nanoseconds: 100_000_000)

        let rules = published.rules
        XCTAssertEqual(rules, ["com.apple.Safari=left", "com.apple.Safari=right"])
    }

    func testChecksNothingWhileStopped() async throws {
        let published = Published()
        let follower = WindowRouteFollower { rules in published.rules.append(rules) }
        follower.update(runningApplications: [], displayTargets: [], rawRules: "com.apple.Safari=left")
        follower.checkNow()
        try await Task.sleep(nanoseconds: 100_000_000)

        let rules = published.rules
        XCTAssertTrue(rules.isEmpty)
    }

    /// Removing the last window rule stops following; a result already on its
    /// way to the main thread must not reinstall the old route.
    func testStopDiscardsAResultAlreadyOnItsWay() async throws {
        let published = Published()
        let follower = WindowRouteFollower { rules in published.rules.append(rules) }
        follower.update(runningApplications: [], displayTargets: [], rawRules: "com.apple.Safari=left")
        follower.start()
        try await waitForPublished(published, count: 1)

        // The main thread is busy here, so the new result waits in its queue.
        follower.update(runningApplications: [], displayTargets: [], rawRules: "com.apple.Safari=right")
        follower.waitForQueuedWork()
        follower.stop()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(published.rules, ["com.apple.Safari=left"])
    }

    func testResultForAnOlderConfigurationIsNotDelivered() async throws {
        let published = Published()
        let follower = WindowRouteFollower { rules in published.rules.append(rules) }
        follower.update(runningApplications: [], displayTargets: [], rawRules: "com.apple.Safari=left")
        follower.start()
        try await waitForPublished(published, count: 1)

        follower.update(runningApplications: [], displayTargets: [], rawRules: "com.apple.Safari=right")
        follower.waitForQueuedWork()
        follower.update(runningApplications: [], displayTargets: [], rawRules: "com.apple.Safari=muted")
        follower.waitForQueuedWork()
        try await waitForPublished(published, count: 2)
        try await Task.sleep(nanoseconds: 100_000_000)
        follower.stop()

        XCTAssertEqual(published.rules, ["com.apple.Safari=left", "com.apple.Safari=muted"])
    }

    private func waitForPublished(_ published: Published, count: Int) async throws {
        for _ in 0..<200 {
            if published.rules.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected \(count) published rule sets.")
    }
}

@MainActor
final class RouterOutputActivationTests: XCTestCase {
    /// Two displays at -30 dB, with Nearfield's volume and the displays'
    /// levels in decibels. Nearfield is heard at router + display level; an
    /// app playing on a display directly is heard at the display level.
    @MainActor final class Displays {
        var events: [String] = []
        var routerDecibels: Float32 = -40
        var displayDecibels: Float32 = -30
        var routerIsDefault = false
        var otherPlayback: Set<String> = []
        var failing: String?
        var savedCompensation: Float32 = 0
        private(set) var loudestNearfield: Float32 = -.infinity
        private(set) var loudestDisplay: Float32 = -.infinity

        var nearfieldLevel: Float32 { routerDecibels + displayDecibels }

        func step(_ name: String, _ work: () -> Void = {}) throws {
            events.append(name)
            if failing == name { throw NearfieldError.notEnoughStudioDisplays(1) }
            work()
            if routerIsDefault { loudestNearfield = max(loudestNearfield, nearfieldLevel) }
            loudestDisplay = max(loudestDisplay, displayDecibels)
        }

        func makeActivation() -> RouterOutputActivation {
            RouterOutputActivation(operations: .init(
                currentRouterVolume: { 0.5 },
                captureDisplays: { try self.step("capture"); return 0.4 },
                setRouterVolume: { _, _ in try self.step("volume") },
                selectRouter: { try self.step("select") { self.routerIsDefault = true } },
                displaysWithOtherPlayback: { uids in self.otherPlayback.intersection(uids) },
                displayRaiseDecibels: { _ in -self.displayDecibels },
                shiftRouterVolume: { decibels in
                    let before = self.routerDecibels
                    try self.step("shift") { self.routerDecibels = min(max(before + decibels, -63.5), 0) }
                    return self.routerDecibels - before
                },
                raiseDisplays: { try self.step("raise") { self.displayDecibels = 0 } },
                restoreDisplays: { try self.step("restore") { self.displayDecibels = -30 } },
                routerIsDefault: { self.routerIsDefault },
                applyBalance: { try self.step("balance") },
                saveWaitingCompensation: { self.savedCompensation = $0 }
            ))
        }
    }

    func testDisplaysAreRaisedOnlyAfterNearfieldIsSelected() throws {
        let displays = Displays()
        let activation = displays.makeActivation()

        try activation.activate(displayUIDs: ["left", "right"])

        XCTAssertEqual(displays.events, ["capture", "volume", "select", "raise"])
        XCTAssertEqual(activation.preparedDisplayUIDs, ["left", "right"])
        XCTAssertNil(activation.waitingDisplayUIDs)
    }

    func testFailedSelectionLeavesTheDisplaysAsTheyWere() {
        let displays = Displays()
        displays.failing = "select"
        let activation = displays.makeActivation()

        XCTAssertThrowsError(try activation.activate(displayUIDs: ["left", "right"]))

        XCTAssertEqual(displays.events, ["capture", "volume", "select", "restore"])
        XCTAssertEqual(displays.displayDecibels, -30)
        XCTAssertNil(activation.preparedDisplayUIDs)
    }

    func testFailedRaiseRestoresTheDisplays() {
        let displays = Displays()
        displays.failing = "raise"
        let activation = displays.makeActivation()

        XCTAssertThrowsError(try activation.activate(displayUIDs: ["left", "right"]))

        XCTAssertEqual(displays.events.last, "restore")
        XCTAssertNil(activation.preparedDisplayUIDs)
    }

    func testPreparedDisplaysOnlyGetTheBalance() throws {
        let displays = Displays()
        let activation = displays.makeActivation()
        try activation.activate(displayUIDs: ["left", "right"])
        displays.events = []

        try activation.activateIfNeeded(displayUIDs: ["left", "right"])

        XCTAssertEqual(displays.events, ["balance"])
    }

    /// Enabling app routing restores the displays, then configures Nearfield
    /// again: the displays must be raised again, not skipped as prepared.
    func testRestoredDisplaysArePreparedAgain() throws {
        let displays = Displays()
        let activation = displays.makeActivation()
        try activation.activate(displayUIDs: ["left", "right"])

        try activation.restoreDisplays()
        XCTAssertEqual(displays.displayDecibels, -30)
        displays.events = []
        try activation.activateIfNeeded(displayUIDs: ["left", "right"])

        XCTAssertEqual(displays.events, ["capture", "volume", "select", "raise"])
        XCTAssertEqual(displays.displayDecibels, 0)
    }

    func testOtherDisplaysOrAnotherOutputActivateAgain() throws {
        let displays = Displays()
        let activation = displays.makeActivation()
        try activation.activate(displayUIDs: ["left", "right"])
        displays.events = []

        try activation.activateIfNeeded(displayUIDs: ["left", "center", "right"])
        XCTAssertEqual(displays.events.last, "raise")

        displays.events = []
        displays.routerIsDefault = false
        try activation.activateIfNeeded(displayUIDs: ["left", "center", "right"])
        XCTAssertEqual(displays.events, ["capture", "volume", "select", "raise"])
    }

    /// An app set to play on a display directly must not get louder when
    /// Nearfield takes over; Nearfield makes up the difference instead.
    func testDisplayWithAnotherAppIsNotRaised() throws {
        let displays = Displays()
        displays.otherPlayback = ["left"]
        let activation = displays.makeActivation()

        try activation.activate(displayUIDs: ["left", "right"])

        XCTAssertFalse(displays.events.contains("raise"))
        XCTAssertEqual(displays.loudestDisplay, -30)
        XCTAssertEqual(activation.waitingDisplayUIDs, ["left", "right"])
        XCTAssertNil(activation.preparedDisplayUIDs)
        // Heard as if the displays were raised: -40 dB.
        XCTAssertEqual(displays.nearfieldLevel, -40)
        XCTAssertEqual(displays.savedCompensation, 30)
    }

    func testWaitingDisplaysAreRaisedWithoutGettingLouderOnceFree() throws {
        let displays = Displays()
        displays.otherPlayback = ["left"]
        let activation = displays.makeActivation()
        try activation.activate(displayUIDs: ["left", "right"])

        // Still in use: nothing changes.
        displays.events = []
        try activation.raiseWaitingDisplaysIfFree()
        try activation.activateIfNeeded(displayUIDs: ["left", "right"])
        XCTAssertEqual(displays.events, ["balance"])

        displays.otherPlayback = []
        displays.events = []
        try activation.raiseWaitingDisplaysIfFree()

        XCTAssertEqual(displays.events, ["shift", "raise"])
        XCTAssertEqual(displays.displayDecibels, 0)
        XCTAssertEqual(displays.nearfieldLevel, -40)
        XCTAssertLessThanOrEqual(displays.loudestNearfield, -40)
        XCTAssertEqual(activation.preparedDisplayUIDs, ["left", "right"])
        XCTAssertNil(activation.waitingDisplayUIDs)
        XCTAssertEqual(displays.savedCompensation, 0)
    }

    func testStoppingTheWaitTakesBackTheAddedVolume() throws {
        let displays = Displays()
        displays.otherPlayback = ["right"]
        let activation = displays.makeActivation()
        try activation.activate(displayUIDs: ["left", "right"])
        XCTAssertEqual(displays.routerDecibels, -10)

        activation.invalidate()

        XCTAssertEqual(displays.routerDecibels, -40)
        XCTAssertNil(activation.waitingDisplayUIDs)
        XCTAssertEqual(displays.savedCompensation, 0)
    }

    func testWaitEndsWhenNearfieldIsNoLongerTheOutput() throws {
        let displays = Displays()
        displays.otherPlayback = ["left"]
        let activation = displays.makeActivation()
        try activation.activate(displayUIDs: ["left", "right"])

        displays.routerIsDefault = false
        displays.otherPlayback = []
        try activation.raiseWaitingDisplaysIfFree()

        XCTAssertFalse(displays.events.contains("raise"))
        XCTAssertEqual(displays.routerDecibels, -40)
        XCTAssertNil(activation.waitingDisplayUIDs)
    }

    func testOnlyOtherAppsPlayingDirectlyCountAsUsingADisplay() {
        let targets: Set<String> = ["left", "right"]
        let driverHost = StudioDisplayAudioManager.driverServiceBundleID
        let playback: [RouterConnectionHandoff.Playback] = [
            .init(processID: 10, outputUIDs: ["left"], bundleID: "com.apple.Music"),
            .init(processID: 11, outputUIDs: [NearfieldAudioIdentifiers.routerDeviceUID]),
            // Nearfield's driver plays on the displays themselves.
            .init(processID: 12, outputUIDs: ["left", "right"], bundleID: driverHost),
            .init(processID: 13, outputUIDs: ["BuiltInSpeakerDevice"])
        ]

        XCTAssertEqual(StudioDisplayAudioManager.displaysWithOtherPlayback(targets, playback: playback, driverProcessID: 12), ["left"])
        XCTAssertTrue(StudioDisplayAudioManager.displaysWithOtherPlayback(
            targets, playback: Array(playback.dropFirst()), driverProcessID: 12
        ).isEmpty)
        // Another driver's host playing on a display is another app.
        let otherDriver = RouterConnectionHandoff.Playback(processID: 14, outputUIDs: ["right"], bundleID: driverHost)
        XCTAssertEqual(StudioDisplayAudioManager.displaysWithOtherPlayback(
            targets, playback: [playback[2], otherDriver], driverProcessID: 12
        ), ["right"])
        // Drivers before 1.1.0 do not report their process: driver hosts are skipped.
        XCTAssertTrue(StudioDisplayAudioManager.displaysWithOtherPlayback(
            targets, playback: [playback[2], otherDriver], driverProcessID: nil
        ).isEmpty)
    }

    /// Turning Nearfield down while waiting can leave too little room to lower
    /// it before raising the displays; then they keep waiting.
    func testDisplaysKeepWaitingWhenNearfieldCannotGoLowEnough() throws {
        let displays = Displays()
        displays.otherPlayback = ["left"]
        let activation = displays.makeActivation()
        try activation.activate(displayUIDs: ["left", "right"])
        displays.routerDecibels = -60

        displays.otherPlayback = []
        try activation.raiseWaitingDisplaysIfFree()

        XCTAssertFalse(displays.events.contains("raise"))
        XCTAssertEqual(displays.routerDecibels, -60)
        XCTAssertEqual(displays.displayDecibels, -30)
        XCTAssertEqual(activation.waitingDisplayUIDs, ["left", "right"])
    }

    func testFailedCompensationStillActivatesQuieter() throws {
        let displays = Displays()
        displays.otherPlayback = ["left"]
        displays.failing = "shift"
        let activation = displays.makeActivation()

        try activation.activate(displayUIDs: ["left", "right"])

        XCTAssertTrue(displays.routerIsDefault)
        XCTAssertEqual(activation.waitingDisplayUIDs, ["left", "right"])
        XCTAssertLessThanOrEqual(displays.loudestNearfield, -40)
        XCTAssertEqual(displays.displayDecibels, -30)
    }

    /// Nearfield's volume cannot go above 0 dB, so it may wait quieter than
    /// intended, and it stays on the quiet side after the raise.
    func testLimitedCompensationStaysOnTheQuietSide() throws {
        let displays = Displays()
        displays.routerDecibels = -10
        displays.otherPlayback = ["left"]
        let activation = displays.makeActivation()
        try activation.activate(displayUIDs: ["left", "right"])
        XCTAssertEqual(displays.routerDecibels, 0)

        displays.otherPlayback = []
        try activation.raiseWaitingDisplaysIfFree()

        XCTAssertLessThanOrEqual(displays.loudestNearfield, -10)
        XCTAssertEqual(displays.nearfieldLevel, -30)
    }
}
