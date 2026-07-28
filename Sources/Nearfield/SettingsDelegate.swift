import Foundation

enum SpatialRoutingChannel: String, Equatable {
    case left
    case right
    case pair
    case muted

    var symbolName: String {
        switch self {
        case .left: "l.circle.fill"
        case .right: "r.circle.fill"
        case .pair: "speaker.wave.2.circle.fill"
        case .muted: "speaker.slash.circle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .left: "Left channel"
        case .right: "Right channel"
        case .pair: "Both channels"
        case .muted: "Muted"
        }
    }

    init?(route: String) {
        switch route.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left", "left-display":
            self = .left
        case "right", "right-display":
            self = .right
        case "pair", "default":
            self = .pair
        case "muted", "mute", "silent":
            self = .muted
        default:
            return nil
        }
    }
}

@MainActor
protocol SettingsAudioStateProviding: AnyObject {
    func settingsDevices() -> [AudioDevice]
    func settingsRefreshAudioState() async -> Bool
    func settingsMode() -> NearfieldOutputMode
    func settingsLeftDeviceUID() -> String?
    func settingsNearfieldDriverSelected() -> Bool
    func settingsFooterStatus() -> String
    func settingsApplyConfiguration()
    func settingsPlayTestTone(_ channel: TestToneChannel)
}

@MainActor
protocol SettingsPreferencesControlling: AnyObject {
    func settingsOpenAtLogin() -> Bool
    func settingsSetOpenAtLogin(_ enabled: Bool)
    func settingsShowMenuBarApp() -> Bool
    func settingsSetShowMenuBarApp(_ enabled: Bool)
    func settingsDidReachSettingsScreen()
    func settingsAppVersionText() -> String
    func settingsBalance() -> Float
    func settingsSetBalance(_ balance: Float)
    func settingsSetMode(_ mode: NearfieldOutputMode)
    func settingsSetLeftDeviceUID(_ uid: String)
    func settingsSwapAssignment()
}

struct DriverInstallRequest {
    let disablesAppRoutingOnFailure: Bool
    let requiresConfirmation: Bool
    let presentsErrors: Bool
    let allowsMissingStudioDisplays: Bool

    static let userInitiated = DriverInstallRequest(
        disablesAppRoutingOnFailure: false,
        requiresConfirmation: true,
        presentsErrors: true,
        allowsMissingStudioDisplays: false
    )

    static let enablingAppRouting = DriverInstallRequest(
        disablesAppRoutingOnFailure: true,
        requiresConfirmation: true,
        presentsErrors: true,
        allowsMissingStudioDisplays: false
    )

    static func onboarding(allowsMissingStudioDisplays: Bool) -> DriverInstallRequest {
        DriverInstallRequest(
            disablesAppRoutingOnFailure: false,
            requiresConfirmation: false,
            presentsErrors: false,
            allowsMissingStudioDisplays: allowsMissingStudioDisplays
        )
    }
}

@MainActor
protocol SettingsDriverControlling: AnyObject {
    func settingsDriverInstalled() -> Bool
    func settingsIsInstallingDriver() -> Bool
    func settingsInstallDriver(_ request: DriverInstallRequest)
    func settingsRemoveEverything()
}

@MainActor
protocol SettingsRoutingControlling: AnyObject {
    func settingsAppRoutingEnabled() -> Bool
    func settingsSetAppRoutingEnabled(_ enabled: Bool)
    func settingsAppRoutingAppBundleIDs() -> [String]?
    func settingsSetAppRoutingAppBundleIDs(_ bundleIDs: [String])
    func settingsSpatialRoutingChannel(
        for bundleIdentifier: String,
        routingBundleIdentifiers: [String]
    ) -> SpatialRoutingChannel?
    func settingsRoutingRules() -> String
    func settingsSetRoutingRules(_ rules: String)
}

@MainActor
protocol SettingsDelegate:
    SettingsAudioStateProviding,
    SettingsPreferencesControlling,
    SettingsDriverControlling,
    SettingsRoutingControlling {}

@MainActor
extension SettingsDriverControlling {
    func settingsInstallDriver() {
        settingsInstallDriver(.userInitiated)
    }
}
