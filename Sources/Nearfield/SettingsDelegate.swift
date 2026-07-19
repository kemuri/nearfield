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
protocol SettingsDelegate: AnyObject {
    func settingsDevices() -> [AudioDevice]
    func settingsRefreshAudioState() async -> Bool
    func settingsMode() -> NearfieldOutputMode
    func settingsLeftDeviceUID() -> String?
    func settingsOpenAtLogin() -> Bool
    func settingsSetOpenAtLogin(_ enabled: Bool)
    func settingsShowMenuBarApp() -> Bool
    func settingsSetShowMenuBarApp(_ enabled: Bool)
    func settingsDidReachSettingsScreen()
    func settingsDriverInstalled() -> Bool
    func settingsIsInstallingDriver() -> Bool
    func settingsNearfieldDriverSelected() -> Bool
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
    func settingsFooterStatus() -> String
    func settingsAppVersionText() -> String
    func settingsBalance() -> Float
    func settingsSetBalance(_ balance: Float)
    func settingsSetMode(_ mode: NearfieldOutputMode)
    func settingsSetLeftDeviceUID(_ uid: String)
    func settingsApplyConfiguration()
    func settingsInstallDriver(
        requiresConfirmation: Bool,
        presentsErrors: Bool,
        allowsMissingStudioDisplays: Bool
    )
    func settingsRemoveEverything()
    func settingsPlayTestTone(_ channel: TestToneChannel)
}

@MainActor
extension SettingsDelegate {
    func settingsInstallDriver() {
        settingsInstallDriver(
            requiresConfirmation: true,
            presentsErrors: true,
            allowsMissingStudioDisplays: false
        )
    }

    func settingsInstallDriver(requiresConfirmation: Bool) {
        settingsInstallDriver(
            requiresConfirmation: requiresConfirmation,
            presentsErrors: true,
            allowsMissingStudioDisplays: false
        )
    }

    func settingsInstallDriver(requiresConfirmation: Bool, presentsErrors: Bool) {
        settingsInstallDriver(
            requiresConfirmation: requiresConfirmation,
            presentsErrors: presentsErrors,
            allowsMissingStudioDisplays: false
        )
    }
}
