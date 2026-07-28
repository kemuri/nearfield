import Foundation

enum NearfieldAudioIdentifiers {
    static let legacyProxyDeviceUID = "ProxyAudioDevice_UID"
    static let legacyRouterDeviceUID = "StudioPairRouterAudioDevice_UID"
    static let routerDeviceUID = "NearfieldAudioDevice_UID"
    static let routerBoxUID = "NearfieldAudioBox_UID"
    static let appTargetAggregateUID = "com.kemuri.Nearfield.TargetAggregate"
    static let driverTargetAggregateUID = "com.kemuri.Nearfield.DriverTargetAggregate"
    static let legacyTargetAggregateUID = "com.kemuri.StudioPair.Aggregate"

    static let appTargetAggregateName = "Nearfield Target"
    static let driverTargetAggregateName = "Nearfield Driver Target"
    static let legacyTargetAggregateNames: Set<String> = [
        "Studio Pair Target",
        "Studio Pair"
    ]

    static let virtualOutputUIDs: Set<String> = [
        legacyProxyDeviceUID,
        legacyRouterDeviceUID,
        routerDeviceUID,
        driverTargetAggregateUID,
        appTargetAggregateUID
    ]

    static let managedAggregateUIDs: Set<String> = [
        appTargetAggregateUID,
        driverTargetAggregateUID,
        legacyTargetAggregateUID
    ]

    static let managedAggregateNames: Set<String> = legacyTargetAggregateNames.union([
        appTargetAggregateName,
        driverTargetAggregateName
    ])
}
