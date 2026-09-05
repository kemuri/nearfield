import CoreGraphics
import Foundation
import XCTest
@testable import Nearfield

final class AudioReliabilityTests: XCTestCase {
    func testVolumeRoundTripThroughZeroPreservesSavedBalance() {
        for balance: Float32 in [-1, -0.5, 0, 0.5, 1] {
            let initial = BalanceMath.channelVolumes(currentLeft: 0.5, currentRight: 0.5, balance: balance)
            let silent = BalanceMath.adjustedChannelVolumes(
                currentLeft: initial.left, currentRight: initial.right, delta: -1, balance: balance
            )
            XCTAssertEqual(silent.left, 0)
            XCTAssertEqual(silent.right, 0)
            let restored = BalanceMath.adjustedChannelVolumes(
                currentLeft: silent.left, currentRight: silent.right, delta: 0.5, balance: balance
            )
            XCTAssertEqual(restored.left, initial.left, accuracy: 0.0001)
            XCTAssertEqual(restored.right, initial.right, accuracy: 0.0001)
        }
    }

    func testReapplyingBalanceUsesTheLatestMasterVolume() {
        // Display reassignment reapplies balance after the driver rebuilds.
        // A volume change during that delay must remain authoritative.
        let latest = BalanceMath.adjustedChannelVolumes(
            currentLeft: 0.8, currentRight: 0.4, delta: -0.3, balance: -0.5
        )
        let reapplied = BalanceMath.channelVolumes(
            currentLeft: latest.left, currentRight: latest.right, balance: -0.5
        )
        XCTAssertEqual(reapplied.left, 0.5, accuracy: 0.0001)
        XCTAssertEqual(reapplied.right, 0.25, accuracy: 0.0001)
    }

    func testMaintenanceStopsOnFileOperationFailureDespiteToleratedRestart() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", DriverInstaller.maintenanceShellCommand("""
            /usr/bin/true
            /usr/bin/false
            /usr/bin/false || true
            """)]
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
    }

    func testMaintenanceAllowsExplicitlyToleratedRestartFailure() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", DriverInstaller.maintenanceShellCommand("""
            /usr/bin/false || true
            /usr/bin/true
            /usr/bin/false || true
            """)]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testDriverRemovalVerificationRejectsRemainingBundle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try DriverInstaller.verifyDriverRemoval(paths: [directory.path]))
        XCTAssertNoThrow(try DriverInstaller.verifyDriverRemoval(paths: [directory.appendingPathComponent("missing").path]))
    }

    @MainActor
    func testWindowRoutingSharesOneSnapshotAcrossWindowsAndHelperAliases() {
        var appReads = 0
        var windowReads = 0
        var targetReads = 0
        var firstWindowX: CGFloat = 10
        let resolver = WindowAudioRouteResolver(
            runningApplications: {
                appReads += 1
                return [.init(bundleID: "app.one", processID: 101), .init(bundleID: "app.two", processID: 102)]
            },
            windowList: {
                windowReads += 1
                return [
                    Self.window(pid: 101, x: firstWindowX, size: 150),
                    Self.window(pid: 101, x: 510, size: 100),
                    Self.window(pid: 102, x: 510, size: 150)
                ]
            },
            displayTargets: {
                targetReads += 1
                return [
                    .init(route: "left", bounds: CGRect(x: 0, y: 0, width: 500, height: 500)),
                    .init(route: "right", bounds: CGRect(x: 500, y: 0, width: 500, height: 500))
                ]
            }
        )
        let rules = "app.one=window; helper.one=window:app.one; app.two=window"
        let resolved = resolver.resolvedRules(from: rules)
        XCTAssertTrue(resolved.contains("pid:101=left; app.one=left"))
        XCTAssertTrue(resolved.contains("pid:101=left; helper.one=left"))
        XCTAssertTrue(resolved.contains("pid:102=right; app.two=right"))
        XCTAssertEqual(appReads, 1)
        XCTAssertEqual(windowReads, 1)
        XCTAssertEqual(targetReads, 1)

        firstWindowX = 510
        let channels = resolver.currentRoutes(for: [
            .init(bundleIdentifier: "app.one", routingBundleIdentifiers: ["helper.one"]),
            .init(bundleIdentifier: "app.two", routingBundleIdentifiers: [])
        ], rawRules: rules)
        XCTAssertEqual(channels, ["app.one": "right", "app.two": "right"])
        XCTAssertEqual(appReads, 2)
        XCTAssertEqual(windowReads, 2)
        XCTAssertEqual(targetReads, 2)
    }

    @MainActor
    func testFixedAndStoppedAppRoutesDoNotScanWindows() {
        let resolver = WindowAudioRouteResolver(
            runningApplications: { [.init(bundleID: "app.running", processID: 101)] },
            windowList: { XCTFail("Unexpected window scan"); return [] },
            displayTargets: { XCTFail("Unexpected display scan"); return [] }
        )
        XCTAssertEqual(resolver.resolvedRules(from: "app.running=left; app.stopped=window"),
                       "app.running=left; app.stopped=pair")
        XCTAssertEqual(resolver.currentRoutes(for: [
            .init(bundleIdentifier: "app.running", routingBundleIdentifiers: []),
            .init(bundleIdentifier: "app.stopped", routingBundleIdentifiers: [])
        ], rawRules: "app.running=left; app.stopped=window"), ["app.running": "left"])
    }

    private static func window(pid: Int32, x: CGFloat, size: CGFloat) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowAlpha as String: NSNumber(value: 1),
            kCGWindowBounds as String: CGRect(x: x, y: 0, width: size, height: size).dictionaryRepresentation
        ]
    }
}
