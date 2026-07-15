import Foundation

enum NearfieldPreferences {
    static let appRoutingEnabledKey = "appRoutingEnabled"
    static let appRoutingRulesKey = "appRoutingRules"
    static let appRoutingAppBundleIDsKey = "appRoutingAppBundleIDs"

    static func appRoutingEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: appRoutingEnabledKey)
    }

    static func clearAppRoutingEnabled(in defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: appRoutingEnabledKey)
    }

    static func appRoutingRules(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: appRoutingRulesKey) ?? ""
    }
}
