import CoreAudio
import Foundation

/// Custom properties on the driver's box (driver 1.1.0 and later).
enum RouterDriverProperty {
    /// A dictionary Nearfield writes; the driver applies it in one step.
    static let settings = AudioObjectPropertySelector(0x6E66_7374) // 'nfst'
    /// A dictionary Nearfield reads; the driver notifies when it changes.
    static let status = AudioObjectPropertySelector(0x6E66_7373) // 'nfss'
}

/// What the driver reports on its status property.
struct RouterDriverStatus: Equatable {
    var instance: Int64
    var protocolVersion: Int
    var driverVersion: String?
    var capabilities: Set<String>
    var ready: Bool
    var targetDevices: [String]
    var targetMode: String
    var hidden: Bool
    var outputRunning: Bool
    var sampleRate: Double
    var latencyMilliseconds: Double
    var underruns: Int
    var halRequests: Int
    var writerVerification: String?

    init?(dictionary: [String: Any]) {
        guard let version = dictionary["protocolVersion"] as? Int else { return nil }
        protocolVersion = version
        instance = (dictionary["instance"] as? NSNumber)?.int64Value ?? 0
        driverVersion = dictionary["driverVersion"] as? String
        capabilities = Set(dictionary["capabilities"] as? [String] ?? [])
        ready = dictionary["ready"] as? Bool ?? false
        targetDevices = dictionary["targetDevices"] as? [String] ?? []
        targetMode = dictionary["targetMode"] as? String ?? NearfieldOutputMode.stereo.rawValue
        hidden = dictionary["hidden"] as? Bool ?? false
        outputRunning = dictionary["outputRunning"] as? Bool ?? false
        sampleRate = (dictionary["sampleRate"] as? NSNumber)?.doubleValue ?? 0
        latencyMilliseconds = (dictionary["latencyMilliseconds"] as? NSNumber)?.doubleValue ?? 0
        let counters = dictionary["counters"] as? [String: Any] ?? [:]
        underruns = (counters["underruns"] as? NSNumber)?.intValue ?? 0
        halRequests = (counters["halRequests"] as? NSNumber)?.intValue ?? 0
        writerVerification = dictionary["writerVerification"] as? String
    }

    /// Ready for exactly these displays, in this order, in this mode.
    func isReady(deviceUIDs: [String], mode: NearfieldOutputMode) -> Bool {
        guard (2...3).contains(deviceUIDs.count) else { return false }
        return ready && targetDevices == deviceUIDs && targetMode == mode.rawValue
    }
}

/// The configuration Nearfield wants the driver to have.
struct RouterDriverSettings: Equatable {
    var deviceName: String
    var targetDevices: [String]
    var mode: NearfieldOutputMode
    var routingEnabled: Bool
    /// App routes such as "com.apple.Safari=left"; saved by the driver.
    var routeRules: String
    /// Routes for individual processes (window following); never saved.
    var processRoutes: [Int32: String]
    /// Testing switches (hidden preferences); nil leaves the driver's value.
    var diagnostics: Bool? = nil
    var underrunStrategy: String? = nil

    /// The settings-property keys and values that differ from |previous|,
    /// or everything when there is no previous state.
    func changes(since previous: RouterDriverSettings?) -> [String: Any] {
        var changes: [String: Any] = [:]
        if previous?.deviceName != deviceName { changes["deviceName"] = deviceName }
        if previous?.targetDevices != targetDevices { changes["targetDevices"] = targetDevices }
        if previous?.mode != mode { changes["targetMode"] = mode.rawValue }
        if previous?.routingEnabled != routingEnabled { changes["routingEnabled"] = routingEnabled }
        if previous?.routeRules != routeRules { changes["routeRules"] = routeRules }
        if previous?.processRoutes != processRoutes {
            changes["processRoutes"] = Dictionary(uniqueKeysWithValues: processRoutes.map { (String($0.key), $0.value) })
        }
        if let diagnostics, previous?.diagnostics != diagnostics { changes["diagnostics"] = diagnostics }
        if let underrunStrategy, previous?.underrunStrategy != underrunStrategy {
            changes["underrunStrategy"] = underrunStrategy
        }
        return changes
    }
}

enum RouterRouteRules {
    /// Splits resolved rules ("pid:101=left; com.apple.Safari=left") into the
    /// saved app rules and the per-process routes of window following.
    static func split(_ resolvedRules: String) -> (rules: String, processRoutes: [Int32: String]) {
        var rules: [String] = []
        var processRoutes: [Int32: String] = [:]
        for rule in AppRoutingRules.parse(resolvedRules) {
            let key = rule.bundleID.lowercased()
            if key.hasPrefix("pid:"), let pid = Int32(key.dropFirst(4)), pid > 0 {
                processRoutes[pid] = rule.destination.lowercased()
            } else {
                rules.append("\(rule.bundleID)=\(rule.destination)")
            }
        }
        return (rules.joined(separator: "; "), processRoutes)
    }
}
