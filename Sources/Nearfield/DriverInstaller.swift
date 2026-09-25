import Foundation
import Security

enum RouterDriverDiskState: Equatable {
    case missing
    case current
    case legacy
    case invalidCurrent

    var isCurrent: Bool {
        self == .current
    }
}

enum DriverInstallerError: LocalizedError, Equatable {
    case scriptNotFound(String)
    case driverBuildFailed(String)
    case driverBuildTimedOut
    case driverBundleMissing(String)
    case invalidDriverBundle(String)
    case authorizationCancelled
    case installFailed(String)
    case installedVersionMismatch(expected: String, actual: String?)
    case untrustedDriverSignature(String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound(let path):
            return "Could not find script at \(path)."
        case .driverBuildFailed(let output):
            return "Driver build failed.\n\n\(output)"
        case .driverBuildTimedOut:
            return "Driver build timed out."
        case .driverBundleMissing(let path):
            return "Could not find router driver bundle at \(path)."
        case .invalidDriverBundle(let path):
            return "Refusing to install unexpected driver bundle at \(path)."
        case .authorizationCancelled:
            return "Administrator approval was cancelled."
        case .installFailed(let output):
            return "Driver install failed.\n\n\(output)"
        case .installedVersionMismatch(let expected, let actual):
            return "The audio driver update could not be verified. Expected version \(expected), found \(actual ?? "an unknown version"). Try updating the driver again in Settings."
        case .untrustedDriverSignature(let path):
            return "The audio driver at \(path) is not signed by Nearfield's developer. Download Nearfield again from trynearfield.com."
        }
    }
}

final class DriverInstaller {
    private static let halDriverDirectory = "/Library/Audio/Plug-Ins/HAL"
    private static let routerDriverBundleName = "NearfieldAudioDevice.driver"
    // Set by script/build_router_driver.sh via PRODUCT_BUNDLE_IDENTIFIER.
    private static let routerDriverBundleIdentifier = "com.kemuri.Nearfield.AudioDevice"
    private static let legacyRouterDriverBundleName = "StudioPairRouterAudioDevice.driver"
    private static let legacyProxyDriverBundleName = "ProxyAudioDevice.driver"
    private static let driverServiceHelperName = "com.apple.audio.Core-Audio-Driver-Service.helper"

    /// Admin tasks (install, update, uninstall) run one at a time, off the
    /// main thread.
    private static let privilegedQueue = DispatchQueue(
        label: "com.kemuri.Nearfield.privileged-driver-tasks",
        qos: .userInitiated
    )

