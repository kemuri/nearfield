import Foundation

enum NearfieldPreferences {
    static let appRoutingEnabledKey = "appRoutingEnabled"

    static func appRoutingEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: appRoutingEnabledKey)
    }

    static func clearAppRoutingEnabled(in defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: appRoutingEnabledKey)
    }
}
