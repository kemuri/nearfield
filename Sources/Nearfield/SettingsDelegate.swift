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
    func settingsCoreAudioAvailability() -> CoreAudioAvailability
    func settingsRefreshAudioState() async -> Bool
    func settingsMode() -> NearfieldOutputMode
    func settingsLeftDeviceUID() -> String?
    func settingsDisplayOrderUIDs() -> [String]
    func settingsNearfieldDriverSelected() -> Bool
    func settingsFooterStatus() -> String
    func settingsApplyConfiguration()
    func settingsPlayIdentificationChime(on display: AudioDevice)
    func settingsShowDisplayIdentification(
        for displayUID: String,
        fallbackSide: DisplayIdentificationSide
    )
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
    func settingsSetDisplayOrderUIDs(_ uids: [String])
}

enum DriverInstallRequest: Equatable {
    case userInitiated
    case enablingAppRouting
    case onboarding(allowsMissingStudioDisplays: Bool)

    var disablesAppRoutingOnFailure: Bool {
        self == .enablingAppRouting
    }

    var requiresConfirmation: Bool {
        switch self {
        case .userInitiated, .enablingAppRouting:
            true
        case .onboarding:
            false
        }
    }

    var presentsErrors: Bool {
        switch self {
        case .userInitiated, .enablingAppRouting:
            true
        case .onboarding:
            false
        }
    }

    var allowsMissingStudioDisplays: Bool {
        guard case .onboarding(let allowsMissingStudioDisplays) = self else {
            return false
        }
        return allowsMissingStudioDisplays
    }
}

enum DriverInstallFailureStage: Equatable {
    case preparation
    case authorization
    case installation
    case activation
    case configuration
}

struct DriverInstallFailure: Equatable {
    let stage: DriverInstallFailureStage
    let message: String
}

enum DriverInstallPhase: Equatable {
    case preparation
    case authorizationAndInstallation
    case activation
    case configuration
}

enum DriverInstallState: Equatable {
    case idle
    case installing(DriverInstallPhase)
    case succeeded
    case failed(DriverInstallFailure)
}

@MainActor
protocol SettingsDriverControlling: AnyObject {
    func settingsDriverInstalled() -> Bool
    func settingsIsInstallingDriver() -> Bool
    func settingsDriverInstallState() -> DriverInstallState
    func settingsResetDriverInstallState()
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
