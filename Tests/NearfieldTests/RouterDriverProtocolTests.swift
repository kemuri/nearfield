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

final class WindowRouteFollowerTests: XCTestCase {
    @MainActor final class Published {
        var rules: [String] = []
    }

    func testPublishesOnlyWhenResolvedRulesChange() async throws {
        let published = await Published()
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

        let rules = await published.rules
        XCTAssertEqual(rules, ["com.apple.Safari=left", "com.apple.Safari=right"])
    }

    func testChecksNothingWhileStopped() async throws {
        let published = await Published()
        let follower = WindowRouteFollower { rules in published.rules.append(rules) }
        follower.update(runningApplications: [], displayTargets: [], rawRules: "com.apple.Safari=left")
        follower.checkNow()
        try await Task.sleep(nanoseconds: 100_000_000)

        let rules = await published.rules
        XCTAssertTrue(rules.isEmpty)
    }

    private func waitForPublished(_ published: Published, count: Int) async throws {
        for _ in 0..<200 {
            if await published.rules.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Expected \(count) published rule sets.")
    }
}
