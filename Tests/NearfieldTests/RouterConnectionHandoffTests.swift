import XCTest
@testable import Nearfield

@MainActor
final class RouterConnectionHandoffTests: XCTestCase {
    @MainActor final class AudioSession {
        var now: TimeInterval = 0
        var readyAt: TimeInterval = 0
        var connected = true
        var output = "macbook"
        var playback: [RouterConnectionHandoff.Playback] = []
        var selections: [String] = []
        var activationTimes: [TimeInterval] = []
        var preparationCount = 0
        var recoveryWorks = true
        var afterSleep: (() -> Void)?
        let handoff = RouterConnectionHandoff(previousOutputUID: "macbook", initialDefaultUID: "macbook", routerUID: "nearfield")

        func play(on output: String) {
            playback = [.init(processID: 42, outputUIDs: [output])]
        }

        func choose(_ output: String) {
            self.output = output
            handoff.observeDefaultOutput(output)
        }

        var environment: RouterConnectionHandoff.Environment {
            .init(
                snapshot: { .init(displaysConnected: self.connected, targetReady: self.now >= self.readyAt,
                                  defaultOutputUID: self.output, playback: self.playback) },
                prepare: { self.preparationCount += 1 },
                activate: {
                    self.output = "nearfield"
                    self.selections.append(self.output)
                    self.activationTimes.append(self.now)
                    if self.activationTimes.count == 2 && self.recoveryWorks {
                        self.playback = self.playback.map {
                            .init(processID: $0.processID, outputUIDs: $0.outputUIDs == ["macbook"] ? ["nearfield"] : $0.outputUIDs)
                        }
                    }
                    self.handoff.observeDefaultOutput(self.output)
                },
                selectPreviousOutput: {
                    self.output = "macbook"
                    self.selections.append(self.output)
                    self.handoff.observeDefaultOutput(self.output)
                },
                now: { self.now },
                sleep: { nanoseconds in
                    self.now += Double(nanoseconds) / 1_000_000_000
                    self.afterSleep?()
                    // A broken endless retry should fail instead of hanging the suite.
                    if self.now > 600 { throw RouterConnectionHandoff.Failure.playbackDidNotFollow }
                }
            )
        }
    }

    func testSilentAppStartsOnMacBookEightMinutesAfterConnectionAndIsRecoveredOnce() async throws {
        let audio = AudioSession()
        audio.readyAt = 2
        audio.afterSleep = {
            if audio.now >= 480 && audio.playback.isEmpty { audio.play(on: "macbook") }
        }
        try await audio.handoff.run(audio.environment)
        XCTAssertEqual(audio.preparationCount, 1)
        XCTAssertGreaterThanOrEqual(audio.activationTimes[0], 2)
        XCTAssertGreaterThanOrEqual(audio.activationTimes[1], 480)
        XCTAssertEqual(audio.selections, ["nearfield", "macbook", "nearfield"])
        XCTAssertEqual(audio.playback.first?.outputUIDs, ["nearfield"])
    }

    func testLaterAppIsRecoveredAfterAnotherAppAlreadyReachedNearfield() async throws {
        let audio = AudioSession()
        audio.play(on: "nearfield")
        audio.afterSleep = {
            if audio.now >= 30 && audio.playback.count == 1 {
                audio.playback.append(.init(processID: 84, outputUIDs: ["macbook"]))
            }
        }
        try await audio.handoff.run(audio.environment)
        XCTAssertEqual(audio.selections, ["nearfield", "macbook", "nearfield"])
        XCTAssertGreaterThanOrEqual(audio.now, 30)
        XCTAssertEqual(audio.playback, [.init(processID: 42, outputUIDs: ["nearfield"]),
                                        .init(processID: 84, outputUIDs: ["nearfield"])])
    }

