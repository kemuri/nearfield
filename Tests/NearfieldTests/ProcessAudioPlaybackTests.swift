import CoreAudio
import XCTest
@testable import Nearfield

final class ProcessAudioPlaybackTests: XCTestCase {
    final class AudioProcesses {
        var running: Set<AudioObjectID> = [1, 2, 3]
        var pids: [AudioObjectID: Int32] = [1: 100, 2: 200, 3: 300]
        var devices: [AudioObjectID: [AudioObjectID]] = [1: [10], 2: [10], 3: [20, 30]]
        var uids: [AudioObjectID: String] = [10: "macbook", 20: "left-display", 30: "right-display"]

        var properties: ProcessAudioPlayback.Properties {
            .init(processObjects: { [1, 2, 3] },
                  outputIsRunning: { self.running.contains($0) },
                  processID: { self.pids[$0] },
                  outputDevices: { self.devices[$0] ?? [] },
                  deviceUID: { self.uids[$0] })
        }
    }

    func testAllActiveOutputProcessesAreCollectedWithoutAppIdentity() {
        let processes = AudioProcesses()
        XCTAssertEqual(ProcessAudioPlayback.activeOutputs(using: processes.properties, excludingProcessID: 999), [
            .init(processID: 100, outputUIDs: ["macbook"]),
            .init(processID: 200, outputUIDs: ["macbook"]),
            .init(processID: 300, outputUIDs: ["left-display", "right-display"])
        ])
    }

    func testInactiveAndOwnPlaybackAreExcluded() {
        let processes = AudioProcesses()
        processes.running.remove(1)
        XCTAssertEqual(ProcessAudioPlayback.activeOutputs(using: processes.properties, excludingProcessID: 200), [
            .init(processID: 300, outputUIDs: ["left-display", "right-display"])
        ])
    }

    func testDisappearingProcessesAndIncompleteDeviceReadsAreIgnored() {
        let processes = AudioProcesses()
        processes.pids.removeValue(forKey: 1)
        processes.devices[2] = []
        processes.uids.removeValue(forKey: 30)
        XCTAssertEqual(ProcessAudioPlayback.activeOutputs(using: processes.properties, excludingProcessID: 999), [])
    }

    @MainActor
    func testProcessWithoutBundleIdentityTriggersTheActualHandoff() async throws {
        let processes = AudioProcesses()
        let audio = RouterConnectionHandoffTests.AudioSession()
        audio.playback = ProcessAudioPlayback.activeOutputs(using: processes.properties, excludingProcessID: 999)
        try await audio.handoff.run(audio.environment)
        XCTAssertEqual(audio.selections, ["nearfield", "macbook", "nearfield"])
        XCTAssertEqual(audio.playback.filter { $0.outputUIDs == ["nearfield"] }.map(\.processID), [100, 200])
        XCTAssertEqual(audio.playback.last?.outputUIDs, ["left-display", "right-display"])
    }

    func testLiveProcessWithoutAppBundleIsObserved() throws {
        guard ProcessInfo.processInfo.environment["NEARFIELD_TEST_LIVE_AUDIO"] == "1" else {
            throw XCTSkip("Opt-in host audio check: NEARFIELD_TEST_LIVE_AUDIO=1")
        }
        guard ProcessAudioPlayback.isSupported else { throw XCTSkip("Requires macOS 14.2") }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        // Exercise live output IO without producing audible sound or changing devices.
        player.arguments = ["-v", "0", "-r", "0.1", "/System/Library/Sounds/Glass.aiff"]
        try player.run()
        defer {
            if player.isRunning { player.terminate() }
            player.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(4)
        repeat {
            if let playback = ProcessAudioPlayback.activeOutputs().first(where: { $0.processID == player.processIdentifier }) {
                XCTAssertFalse(playback.outputUIDs.isEmpty)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline && player.isRunning
        XCTFail("The live audio process was not detected")
    }
}
