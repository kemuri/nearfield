enum NearfieldWindowPresentation: Equatable {
    case none
    case onboarding
    case settings
}

enum NearfieldLaunchPolicy {
    static func initialLaunchPresentation(
        hasCompletedOnboarding: Bool,
        isDefaultLaunch: Bool,
        isLoginItemLaunch: Bool
    ) -> NearfieldWindowPresentation {
        guard hasCompletedOnboarding else {
            return .onboarding
        }
        guard isDefaultLaunch, !isLoginItemLaunch else {
            return .none
        }
        return .settings
    }

    static func requiresOnboarding(
        hasCompletedOnboarding: Bool,
        currentDriverIsInstalled: Bool
    ) -> Bool {
        !hasCompletedOnboarding || !currentDriverIsInstalled
    }

    static func openApplicationPresentation(
        hasCompletedOnboarding: Bool,
        isLoginItemLaunch: Bool
    ) -> NearfieldWindowPresentation {
        guard hasCompletedOnboarding else {
            return .onboarding
        }
        guard !isLoginItemLaunch else {
            return .none
        }
        return .settings
    }

    static func reopenPresentation(
        hasCompletedOnboarding: Bool
    ) -> NearfieldWindowPresentation {
        hasCompletedOnboarding ? .settings : .onboarding
    }

}
