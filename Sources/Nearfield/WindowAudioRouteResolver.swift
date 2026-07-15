import AppKit
import CoreGraphics

@MainActor
final class WindowAudioRouteResolver {
    private struct Rule {
        let bundleID: String
        let destination: String
    }

    private struct DisplayTarget {
        let route: String
        let bounds: CGRect
    }

    private struct WindowRoute {
        let processID: pid_t
        let route: String
        let area: CGFloat
    }

    func resolvedRules(from rawRules: String) -> String {
        let rules = parseRules(rawRules)

        var resolvedRules: [String] = []
        for rule in rules {
            if isWindowScopedDestination(rule.destination) {
                let expandedRule = windowScopedRules(for: windowScopedSourceBundleID(for: rule))
                resolvedRules.append(contentsOf: expandedRule.processRules)
                resolvedRules.append("\(rule.bundleID)=\(expandedRule.fallbackRoute)")
            } else {
                resolvedRules.append("\(rule.bundleID)=\(normalizedDestination(rule.destination))")
            }
        }

        return resolvedRules.joined(separator: "; ")
    }

    func fallbackRulesWithoutProcessOverrides(from rawRules: String) -> String {
        parseRules(rawRules)
            .map { rule in
                let destination = isWindowScopedDestination(rule.destination)
                    ? "pair"
                    : normalizedDestination(rule.destination)
                return "\(rule.bundleID)=\(destination)"
            }
            .joined(separator: "; ")
    }

    func hasWindowScopedRoute(in rawRules: String) -> Bool {
        parseRules(rawRules).contains { isWindowScopedDestination($0.destination) }
    }

    func hasRunningWindowScopedRoute(in rawRules: String) -> Bool {
        let bundleIDs = windowScopedSourceBundleIDs(in: rawRules)
        guard !bundleIDs.isEmpty else { return false }
        return isAnyBundleRunning(bundleIDs)
    }

    func currentRoute(
        for primaryBundleID: String,
        routingBundleIDs: [String],
        rawRules: String
    ) -> String? {
        let bundleIDs = ([primaryBundleID] + routingBundleIDs).uniquePreservingOrder()
        guard isAnyBundleRunning(bundleIDs) else {
            return nil
        }

        let rules = parseRules(rawRules).filter { bundleIDs.contains($0.bundleID) }
        guard let rule = rules.first(where: { $0.bundleID == primaryBundleID }) ?? rules.first else {
            return nil
        }

        if isWindowScopedDestination(rule.destination) {
            return currentWindowScopedRoute(for: windowScopedSourceBundleID(for: rule))
        }
        return normalizedDestination(rule.destination)
    }

    private func parseRules(_ rules: String) -> [Rule] {
        rules
            .split { $0 == ";" || $0 == "\n" }
            .compactMap { rawRule in
                let parts = rawRule.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let bundleID = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                let destination = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !bundleID.isEmpty, !destination.isEmpty else { return nil }
                return Rule(bundleID: bundleID, destination: destination)
            }
    }

    private func normalizedDestination(_ destination: String) -> String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isWindowScopedDestination(_ destination: String) -> Bool {
        let normalized = normalizedDestination(destination)
        return normalized == "window" ||
            normalized == "screen" ||
            normalized == "display" ||
            normalized.hasPrefix("window:") ||
            normalized.hasPrefix("screen:") ||
            normalized.hasPrefix("display:")
    }

