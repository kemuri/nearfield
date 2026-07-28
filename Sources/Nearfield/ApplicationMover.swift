import Foundation

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
