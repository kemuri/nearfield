import Foundation

enum NearfieldResources {
    static let validationCommandLineArgument = "--nearfield-validate-packaged-resources"

    private static let swiftPackageResourceBundleName = "Nearfield_Nearfield.bundle"
    private static let menuBarIconRelativePaths = [
        "Icons/menubar.svg",
        "menubar.svg"
    ]

    static func menuBarIconURL(
        in bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> URL? {
        menuBarIconURL(
            searchRoots: resourceBundleSearchRoots(in: bundle),
            fileManager: fileManager
        )
    }

    static func menuBarIconURL(
        searchRoots: [URL],
        fileManager: FileManager = .default
    ) -> URL? {
        for root in searchRoots {
            for relativePath in menuBarIconRelativePaths {
                let candidate = root.appendingPathComponent(relativePath, isDirectory: false)
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    return candidate
                }
            }
        }
        return nil
    }

    private static func resourceBundleSearchRoots(in bundle: Bundle) -> [URL] {
        var candidates: [URL] = []
        if let resourceURL = bundle.resourceURL {
            candidates.append(
                resourceURL.appendingPathComponent(
                    swiftPackageResourceBundleName,
                    isDirectory: true
                )
            )
        }
        candidates.append(
            bundle.bundleURL.appendingPathComponent(
                swiftPackageResourceBundleName,
                isDirectory: true
            )
        )
        if let executableURL = bundle.executableURL {
            candidates.append(
                executableURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(
                        swiftPackageResourceBundleName,
                        isDirectory: true
                    )
            )
        }
#if DEBUG
        // Keep `swift run` useful without baking the checkout path into a
        // release executable. Packaged apps always resolve one of the roots
        // above first.
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Sources/Nearfield/Resources", isDirectory: true)
        )
#endif

        var seenPaths: Set<String> = []
        return candidates.filter { candidate in
            seenPaths.insert(candidate.standardizedFileURL.path).inserted
        }
    }
}
