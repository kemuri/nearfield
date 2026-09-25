import AppKit

/// Helper processes that play audio for a routed app (browser renderers,
/// Electron helpers). Found by scanning the app bundle, which can take a
/// while for large apps, so it runs off the main thread at launch and when
/// the routing rules change, never while the Settings window refreshes.
@MainActor
final class RoutingAppCatalog {
    private var routingBundleIDsByApp: [String: [String]] = [:]
    private var scanning: Set<String> = []
    private let scanQueue = DispatchQueue(label: "com.kemuri.Nearfield.routing-apps", qos: .utility)
    /// Called on the main thread after new helpers were found.
    var onUpdate: (() -> Void)?

    /// The app and its helpers, once scanned.
    func routingBundleIdentifiers(for bundleID: String) -> [String]? {
        routingBundleIDsByApp[bundleID]
    }

    /// Scans apps that were not scanned yet.
    func refresh(bundleIDs: [String]) {
        let missing = bundleIDs.uniquePreservingOrder().filter {
            routingBundleIDsByApp[$0] == nil && !scanning.contains($0)
        }
        guard !missing.isEmpty else { return }
        scanning.formUnion(missing)
        scanQueue.async { [weak self] in
            let found = missing.map { bundleID -> (String, [String]) in
                let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                return (bundleID, url.map {
                    Self.routingBundleIdentifiers(forAppAt: $0, primaryBundleIdentifier: bundleID)
                } ?? ([bundleID] + AppRoutingAliases.aliasBundleIDs(for: bundleID)).uniquePreservingOrder())
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (bundleID, identifiers) in found {
                        self.routingBundleIDsByApp[bundleID] = identifiers
                        self.scanning.remove(bundleID)
                    }
                    self.onUpdate?()
                }
            }
        }
    }

    nonisolated static func routingBundleIdentifiers(
        forAppAt appURL: URL,
        primaryBundleIdentifier: String
    ) -> [String] {
        let bundleExtensions = Set(["app", "xpc"])
        var bundleIdentifiers = [primaryBundleIdentifier]
        let searchRoots = [
            appURL.appendingPathComponent("Contents/Frameworks"),
            appURL.appendingPathComponent("Contents/Helpers"),
            appURL.appendingPathComponent("Contents/XPCServices"),
            appURL.appendingPathComponent("Contents/PlugIns"),
            appURL.appendingPathComponent("Contents/Library/LoginItems")
        ]

        for root in searchRoots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let url as URL in enumerator {
                guard bundleExtensions.contains(url.pathExtension.lowercased()) else { continue }
                if let bundleIdentifier = Bundle(url: url)?.bundleIdentifier {
                    bundleIdentifiers.append(bundleIdentifier)
                }
                enumerator.skipDescendants()
            }
        }

        bundleIdentifiers.append(contentsOf: AppRoutingAliases.aliasBundleIDs(for: primaryBundleIdentifier))
        return bundleIdentifiers.uniquePreservingOrder()
    }
}

enum AppIconThumbnail {
    /// Routed apps are shown at 24 pt; keep only a bitmap of that size
    /// instead of the full icon family.
    @MainActor
    static func make(from image: NSImage, points: CGFloat = 24) -> NSImage {
        let scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        let pixels = Int((points * scale).rounded())
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            image.size = NSSize(width: points, height: points)
            return image
        }
        representation.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
        image.draw(
            in: NSRect(x: 0, y: 0, width: points, height: points),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let thumbnail = NSImage(size: representation.size)
        thumbnail.addRepresentation(representation)
        return thumbnail
    }
}
