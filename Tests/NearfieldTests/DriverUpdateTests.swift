import Foundation
import XCTest
@testable import Nearfield

final class DriverUpdateTests: XCTestCase {
    func testNumericVersionsCompareComponentsAndNeverUseLexicalOrder() throws {
        XCTAssertGreaterThan(try XCTUnwrap(RouterDriverVersion("1.0.10")),
                             try XCTUnwrap(RouterDriverVersion("1.0.9")))
        XCTAssertEqual(RouterDriverVersion("2"), RouterDriverVersion("2.0.0"))
        XCTAssertEqual(RouterDriverVersion("1.08"), RouterDriverVersion("1.8.0"))
        for invalid in ["", "1..2", "1.2.3.4", "1.2b1", "-1", " 1", "$(CURRENT_PROJECT_VERSION)"] {
            XCTAssertNil(RouterDriverVersion(invalid), invalid)
        }
    }

    func testOlderInstalledDriverOffersBundledUpgradeWithoutBecomingMissing() throws {
        let fixture = try DriverFixture(installedVersion: "1.0.7", bundledVersion: "1.0.8")
        let update = try XCTUnwrap(fixture.update())
        XCTAssertEqual(update.installedVersion, "1.0.7")
        XCTAssertEqual(update.availableVersion, "1.0.8")
        XCTAssertEqual(update.bundledDriverURL, fixture.bundledURL)
        XCTAssertTrue(DriverInstaller.routerDriverDiskState(in: fixture.installedDirectory).isCurrent)
    }

    func testEqualAndNewerInstalledDriversAreNotOfferedAnUpgradeOrDowngrade() throws {
        for installedVersion in ["1.0.8", "1.0.9", "1.0.10", "2"] {
            let fixture = try DriverFixture(installedVersion: installedVersion, bundledVersion: "1.0.8")
            XCTAssertNil(fixture.update(), installedVersion)
        }
    }

    func testUnknownInstalledVersionCanUpgradeButUnknownBundledVersionCannot() throws {
        for installedVersion in [nil, "invalid"] as [String?] {
            let fixture = try DriverFixture(installedVersion: installedVersion, bundledVersion: "1.0.8")
            XCTAssertNotNil(fixture.update())
        }
        for bundledVersion in [nil, "$(CURRENT_PROJECT_VERSION)"] as [String?] {
            let fixture = try DriverFixture(installedVersion: "1.0.7", bundledVersion: bundledVersion)
            XCTAssertNil(fixture.update())
        }
    }

    func testMissingAndInvalidDriverBundlesStayInInstallationFlow() throws {
        let fixture = try DriverFixture(installedVersion: "1.0.7", bundledVersion: "1.0.8")
        try FileManager.default.removeItem(at: fixture.installedURL)
        XCTAssertNil(fixture.update())
        try fixture.writeBundle(at: fixture.installedURL, version: "1.0.7", identifier: "com.example.WrongDriver")
        XCTAssertNil(fixture.update())
        try fixture.writeBundle(at: fixture.installedURL, version: "1.0.7")
        try fixture.writeBundle(at: fixture.bundledURL, version: "1.0.8", identifier: "com.example.WrongDriver")
        XCTAssertNil(fixture.update())
        try FileManager.default.removeItem(at: fixture.bundledURL)
        XCTAssertNil(fixture.update())
    }

    func testReplacementAtSamePathClearsUpgradeOnlyAfterVersionMatches() throws {
        let fixture = try DriverFixture(installedVersion: "1.0.7", bundledVersion: "1.0.8")
        XCTAssertNotNil(fixture.update())
        XCTAssertThrowsError(try DriverInstaller.verifyInstalledDriverVersion("1.0.8", in: fixture.installedDirectory))
        // Model the privileged install replacing the bundle at its existing path.
        try FileManager.default.removeItem(at: fixture.installedURL)
        try FileManager.default.copyItem(at: fixture.bundledURL, to: fixture.installedURL)
        XCTAssertNil(fixture.update())
        XCTAssertNoThrow(try DriverInstaller.verifyInstalledDriverVersion("1.0.8", in: fixture.installedDirectory))
        try FileManager.default.removeItem(at: fixture.installedURL)
        XCTAssertThrowsError(try DriverInstaller.verifyInstalledDriverVersion("1.0.8", in: fixture.installedDirectory))
    }

    func testUpgradeRequestPreservesRoutingOnCancellationAndDoesNotRequireDisplays() {
        let request = DriverInstallRequest.driverUpgrade
        XCTAssertTrue(request.requiresConfirmation)
        XCTAssertTrue(request.presentsErrors)
        XCTAssertTrue(request.allowsMissingStudioDisplays)
        XCTAssertFalse(request.disablesAppRoutingOnFailure)
    }
}

private final class DriverFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearfieldDriverUpdate-\(UUID().uuidString)")
    var installedDirectory: URL { root.appendingPathComponent("HAL") }
    var installedURL: URL { installedDirectory.appendingPathComponent("NearfieldAudioDevice.driver") }
    var bundledURL: URL { root.appendingPathComponent("App/Contents/Resources/Drivers/NearfieldAudioDevice.driver") }

    init(installedVersion: String?, bundledVersion: String?) throws {
        try writeBundle(at: installedURL, version: installedVersion)
        try writeBundle(at: bundledURL, version: bundledVersion)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func update() -> RouterDriverUpdate? {
        DriverInstaller.availableDriverUpdate(in: installedDirectory, bundledDriverURL: bundledURL)
    }

    func writeBundle(at url: URL, version: String?, identifier: String = "com.kemuri.Nearfield.AudioDevice") throws {
        let executable = url.appendingPathComponent("Contents/MacOS/NearfieldAudioDevice")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var info = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "NearfieldAudioDevice"]
        info["CFBundleVersion"] = version
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
}
