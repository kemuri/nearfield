import Foundation

enum NearfieldPreferences {
    static let outputModeKey = "outputMode"
    static let leftDeviceUIDKey = "leftDeviceUID"
    static let displayOrderUIDsKey = "displayOrderUIDs"
    static let balanceKey = "balance"
    static let showMenuBarAppKey = "showMenuBarApp"
    static let onboardingCompletionVersionKey = "onboardingCompletionVersion"
    static let aggregateSchemaVersionKey = "aggregateSchemaVersion"
    static let proxyPreparedDisplayStateKey = "proxyPreparedDisplayState"
    static let appRoutingEnabledKey = "appRoutingEnabled"
    static let appRoutingRulesKey = "appRoutingRules"
    static let appRoutingAppBundleIDsKey = "appRoutingAppBundleIDs"
    /// Testing switch for 0.2.0: leave the volume keys to macOS alone.
    static let systemHandlesVolumeKeysKey = "systemHandlesVolumeKeys"
    /// Testing switches for driver 1.1.0, forwarded when set.
    static let driverDiagnosticsKey = "driverDiagnostics"
    static let driverUnderrunStrategyKey = "driverUnderrunStrategy"
    static let latestOnboardingCompletionVersion = 1
    static let latestAggregateSchemaVersion = 12

    private static let allKeys = [
        outputModeKey,
        leftDeviceUIDKey,
        displayOrderUIDsKey,
        balanceKey,
        showMenuBarAppKey,
        onboardingCompletionVersionKey,
        aggregateSchemaVersionKey,
        proxyPreparedDisplayStateKey,
        appRoutingEnabledKey,
        appRoutingRulesKey,
        appRoutingAppBundleIDsKey,
        systemHandlesVolumeKeysKey,
        driverDiagnosticsKey,
        driverUnderrunStrategyKey
    ]

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

    static func displayOrderUIDs(in defaults: UserDefaults = .standard) -> [String] {
        DisplayOrder.normalizedUIDs(defaults.stringArray(forKey: displayOrderUIDsKey) ?? [])
    }

    static func setDisplayOrderUIDs(_ uids: [String], in defaults: UserDefaults = .standard) {
        let normalizedUIDs = DisplayOrder.normalizedUIDs(uids)
        defaults.set(normalizedUIDs, forKey: displayOrderUIDsKey)
        if let leftUID = normalizedUIDs.first {
            setLeftDeviceUID(leftUID, in: defaults)
        }
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

    static func resetAll(in defaults: UserDefaults = .standard) {
        allKeys.forEach { defaults.removeObject(forKey: $0) }
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
            displayOrderUIDsKey,
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

    static func systemHandlesVolumeKeys(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: systemHandlesVolumeKeysKey)
    }

    static func driverDiagnostics(in defaults: UserDefaults = .standard) -> Bool? {
        defaults.object(forKey: driverDiagnosticsKey) == nil ? nil : defaults.bool(forKey: driverDiagnosticsKey)
    }

    static func driverUnderrunStrategy(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: driverUnderrunStrategyKey).flatMap { ["both", "steer", "gap"].contains($0) ? $0 : nil }
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