    static func runPrivilegedTask(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            privilegedQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Legacy bundles in the HAL folder that belong to Nearfield. Another
    /// product's ProxyAudioDevice.driver (the open-source project Nearfield's
    /// driver started from) is left alone.
    private static func legacyRouterDriverBundleNames(
        in directoryURL: URL = URL(fileURLWithPath: halDriverDirectory, isDirectory: true)
    ) -> [String] {
        var names = [legacyRouterDriverBundleName]
        if isNearfieldLegacyDriver(at: directoryURL.appendingPathComponent(legacyProxyDriverBundleName, isDirectory: true)) {
            names.append(legacyProxyDriverBundleName)
        }
        return names
    }

    private static func routerDriverBundleNames(
        in directoryURL: URL = URL(fileURLWithPath: halDriverDirectory, isDirectory: true)
    ) -> [String] {
        [routerDriverBundleName] + legacyRouterDriverBundleNames(in: directoryURL)
    }

    static func isNearfieldLegacyDriver(at bundleURL: URL, fileManager: FileManager = .default) -> Bool {
        let infoURL = bundleURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = fileManager.contents(atPath: infoURL.path),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        if let identifier = info["CFBundleIdentifier"] as? String, identifier.hasPrefix("com.kemuri.") {
            return true
        }
        // Older builds kept the upstream identifier; their binary still names Nearfield.
        guard let executable = info["CFBundleExecutable"] as? String,
              isSafeBundleExecutableName(executable),
              let binary = fileManager.contents(
                atPath: bundleURL.appendingPathComponent("Contents/MacOS/\(executable)").path
              ) else {
            return false
        }
        return ["com.kemuri.", "StudioPair", "NearfieldAudio"].contains { marker in
            binary.range(of: Data(marker.utf8)) != nil
        }
    }

    func buildRouterDriver() throws -> String {
        // Distribution builds install only the driver shipped inside the app
        // bundle. Building from a discovered source tree would let anything
        // that controls the working directory (or a parent of it) hand us a
        // bundle that we then ad-hoc sign and load as root.
        if BuildConfiguration.isDistribution {
            guard let bundledDriverPath = try bundledRouterDriverPath() else {
                throw DriverInstallerError.driverBundleMissing(
                    "Drivers/\(Self.routerDriverBundleName) inside Nearfield.app"
                )
            }
            return bundledDriverPath
        }

        if sourceBuildScriptPathIfAvailable() != nil {
            return try buildRouterDriverFromSource()
        }
        if let bundledDriverPath = try bundledRouterDriverPath() {
            return bundledDriverPath
        }

        return try buildRouterDriverFromSource()
    }

    func installBuiltRouterDriver(at driverPath: String) throws {
        let sourcePath = try validatedDriverBundlePath(driverPath)
        let destinationPath = "\(Self.halDriverDirectory)/\(Self.routerDriverBundleName)"
        let temporaryPath = "\(destinationPath).nearfield-installing"
        let cleanupPaths = installCleanupPaths(temporaryPath: temporaryPath)
        // Distribution builds install the Developer ID signed driver as
        // shipped, after checking its signature, and check the root-owned
        // copy again before it goes live. Development builds sign ad hoc.
        let requirement = BuildConfiguration.isDistribution ? try Self.bundledDriverRequirement() : nil
        if let requirement {
            try Self.verifySignature(atPath: sourcePath, requirement: requirement)
        }
        let signingCommand = requirement.map {
            "/usr/bin/codesign --verify --deep --strict -R \(shellQuoted("=" + $0)) \(shellQuoted(temporaryPath))"
        } ?? "/usr/bin/codesign --force --deep --sign - \(shellQuoted(temporaryPath))"
        let command = [
            "/bin/mkdir -p \(shellQuoted(Self.halDriverDirectory))",
            driverServiceRestartCommand(),
            removeCommand(paths: cleanupPaths),
            "/usr/bin/ditto \(shellQuoted(sourcePath)) \(shellQuoted(temporaryPath))",
            "/usr/bin/xattr -cr \(shellQuoted(temporaryPath)) || true",
            "/usr/sbin/chown -R root:wheel \(shellQuoted(temporaryPath))",
            signingCommand,
            "/usr/bin/xattr -cr \(shellQuoted(temporaryPath)) || true",
            removeCommand(paths: installedRouterDriverPaths()),
            "/bin/mv \(shellQuoted(temporaryPath)) \(shellQuoted(destinationPath))",
            "/usr/bin/xattr -cr \(shellQuoted(destinationPath)) || true",
            coreAudioRestartCommand()
        ].joined(separator: "\n")
        try runPrivilegedShell(command)
    }

    /// The code requirement for the bundled driver: Nearfield's driver
    /// identifier, signed with Developer ID by the same team as this app.
    static func bundledDriverRequirement() throws -> String {
        guard let team = currentTeamIdentifier() else {
            throw DriverInstallerError.untrustedDriverSignature("Nearfield.app")
        }
        return driverRequirement(teamIdentifier: team)
    }

    static func driverRequirement(teamIdentifier: String) -> String {
        "anchor apple generic and identifier \"\(routerDriverBundleIdentifier)\" and " +
            "certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    static func verifySignature(atPath path: String, requirement requirementText: String) throws {
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw DriverInstallerError.untrustedDriverSignature(path)
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw DriverInstallerError.untrustedDriverSignature(path)
        }
    }

