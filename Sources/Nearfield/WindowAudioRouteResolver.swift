import AppKit
import CoreGraphics

@MainActor
final class WindowAudioRouteResolver {
    struct DisplayTarget {
        let route: String
        let bounds: CGRect
    }

    struct RunningApplication {
        let bundleID: String
        let processID: pid_t
    }

    private struct WindowRoute {
        let processID: pid_t
        let windowID: CGWindowID?
        let route: String
        let area: CGFloat
    }

    private struct WindowSelection {
        let bundleID: String
        let windowID: CGWindowID
    }

    private var selectedWindows: [pid_t: WindowSelection] = [:]
    private let studioDisplays: () -> [AudioDevice]
    private let leftDeviceUID: () -> String?
    private let displayOrderUIDs: () -> [String]
    private let runningApplications: () -> [RunningApplication]
    private let windowList: () -> [[String: Any]]
    private let targetProvider: (() -> [DisplayTarget])?

    init(
        studioDisplays: @escaping () -> [AudioDevice] = { [] },
        leftDeviceUID: @escaping () -> String? = { nil },
        displayOrderUIDs: @escaping () -> [String] = { [] },
        runningApplications: @escaping () -> [RunningApplication] = {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard !app.isTerminated, let bundleID = app.bundleIdentifier else { return nil }
                return RunningApplication(bundleID: bundleID, processID: app.processIdentifier)
            }
        },
        windowList: @escaping () -> [[String: Any]] = {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
        },
        displayTargets: (() -> [DisplayTarget])? = nil
    ) {
        self.studioDisplays = studioDisplays
        self.leftDeviceUID = leftDeviceUID
        self.displayOrderUIDs = displayOrderUIDs
        self.runningApplications = runningApplications
        self.windowList = windowList
        self.targetProvider = displayTargets
    }

    static func assignedRoutes(
        for displays: [AudioDevice],
        leftDeviceUID: String?,
        displayOrderUIDs: [String] = []
    ) -> [String: String] {
        let arrangedDisplays = StudioDisplayAudioManager.orderedDisplays(
            from: displays,
            leftDeviceUID: leftDeviceUID,
            displayOrderUIDs: displayOrderUIDs
        )
        guard arrangedDisplays.count >= 2 else { return [:] }
        if arrangedDisplays.count >= 3 {
            // The virtual routing bus remains stereo. A center-screen app must
            // therefore keep its stereo pair; the physical center target gets
            // the equal L/R mix when the driver fans that pair out to 3 outputs.
            return [
                arrangedDisplays[0].uid: "left",
                arrangedDisplays[1].uid: "pair",
                arrangedDisplays[2].uid: "right"
            ]
        }
        return [arrangedDisplays[0].uid: "left", arrangedDisplays[1].uid: "right"]
    }

    func resolvedRules(from rawRules: String) -> String {
        let rules = AppRoutingRules.parse(rawRules)
        let sourceBundleIDs = Set(windowScopedSourceBundleIDs(in: rawRules))
        selectedWindows = selectedWindows.filter { sourceBundleIDs.contains($0.value.bundleID) }
        let routesByBundleID = sourceBundleIDs.isEmpty ? [:] : visibleWindowRoutes(
            for: sourceBundleIDs,
            runningApps: runningApplications()
        )

        var resolvedRules: [String] = []
        for rule in rules {
            if AppRoutingRules.isWindowScopedDestination(rule.destination) {
                let routes = routesByBundleID[windowScopedSourceBundleID(for: rule)] ?? []
                let expandedRule = windowScopedRules(routes: routes)
                resolvedRules.append(contentsOf: expandedRule.processRules)
                resolvedRules.append("\(rule.bundleID)=\(expandedRule.fallbackRoute)")
            } else {
                resolvedRules.append("\(rule.bundleID)=\(normalizedDestination(rule.destination))")
            }
        }

        return resolvedRules.joined(separator: "; ")
    }

    func fallbackRulesWithoutProcessOverrides(from rawRules: String) -> String {
        AppRoutingRules.parse(rawRules)
            .map { rule in
                let destination = AppRoutingRules.isWindowScopedDestination(rule.destination)
                    ? "pair"
                    : normalizedDestination(rule.destination)
                return "\(rule.bundleID)=\(destination)"
            }
            .joined(separator: "; ")
    }

    func hasWindowScopedRoute(in rawRules: String) -> Bool {
        AppRoutingRules.parse(rawRules).contains {
            AppRoutingRules.isWindowScopedDestination($0.destination)
        }
    }

    func hasRunningWindowScopedRoute(in rawRules: String) -> Bool {
        let bundleIDs = windowScopedSourceBundleIDs(in: rawRules)
        guard !bundleIDs.isEmpty else { return false }
        return isAnyBundleRunning(bundleIDs)
    }

    func currentRoutes(for requests: [AppAudioRouteRequest], rawRules: String) -> [String: String] {
        guard !requests.isEmpty else { return [:] }
        let runningApps = runningApplications()
        let runningBundleIDs = Set(runningApps.map(\.bundleID))
        let rules = AppRoutingRules.parse(rawRules)
        var selectedRules: [String: AppRoutingRule] = [:]
        for request in requests {
            let bundleIDs = Set([request.bundleIdentifier] + request.routingBundleIdentifiers)
            guard !runningBundleIDs.isDisjoint(with: bundleIDs) else { continue }
            let matchingRules = rules.filter { bundleIDs.contains($0.bundleID) }
            selectedRules[request.bundleIdentifier] = matchingRules.first {
                $0.bundleID == request.bundleIdentifier
            } ?? matchingRules.first
        }
        let sourceBundleIDs = Set(selectedRules.values
            .filter { AppRoutingRules.isWindowScopedDestination($0.destination) }
            .map { windowScopedSourceBundleID(for: $0) })
        let routesByBundleID = visibleWindowRoutes(for: sourceBundleIDs, runningApps: runningApps)
        return selectedRules.compactMapValues { rule in
            if AppRoutingRules.isWindowScopedDestination(rule.destination) {
                return routesByBundleID[windowScopedSourceBundleID(for: rule)]?
                    .max(by: { $0.area < $1.area })?.route
            }
            return normalizedDestination(rule.destination)
        }
    }

    private func normalizedDestination(_ destination: String) -> String {
        destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func windowScopedSourceBundleID(for rule: AppRoutingRule) -> String {
        let destination = rule.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separatorIndex = destination.firstIndex(of: ":") else {
            return rule.bundleID
        }
        let sourceBundleID = String(destination[destination.index(after: separatorIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sourceBundleID.isEmpty ? rule.bundleID : sourceBundleID
    }

    private func windowScopedSourceBundleIDs(in rawRules: String) -> [String] {
        AppRoutingRules.parse(rawRules)
            .filter { AppRoutingRules.isWindowScopedDestination($0.destination) }
            .map { windowScopedSourceBundleID(for: $0) }
            .uniquePreservingOrder()
    }

    private func windowScopedRules(routes: [WindowRoute]) -> (processRules: [String], fallbackRoute: String) {
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

    private func isAnyBundleRunning(_ bundleIDs: [String]) -> Bool {
        let bundleIDs = Set(bundleIDs)
        return runningApplications().contains { bundleIDs.contains($0.bundleID) }
    }

    private func visibleWindowRoutes(
        for bundleIDs: Set<String>,
        runningApps: [RunningApplication]
    ) -> [String: [WindowRoute]] {
        guard !bundleIDs.isEmpty else { return [:] }
        selectedWindows = selectedWindows.filter { pid, selection in
            runningApps.contains { $0.processID == pid && $0.bundleID == selection.bundleID }
        }
        var bundleIDByPID: [pid_t: String] = [:]
        for app in runningApps where bundleIDs.contains(app.bundleID) {
            bundleIDByPID[app.processID] = app.bundleID
        }
        guard !bundleIDByPID.isEmpty else { return [:] }
        // Capture metadata and resolve physical display identities once per
        // refresh, shared by every window and helper-app alias in the batch.
        // This reads no screen contents or window titles.
        let windowInfo = windowList()
        let targets = targetProvider?() ?? displayTargets()
        guard targets.count >= 2 else { return [:] }
        var routes: [String: [WindowRoute]] = [:]
        for window in windowInfo {
            guard let pidNumber = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let bundleID = bundleIDByPID[pidNumber.int32Value],
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

            guard let route = displayRoute(for: bounds, targets: targets) else {
                continue
            }

            routes[bundleID, default: []].append(WindowRoute(
                processID: pidNumber.int32Value,
                windowID: (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                route: route,
                area: bounds.width * bounds.height
            ))
        }

        var selectedRoutes: [String: [WindowRoute]] = [:]
        for (pid, bundleID) in bundleIDByPID {
            let candidates = (routes[bundleID] ?? []).filter { $0.processID == pid }
            // A process can carry audio for several windows without exposing
            // which one is playing. Keep following the established window by
            // identity; a new/larger/frontmost window is not evidence that the
            // audio source changed. Re-select only when that window disappears.
            let previousID = selectedWindows[pid]?.windowID
            let selected = candidates.first { candidate in
                previousID != nil && candidate.windowID == previousID
            } ?? candidates.max(by: { $0.area < $1.area })
            guard let selected else {
                selectedWindows.removeValue(forKey: pid)
                continue
            }
            if let windowID = selected.windowID {
                selectedWindows[pid] = WindowSelection(bundleID: bundleID, windowID: windowID)
            } else {
                selectedWindows.removeValue(forKey: pid)
            }
            selectedRoutes[bundleID, default: []].append(selected)
        }
        return selectedRoutes
    }

    private func displayRoute(for windowBounds: CGRect, targets: [DisplayTarget]) -> String? {
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
        let displays = studioDisplays()
        let assignedRoutes = Self.assignedRoutes(
            for: displays,
            leftDeviceUID: leftDeviceUID(),
            displayOrderUIDs: displayOrderUIDs()
        )
        let assignedTargets: [DisplayTarget] = displays.prefix(3).compactMap { display in
            guard let route = assignedRoutes[display.uid] else { return nil }
            guard let screen = StudioDisplayScreenMatcher.screen(forAudioDeviceUID: display.uid),
                  let displayID = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                  ] as? CGDirectDisplayID else {
                return nil
            }
            return DisplayTarget(
                route: route,
                bounds: CGDisplayBounds(displayID)
            )
        }
        let assignedScreensAreUnique = assignedTargets.enumerated().allSatisfy { index, target in
            !assignedTargets.prefix(index).contains(where: { $0.bounds == target.bounds })
        }
        if assignedTargets.count == min(3, displays.count), assignedScreensAreUnique {
            return assignedTargets
        }

        // Older or non-Studio-Display setups cannot be matched through the
        // USB/DisplayPort identity chain, so retain the spatial fallback.
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
        if sortedScreens.count >= 3 {
            return [
                DisplayTarget(route: "left", bounds: sortedScreens[0].bounds),
                DisplayTarget(route: "pair", bounds: sortedScreens[1].bounds),
                DisplayTarget(route: "right", bounds: sortedScreens[2].bounds)
            ]
        }
        return [DisplayTarget(route: "left", bounds: sortedScreens[0].bounds),
                DisplayTarget(route: "right", bounds: sortedScreens[1].bounds)]
    }
}
