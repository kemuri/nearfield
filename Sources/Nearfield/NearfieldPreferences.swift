import Foundation

enum NearfieldPreferences {
    static let outputModeKey = "outputMode"
    static let leftDeviceUIDKey = "leftDeviceUID"
    static let balanceKey = "balance"
    static let showMenuBarAppKey = "showMenuBarApp"
    static let onboardingCompletionVersionKey = "onboardingCompletionVersion"
    static let aggregateSchemaVersionKey = "aggregateSchemaVersion"
    static let proxyPreparedDisplayStateKey = "proxyPreparedDisplayState"
    static let appRoutingEnabledKey = "appRoutingEnabled"
    static let appRoutingRulesKey = "appRoutingRules"
    static let appRoutingAppBundleIDsKey = "appRoutingAppBundleIDs"
    static let latestOnboardingCompletionVersion = 1
    static let latestAggregateSchemaVersion = 12

    static func outputMode(in defaults: UserDefaults = .standard) -> NearfieldOutputMode {
        guard let rawValue = defaults.string(forKey: outputModeKey),
              let mode = NearfieldOutputMode(rawValue: rawValue) else {
            return .stereo
        }
        return mode
    }

    static func setOutputMode(_ mode: NearfieldOutputMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: outputModeKey)
    }

    static func leftDeviceUID(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: leftDeviceUIDKey)
    }

    static func setLeftDeviceUID(_ uid: String, in defaults: UserDefaults = .standard) {
        defaults.set(uid, forKey: leftDeviceUIDKey)
    }

    static func balance(in defaults: UserDefaults = .standard) -> Float {
        defaults.float(forKey: balanceKey)
    }

    static func setBalance(_ balance: Float, in defaults: UserDefaults = .standard) {
        defaults.set(balance, forKey: balanceKey)
    }

    static func showMenuBarApp(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showMenuBarAppKey) != nil else {
            return true
        }
        return defaults.bool(forKey: showMenuBarAppKey)
    }

    static func setShowMenuBarApp(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: showMenuBarAppKey)
    }

    static func hasCompletedOnboarding(in defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: onboardingCompletionVersionKey) >= latestOnboardingCompletionVersion
    }

    static func markOnboardingCompleted(in defaults: UserDefaults = .standard) {
        defaults.set(latestOnboardingCompletionVersion, forKey: onboardingCompletionVersionKey)
    }

    static func resetOnboardingCompletion(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: onboardingCompletionVersionKey)
    }

    static func migrateOnboardingCompletionIfNeeded(
        currentDriverIsInstalled: Bool,
        in defaults: UserDefaults = .standard
    ) {
        guard defaults.object(forKey: onboardingCompletionVersionKey) == nil,
              currentDriverIsInstalled,
              hasPriorSetupEvidence(in: defaults) else {
            return
        }
        markOnboardingCompleted(in: defaults)
    }

    static func hasPriorSetupEvidence(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.integer(forKey: aggregateSchemaVersionKey) >= latestAggregateSchemaVersion {
            return true
        }

        let configuredKeys = [
            outputModeKey,
            leftDeviceUIDKey,
            balanceKey,
            showMenuBarAppKey,
            proxyPreparedDisplayStateKey,
            appRoutingRulesKey,
            appRoutingAppBundleIDsKey
        ]
        if configuredKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            return true
        }

        return defaults.object(forKey: appRoutingEnabledKey) != nil &&
            defaults.bool(forKey: appRoutingEnabledKey)
    }

    static func aggregateSchemaNeedsCleanup(in defaults: UserDefaults = .standard) -> Bool {
        defaults.integer(forKey: aggregateSchemaVersionKey) < latestAggregateSchemaVersion
    }

    static func markAggregateSchemaCurrent(in defaults: UserDefaults = .standard) {
        defaults.set(latestAggregateSchemaVersion, forKey: aggregateSchemaVersionKey)
    }

    static func proxyPreparedDisplayStateData(in defaults: UserDefaults = .standard) -> Data? {
        defaults.data(forKey: proxyPreparedDisplayStateKey)
    }

    static func setProxyPreparedDisplayStateData(_ data: Data?, in defaults: UserDefaults = .standard) {
        if let data {
            defaults.set(data, forKey: proxyPreparedDisplayStateKey)
        } else {
            defaults.removeObject(forKey: proxyPreparedDisplayStateKey)
        }
    }

    static func appRoutingEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: appRoutingEnabledKey)
    }

    static func setAppRoutingEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: appRoutingEnabledKey)
    }

    static func clearAppRoutingEnabled(in defaults: UserDefaults = .standard) {
        setAppRoutingEnabled(false, in: defaults)
    }

    static func appRoutingRules(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: appRoutingRulesKey) ?? ""
    }

    static func setAppRoutingRules(_ rules: String, in defaults: UserDefaults = .standard) {
        defaults.set(rules, forKey: appRoutingRulesKey)
    }

    static func appRoutingAppBundleIDs(in defaults: UserDefaults = .standard) -> [String]? {
        guard defaults.object(forKey: appRoutingAppBundleIDsKey) != nil else {
            return nil
        }
        return defaults.stringArray(forKey: appRoutingAppBundleIDsKey) ?? []
    }

    static func setAppRoutingAppBundleIDs(_ bundleIDs: [String], in defaults: UserDefaults = .standard) {
        defaults.set(bundleIDs, forKey: appRoutingAppBundleIDsKey)
    }
}