    private static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else {
            return nil
        }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }

    func removeAllInstalledDriversAndRestartCoreAudio() throws {
        let command = [
            driverServiceRestartCommand(),
            removeCommand(paths: Self.installedDriverRemovalPaths()),
            coreAudioRestartCommand()
        ].joined(separator: "\n")
        try runPrivilegedShell(command)
        try Self.verifyDriverRemoval(paths: Self.installedDriverRemovalPaths())
    }

    static func verifyDriverRemoval(paths: [String], fileManager: FileManager = .default) throws {
        if let remainingPath = paths.first(where: { fileManager.fileExists(atPath: $0) }) {
            throw DriverInstallerError.installFailed("Driver removal did not remove \(remainingPath).")
        }
    }

    static func driverPath(fromBuildOutput output: String, expectedSuffix: String = routerDriverBundleName) throws -> String {
        guard let driverPath = output
            .split(whereSeparator: \.isNewline)
            .map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
            .last(where: { !$0.isEmpty && $0.hasSuffix(expectedSuffix) }) else {
            throw DriverInstallerError.driverBundleMissing(output)
        }
        return driverPath
    }

    static func privilegedInstallError(
        errorNumber: Int?,
        message: String
    ) -> DriverInstallerError {
        if errorNumber == -128 {
            // AppleScript reports user-cancelled authorization as userCanceledErr.
            return .authorizationCancelled
        }
        return .installFailed(message)
    }

    /// Nearfield's bundles in the HAL folder, plus the staging copies its
    /// installers leave behind (those suffixes are only ever Nearfield's).
    static func installedDriverRemovalPaths(
        in directoryURL: URL = URL(fileURLWithPath: halDriverDirectory, isDirectory: true)
    ) -> [String] {
        let directory = directoryURL.path
        let ownedNames = Set(routerDriverBundleNames(in: directoryURL))
        return [routerDriverBundleName, legacyRouterDriverBundleName, legacyProxyDriverBundleName]
            .map { bundleName in (bundleName, "\(directory)/\(bundleName)") }
            .flatMap { bundleName, driverPath in
                [
                    "\(driverPath).studiopair-installing",
                    "\(driverPath).nearfield-installing"
                ] + (ownedNames.contains(bundleName) ? [driverPath] : [])
            }
    }

    static func routerDriverDiskState(
        in directoryURL: URL = URL(fileURLWithPath: halDriverDirectory, isDirectory: true),
        fileManager: FileManager = .default
    ) -> RouterDriverDiskState {
        let currentDriverURL = directoryURL.appendingPathComponent(
            routerDriverBundleName,
            isDirectory: true
        )
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: currentDriverURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  isExpectedRouterDriverBundle(
                    at: currentDriverURL,
                    fileManager: fileManager
                  ) else {
                return .invalidCurrent
            }
            return .current
        }

        let hasLegacyDriver = legacyRouterDriverBundleNames(in: directoryURL).contains { bundleName in
            fileManager.fileExists(
                atPath: directoryURL.appendingPathComponent(bundleName, isDirectory: true).path
            )
        }
        return hasLegacyDriver ? .legacy : .missing
    }

    static func waitForCurrentRouterDriverOnDisk(
        in directoryURL: URL = URL(fileURLWithPath: halDriverDirectory, isDirectory: true),
        fileManager: FileManager = .default,
        timeout: TimeInterval = 2,
        interval: TimeInterval = 0.1
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if routerDriverDiskState(
                in: directoryURL,
                fileManager: fileManager
            ).isCurrent {
                return true
            }
            guard !Task.isCancelled, Date() < deadline else {
                return false
            }
            try? await Task.sleep(
                nanoseconds: UInt64(max(0, interval) * 1_000_000_000)
            )
        } while true
    }

    static var bundledRouterDriverURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Drivers/\(routerDriverBundleName)")
    }

    static func availableDriverUpdate(
        in directoryURL: URL = URL(fileURLWithPath: halDriverDirectory, isDirectory: true),
        bundledDriverURL: URL = bundledRouterDriverURL
    ) -> RouterDriverUpdate? {
        // Missing/invalid drivers belong to the existing installation flow.
        guard routerDriverDiskState(in: directoryURL).isCurrent,
              isExpectedRouterDriverBundle(at: bundledDriverURL, fileManager: .default),
              let available = driverBuildVersion(at: bundledDriverURL),
              let availableVersion = RouterDriverVersion(available) else { return nil }
        let installed = driverBuildVersion(at: directoryURL.appendingPathComponent(routerDriverBundleName))
        if let installed, let installedVersion = RouterDriverVersion(installed),
           installedVersion >= availableVersion {
            return nil
        }
        return RouterDriverUpdate(
            installedVersion: installed,
            availableVersion: available,
            bundledDriverURL: bundledDriverURL
        )
    }

    static func verifyInstalledDriverVersion(
        _ expected: String,
        in directoryURL: URL = URL(fileURLWithPath: halDriverDirectory, isDirectory: true)
    ) throws {
        let actual = driverBuildVersion(at: directoryURL.appendingPathComponent(routerDriverBundleName))
        guard routerDriverDiskState(in: directoryURL).isCurrent,
              let expectedVersion = RouterDriverVersion(expected),
              let actual, RouterDriverVersion(actual) == expectedVersion else {
            throw DriverInstallerError.installedVersionMismatch(expected: expected, actual: actual)
        }
    }

    private static func driverBuildVersion(at bundleURL: URL) -> String? {
        // Read disk directly; Bundle caches metadata after a driver replacement.
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return info["CFBundleVersion"] as? String
    }

    private func bundledRouterDriverPath() throws -> String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Drivers/\(Self.routerDriverBundleName)"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Drivers/\(Self.routerDriverBundleName)")
        ].compactMap { $0 }

        for candidate in candidates {
            var isDirectory = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            return try validatedDriverBundlePath(candidate.path)
        }
        return nil
    }

    private func buildRouterDriverFromSource() throws -> String {
        guard let buildScriptPath = sourceBuildScriptPathIfAvailable() else {
            let expectedPath = fallbackRepoRootURL()
                .appendingPathComponent("script/build_router_driver.sh")
                .path
            throw DriverInstallerError.scriptNotFound(expectedPath)
        }
        let driverPath = try runBuildScript(buildScriptPath, expectedSuffix: Self.routerDriverBundleName)
        return try validatedDriverBundlePath(driverPath)
    }

    private func sourceBuildScriptPathIfAvailable() -> String? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.bundleURL,
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        ]

        for candidate in candidates {
            var directory = candidate.hasDirectoryPath ? candidate : candidate.deletingLastPathComponent()
            for _ in 0..<10 {
                let scriptURL = directory.appendingPathComponent("script/build_router_driver.sh")
                let packageURL = directory.appendingPathComponent("Package.swift")
                if fileManager.isExecutableFile(atPath: scriptURL.path),
                   fileManager.fileExists(atPath: packageURL.path) {
                    return scriptURL.path
                }

                let parent = directory.deletingLastPathComponent()
                if parent.path == directory.path {
                    break
                }
                directory = parent
            }
        }

        return nil
    }

    private func fallbackRepoRootURL() -> URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    private func runBuildScript(_ scriptPath: String, expectedSuffix: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptPath)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nearfield-driver-build-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        do {
            try process.run()
        } catch {
            throw DriverInstallerError.driverBuildFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(120)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw DriverInstallerError.driverBuildTimedOut
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        try? outputHandle.synchronize()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw DriverInstallerError.driverBuildFailed(output)
        }
        return try Self.driverPath(fromBuildOutput: output, expectedSuffix: expectedSuffix)
    }

    private func validatedDriverBundlePath(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent == Self.routerDriverBundleName else {
            throw DriverInstallerError.invalidDriverBundle(url.path)
        }
        guard !containsShellLineSeparator(url.path) else {
            throw DriverInstallerError.invalidDriverBundle(url.path)
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DriverInstallerError.driverBundleMissing(url.path)
        }

        // The install step ad-hoc signs whatever it is handed and loads it into
        // coreaudiod as root, so confirm this really is our plug-in and not
        // just a directory that happens to carry the right name.
        guard Self.isExpectedRouterDriverBundle(
            at: url,
            fileManager: FileManager.default
        ) else {
            throw DriverInstallerError.invalidDriverBundle(url.path)
        }
        return url.path
    }

    private static func isExpectedRouterDriverBundle(
        at bundleURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let infoURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let infoData = fileManager.contents(atPath: infoURL.path),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: infoData,
                options: [],
                format: nil
              ),
              let info = propertyList as? [String: Any],
              info["CFBundleIdentifier"] as? String == routerDriverBundleIdentifier,
              let executableName = info["CFBundleExecutable"] as? String,
              isSafeBundleExecutableName(executableName) else {
            return false
        }

        let executableURL = bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
        return fileManager.isExecutableFile(atPath: executableURL.path)
    }

    private static func isSafeBundleExecutableName(_ name: String) -> Bool {
        !name.isEmpty &&
            name != "." &&
            name != ".." &&
            (name as NSString).lastPathComponent == name
    }

    private func installedDriverPath(_ bundleName: String) -> String {
        "\(Self.halDriverDirectory)/\(bundleName)"
    }

    private func installedRouterDriverPaths() -> [String] {
        Self.routerDriverBundleNames().map(installedDriverPath(_:))
    }

    private func temporaryDriverPaths(for driverPath: String) -> [String] {
        [
            "\(driverPath).studiopair-installing",
            "\(driverPath).nearfield-installing"
        ]
    }

    private func installCleanupPaths(temporaryPath: String) -> [String] {
        let legacyTemporaryPaths = installedRouterDriverPaths().flatMap(temporaryDriverPaths(for:))
        return (legacyTemporaryPaths + [temporaryPath]).uniquePreservingOrder()
    }

    private func removeCommand(paths: [String]) -> String {
        paths
            .map { "/bin/rm -rf \(shellQuoted($0))" }
            .joined(separator: "\n")
    }

    private func coreAudioRestartCommand() -> String {
        "/usr/bin/killall coreaudiod || true"
    }

    private func driverServiceRestartCommand() -> String {
        "/usr/bin/pkill -f \(shellQuoted(Self.driverServiceHelperName)) || true"
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func containsShellLineSeparator(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value == 0 || CharacterSet.newlines.contains(scalar)
        }
    }

    static func maintenanceShellCommand(_ command: String) -> String {
        let commands = command
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Restart commands explicitly tolerate an absent process with `|| true`.
        // File-operation errors must still propagate to the caller.
        return (["set -e"] + commands).joined(separator: "; ")
    }

    private func runPrivilegedShell(_ command: String) throws {
        // Callers build this command only from fixed executable names and
        // newline/NUL-free paths that were individually shell-quoted. The
        // second escaping pass below is solely for the AppleScript string.
        let compactCommand = Self.maintenanceShellCommand(command)
        let escapedCommand = "\(compactCommand) 2>&1"
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = """
        do shell script "\(escapedCommand)" with administrator privileges with prompt "Nearfield needs administrator access to manage its HAL audio driver."
        """

        var error: NSDictionary?
        guard let script = NSAppleScript(source: appleScript) else {
            throw DriverInstallerError.installFailed("Could not create maintenance AppleScript.")
        }
        _ = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? error.description
            throw Self.privilegedInstallError(
                errorNumber: error[NSAppleScript.errorNumber] as? Int,
                message: message
            )
        }
    }
}
