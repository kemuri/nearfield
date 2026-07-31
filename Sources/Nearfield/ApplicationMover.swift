import Foundation
import Security

enum ApplicationMover {
    static func installBundle(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let destinationDirectory = destinationURL.deletingLastPathComponent()
        let stagingURL = destinationDirectory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).nearfield-installing-\(UUID().uuidString)",
            isDirectory: true
        )
        let backupName = ".\(destinationURL.lastPathComponent).nearfield-backup-\(UUID().uuidString)"
        let backupURL = destinationDirectory.appendingPathComponent(backupName, isDirectory: true)
        var replacementSucceeded = false

        defer {
            try? fileManager.removeItem(at: stagingURL)
            if replacementSucceeded {
                try? fileManager.removeItem(at: backupURL)
            }
        }

        // Copying can fail for permissions, space, or quarantine reasons. Do
        // all of that work before touching the existing installation.
        try fileManager.copyItem(at: sourceURL, to: stagingURL)

        if fileManager.fileExists(atPath: destinationURL.path) {
            do {
                _ = try fileManager.replaceItemAt(
                    destinationURL,
                    withItemAt: stagingURL,
                    backupItemName: backupName,
                    options: [.withoutDeletingBackupItem]
                )
            } catch {
                if !fileManager.fileExists(atPath: destinationURL.path),
                   fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.moveItem(at: backupURL, to: destinationURL)
                }
                throw error
            }
            replacementSucceeded = true
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            replacementSucceeded = true
        }
    }
}

enum ApplicationReplacementRelauncher {
    private static let helperScript = """
    while /bin/kill -0 "$1" 2>/dev/null; do
        /bin/sleep 0.1
    done
    exec /usr/bin/open -n "$2"
    """

    static func replacementSatisfiesCurrentApplicationRequirement(
        at applicationURL: URL
    ) -> Bool {
        guard BuildConfiguration.isDistribution else {
            return true
        }

        var currentCode: SecCode?
        guard SecCodeCopySelf([], &currentCode) == errSecSuccess,
              let currentCode else {
            return false
        }

        var currentStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(currentCode, [], &currentStaticCode) == errSecSuccess,
              let currentStaticCode else {
            return false
        }

        var designatedRequirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            currentStaticCode,
            [],
            &designatedRequirement
        ) == errSecSuccess,
              let designatedRequirement else {
            return false
        }

        var replacementCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            applicationURL as CFURL,
            [],
            &replacementCode
        ) == errSecSuccess,
              let replacementCode else {
            return false
        }

        let validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures |
                kSecCSStrictValidate |
                kSecCSCheckNestedCode
        )
        return SecStaticCodeCheckValidity(
            replacementCode,
            validationFlags,
            designatedRequirement
        ) == errSecSuccess
    }

    static func helperArguments(
        processIdentifier: Int32,
        applicationURL: URL
    ) -> [String] {
        [
            "-c",
            helperScript,
            "nearfield-relaunch",
            String(processIdentifier),
            applicationURL.path
        ]
    }

    static func scheduleRelaunch(
        afterProcessExits processIdentifier: Int32,
        applicationURL: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = helperArguments(
            processIdentifier: processIdentifier,
            applicationURL: applicationURL
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
