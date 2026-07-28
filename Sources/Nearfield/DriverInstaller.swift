import Foundation

enum DriverInstallerError: LocalizedError {
    case scriptNotFound(String)
    case driverBuildFailed(String)
    case driverBuildTimedOut
    case driverBundleMissing(String)
    case invalidDriverBundle(String)
    case installFailed(String)

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
        case .installFailed(let output):
            return "Driver install failed.\n\n\(output)"
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

    private static var routerDriverBundleNames: [String] {
        [
            routerDriverBundleName,
            legacyRouterDriverBundleName,
            legacyProxyDriverBundleName
        ]
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
        let command = [
            "set -e",
            "/bin/mkdir -p \(shellQuoted(Self.halDriverDirectory))",
            driverServiceRestartCommand(),
            removeCommand(paths: cleanupPaths),
            "/usr/bin/ditto \(shellQuoted(sourcePath)) \(shellQuoted(temporaryPath))",
            "/usr/bin/xattr -cr \(shellQuoted(temporaryPath)) || true",
            "/usr/sbin/chown -R root:wheel \(shellQuoted(temporaryPath))",
            "/usr/bin/codesign --force --deep --sign - \(shellQuoted(temporaryPath))",
            "/usr/bin/xattr -cr \(shellQuoted(temporaryPath)) || true",
            removeCommand(paths: installedRouterDriverPaths()),
            "/bin/mv \(shellQuoted(temporaryPath)) \(shellQuoted(destinationPath))",
            "/usr/bin/xattr -cr \(shellQuoted(destinationPath)) || true",
            coreAudioRestartCommand()
        ].joined(separator: "\n")
        try runPrivilegedShell(command)
    }

    func removeAllInstalledDriversAndRestartCoreAudio() throws {
        let command = [
            driverServiceRestartCommand(),
            removeCommand(paths: Self.installedDriverRemovalPaths()),
            coreAudioRestartCommand()
        ].joined(separator: "\n")
        try runPrivilegedShell(command)
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

    static func installedDriverRemovalPaths() -> [String] {
        routerDriverBundleNames
            .map { "\(halDriverDirectory)/\($0)" }
            .flatMap { driverPath in
                [
                    "\(driverPath).studiopair-installing",
                    "\(driverPath).nearfield-installing",
                    driverPath
                ]
            }
    }

    static func isRouterDriverInstalledOnDisk() -> Bool {
        routerDriverBundleNames.contains { bundleName in
            FileManager.default.fileExists(atPath: "\(halDriverDirectory)/\(bundleName)")
        }
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
        guard Bundle(url: url)?.bundleIdentifier == Self.routerDriverBundleIdentifier else {
            throw DriverInstallerError.invalidDriverBundle(url.path)
        }
        return url.path
    }

    private func installedDriverPath(_ bundleName: String) -> String {
        "\(Self.halDriverDirectory)/\(bundleName)"
    }

    private func installedRouterDriverPaths() -> [String] {
        Self.routerDriverBundleNames.map(installedDriverPath(_:))
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

    private func runPrivilegedShell(_ command: String) throws {
        let compactCommand = command
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
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
            throw DriverInstallerError.installFailed(message)
        }
    }
}