    private func windowScopedSourceBundleID(for rule: Rule) -> String {
        let destination = rule.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separatorIndex = destination.firstIndex(of: ":") else {
            return rule.bundleID
        }
        let sourceBundleID = String(destination[destination.index(after: separatorIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceBundleID.isEmpty ? rule.bundleID : sourceBundleID
    }

    private func windowScopedSourceBundleIDs(in rawRules: String) -> [String] {
        parseRules(rawRules)
            .filter { isWindowScopedDestination($0.destination) }
            .map { windowScopedSourceBundleID(for: $0) }
            .uniquePreservingOrder()
    }

    private func windowScopedRules(for bundleID: String) -> (processRules: [String], fallbackRoute: String) {
        let routes = visibleWindowRoutes(for: bundleID)
        guard !routes.isEmpty else {
            return ([], "pair")
        }

        var bestRouteByProcessID: [pid_t: WindowRoute] = [:]
        for route in routes {
            if let existingRoute = bestRouteByProcessID[route.processID],
               existingRoute.area >= route.area {
                continue
            }
            bestRouteByProcessID[route.processID] = route
        }

        let processRules = bestRouteByProcessID
            .sorted { $0.key < $1.key }
            .map { "pid:\($0.key)=\($0.value.route)" }
        let fallbackRoute = routes.max(by: { $0.area < $1.area })?.route ?? "pair"
        return (processRules, fallbackRoute)
    }

    private func currentWindowScopedRoute(for bundleID: String) -> String? {
        visibleWindowRoutes(for: bundleID)
            .max(by: { $0.area < $1.area })?
            .route
    }

    private func isAnyBundleRunning(_ bundleIDs: [String]) -> Bool {
        let bundleIDs = Set(bundleIDs)
        return NSWorkspace.shared.runningApplications.contains {
            guard let bundleIdentifier = $0.bundleIdentifier else { return false }
            return !$0.isTerminated && bundleIDs.contains(bundleIdentifier)
        }
    }

    private func visibleWindowRoutes(for bundleID: String) -> [WindowRoute] {
        let runningPIDs = Set(NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == bundleID && !$0.isTerminated }
            .map(\.processIdentifier))
        // Spatial routing only reads required window-list metadata (PID, layer,
        // bounds, and alpha). It never captures screen contents or window names,
        // so Screen Recording authorization is neither needed nor requested.
        guard !runningPIDs.isEmpty,
              let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var routes: [WindowRoute] = []
        for window in windowInfo {
            guard let pidNumber = window[kCGWindowOwnerPID as String] as? NSNumber,
                  runningPIDs.contains(pidNumber.int32Value),
                  let layerNumber = window[kCGWindowLayer as String] as? NSNumber,
                  layerNumber.intValue == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width >= 80,
                  bounds.height >= 80 else {
                continue
            }

            if let alphaNumber = window[kCGWindowAlpha as String] as? NSNumber,
               alphaNumber.doubleValue <= 0 {
                continue
            }

            guard let route = displayRoute(for: bounds) else {
                continue
            }

            routes.append(WindowRoute(
                processID: pidNumber.int32Value,
                route: route,
                area: bounds.width * bounds.height
            ))
        }

        return routes
    }

    private func displayRoute(for windowBounds: CGRect) -> String? {
        let targets = displayTargets()
        guard targets.count >= 2 else { return nil }

        var bestTarget: DisplayTarget?
        var bestIntersectionArea: CGFloat = 0
        for target in targets {
            let intersection = windowBounds.intersection(target.bounds)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestTarget = target
            }
        }

        if let bestTarget, bestIntersectionArea > 0 {
            return bestTarget.route
        }

        let center = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        return targets.first(where: { $0.bounds.contains(center) })?.route
    }

    private func displayTargets() -> [DisplayTarget] {
        let screens = NSScreen.screens
        let studioScreens = screens.filter { $0.localizedName.localizedCaseInsensitiveContains("Studio Display") }
        let candidateScreens = studioScreens.count >= 2 ? studioScreens : screens

        let sortedScreens = candidateScreens
            .compactMap { screen -> (screen: NSScreen, bounds: CGRect)? in
                guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                    return nil
                }
                return (screen, CGDisplayBounds(displayID))
            }
            .sorted {
                if $0.bounds.midX == $1.bounds.midX {
                    return $0.bounds.midY < $1.bounds.midY
                }
                return $0.bounds.midX < $1.bounds.midX
            }

        guard sortedScreens.count >= 2 else { return [] }
        return [
            DisplayTarget(route: "left", bounds: sortedScreens[0].bounds),
            DisplayTarget(route: "right", bounds: sortedScreens[1].bounds)
        ]
    }
}