    func testReadyRouteAndCorrectPlaybackDoNotBounceOutput() async {
        let audio = AudioSession()
        audio.afterSleep = {
            audio.play(on: "nearfield")
            if audio.now > 10 { audio.choose("headphones") }
        }
        do { try await audio.handoff.run(audio.environment); XCTFail("Should monitor until cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(audio.selections, ["nearfield"])
    }

    func testNormalAsynchronousClientSwitchDoesNotTriggerRecovery() async {
        let audio = AudioSession()
        audio.play(on: "macbook")
        audio.afterSleep = {
            if audio.now > 1 { audio.play(on: "nearfield") }
            if audio.now > 10 { audio.choose("headphones") }
        }
        do { try await audio.handoff.run(audio.environment); XCTFail("Should monitor until cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(audio.selections, ["nearfield"])
    }

    func testPlaybackOnUnrelatedOrMultipleOutputsDoesNotTriggerRecovery() async {
        let audio = AudioSession()
        audio.playback = [
            .init(processID: 10, outputUIDs: ["headphones"]),
            .init(processID: 20, outputUIDs: ["left-display", "right-display"]),
            .init(processID: 30, outputUIDs: ["nearfield"]),
            .init(processID: 40, outputUIDs: ["macbook", "headphones"])
        ]
        audio.afterSleep = { if audio.now > 10 { audio.choose("headphones") } }
        do { try await audio.handoff.run(audio.environment); XCTFail("Should monitor until cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(audio.selections, ["nearfield"])
    }

    func testMultipleStaleAppsShareOneRecoveryAttempt() async throws {
        let audio = AudioSession()
        audio.playback = [.init(processID: 42, outputUIDs: ["macbook"]),
                          .init(processID: 84, outputUIDs: ["macbook"])]
        try await audio.handoff.run(audio.environment)
        XCTAssertEqual(audio.selections, ["nearfield", "macbook", "nearfield"])
        XCTAssertTrue(audio.playback.allSatisfy { $0.outputUIDs == ["nearfield"] })
    }

    func testManualChoiceWhileWaitingForReadinessCancelsActivation() async {
        let audio = AudioSession()
        audio.readyAt = 2
        audio.afterSleep = { audio.choose("headphones") }
        do { try await audio.handoff.run(audio.environment); XCTFail("Should cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(audio.selections.isEmpty)
        XCTAssertEqual(audio.output, "headphones")
    }

    func testManualChoiceDuringRecoveryIsNeverOverwritten() async {
        let audio = AudioSession()
        audio.play(on: "macbook")
        audio.afterSleep = { if audio.selections.count == 2 { audio.choose("headphones") } }
        do { try await audio.handoff.run(audio.environment); XCTFail("Should cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(audio.selections, ["nearfield", "macbook"])
        XCTAssertEqual(audio.output, "headphones")
    }

    func testManualChoiceDuringSilentMonitoringCancelsLateRecovery() async {
        let audio = AudioSession()
        audio.afterSleep = { if audio.now > 30 { audio.choose("macbook"); audio.play(on: "macbook") } }
        do { try await audio.handoff.run(audio.environment); XCTFail("Should cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(audio.selections, ["nearfield"])
        XCTAssertEqual(audio.output, "macbook")
    }

    func testDisconnectDuringRecoveryDoesNotRestoreNearfield() async {
        let audio = AudioSession()
        audio.play(on: "macbook")
        audio.afterSleep = { if audio.selections.count == 2 { audio.connected = false } }
        do { try await audio.handoff.run(audio.environment); XCTFail("Should cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(audio.selections, ["nearfield", "macbook"])
    }

    func testReadinessTimeoutLeavesPreviousOutputSelected() async {
        let audio = AudioSession()
        audio.readyAt = 60
        do { try await audio.handoff.run(audio.environment); XCTFail("Should time out") }
        catch { XCTAssertEqual(error as? RouterConnectionHandoff.Failure, .targetNotReady) }
        XCTAssertTrue(audio.selections.isEmpty)
        XCTAssertEqual(audio.output, "macbook")
    }

    func testFailedRecoveryReportsFailureWithoutRepeatedSwitches() async {
        let audio = AudioSession()
        audio.recoveryWorks = false
        audio.play(on: "macbook")
        do { try await audio.handoff.run(audio.environment); XCTFail("Should fail") }
        catch { XCTAssertEqual(error as? RouterConnectionHandoff.Failure, .playbackDidNotFollow) }
        XCTAssertEqual(audio.selections, ["nearfield", "macbook", "nearfield"])
    }

    func testLateDriverLoadingIsRetriedBeforeActivation() async throws {
        let audio = AudioSession()
        var environment = audio.environment
        environment.prepare = {
            if audio.now < 1 { throw RouterAudioDriverError.notInstalled }
        }
        environment.supportsPlaybackVerification = false
        try await audio.handoff.run(environment)
        XCTAssertGreaterThanOrEqual(audio.activationTimes[0], 1)
    }

    func testReadinessRequiresExactTargetsOrderAndMode() {
        let status = "ready\nstereo\nleft\nright"
        XCTAssertTrue(RouterAudioDriverManager.readinessMatches(status, deviceUIDs: ["left", "right"], mode: .stereo))
        for invalid in [nil, "pending", "ready", "ready\nstereo\nmacbook\nright", "ready\nstereo\nright\nleft"] {
            XCTAssertFalse(RouterAudioDriverManager.readinessMatches(invalid, deviceUIDs: ["left", "right"], mode: .stereo))
        }
        XCTAssertFalse(RouterAudioDriverManager.readinessMatches(status, deviceUIDs: ["left", "right"], mode: .mono))
    }
}
