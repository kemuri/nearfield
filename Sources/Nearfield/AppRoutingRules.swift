import Foundation

struct AppRoutingRule: Equatable {
    var bundleID: String
    var destination: String
}

enum AppRoutingAliases {
    static func aliasBundleIDs(for primaryBundleID: String) -> [String] {
        switch primaryBundleID {
        case "com.apple.Safari":
            return [
                "com.apple.WebKit.WebContent",
                "com.apple.WebKit.GPU",
                "com.apple.WebKit.Networking",
                "com.apple.WebKit.WebContent.CaptivePortal",
                "com.apple.WebKit.WebContent.Development",
                "com.apple.WebKit.GPU.Development",
                "com.apple.WebKit.Networking.Development",
                "com.apple.WebKit.Plugin.64",
                "com.apple.WebKit.Plugin.64.Development"
            ]
        default:
            return []
        }
    }
}

enum AppRoutingRules {
    static func parse(_ rules: String) -> [AppRoutingRule] {
        rules
            .split { $0 == ";" || $0 == "\n" }
            .compactMap { rawRule in
                let parts = rawRule.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let bundleID = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let destination = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !bundleID.isEmpty, !destination.isEmpty else { return nil }
                return AppRoutingRule(bundleID: bundleID, destination: destination)
            }
    }

    static func serialize(_ rules: [AppRoutingRule]) -> String {
        rules
            .map { "\($0.bundleID)=\($0.destination)" }
            .joined(separator: "; ")
    }

    static func isWindowScopedDestination(_ destination: String) -> Bool {
        let normalized = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "window" ||
            normalized == "screen" ||
            normalized == "display" ||
            normalized.hasPrefix("window:") ||
            normalized.hasPrefix("screen:") ||
            normalized.hasPrefix("display:")
    }

    static func settingApp(
        bundleID: String,
        enabled: Bool,
        destination: String = "window",
        in rawRules: String
    ) -> String {
        var rules = parse(rawRules)
        rules.removeAll { $0.bundleID == bundleID }
        if enabled {
            rules.append(AppRoutingRule(bundleID: bundleID, destination: destination))
        }
        return serialize(rules)
    }

    static func settingApp(
        primaryBundleID: String,
        aliasBundleIDs: [String],
        enabled: Bool,
        in rawRules: String
    ) -> String {
        let aliasBundleIDs = (aliasBundleIDs + AppRoutingAliases.aliasBundleIDs(for: primaryBundleID))
            .filter { $0 != primaryBundleID }
            .uniquePreservingOrder()
        let allBundleIDs = ([primaryBundleID] + aliasBundleIDs).uniquePreservingOrder()
        var rules = parse(rawRules)
        rules.removeAll { allBundleIDs.contains($0.bundleID) }
        if enabled {
            rules.append(AppRoutingRule(bundleID: primaryBundleID, destination: "window"))
            rules.append(contentsOf: aliasBundleIDs.map { aliasBundleID in
                AppRoutingRule(bundleID: aliasBundleID, destination: "window:\(primaryBundleID)")
            })
        }
        return serialize(rules)
    }
}

extension Array where Element: Hashable {
    func uniquePreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
