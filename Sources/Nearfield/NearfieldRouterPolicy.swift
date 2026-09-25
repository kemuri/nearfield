enum NearfieldRouterPolicy {
    static func shouldActivateRouter(
        defaultOutputIsNearfield: Bool,
        displaysJustConnected: Bool,
        connectionActivationPending: Bool
    ) -> Bool {
        defaultOutputIsNearfield || displaysJustConnected || connectionActivationPending
    }

    static func shouldConfigureRouterAfterDriverInstall(studioDisplayCount: Int) -> Bool {
        studioDisplayCount >= 2
    }

    static func shouldAttemptDriverInstall(
        studioDisplayCount: Int,
        allowsMissingStudioDisplays: Bool
    ) -> Bool {
        allowsMissingStudioDisplays || shouldConfigureRouterAfterDriverInstall(
            studioDisplayCount: studioDisplayCount
        )
    }

    static func shouldCompleteDriverInstallWithoutActivation(
        currentDriverIsInstalledOnDisk: Bool,
        allowsMissingStudioDisplays: Bool
    ) -> Bool {
        currentDriverIsInstalledOnDisk &&
            allowsMissingStudioDisplays
    }

    static func shouldCompleteOnboardingAfterDriverInstall(
        driverInstalled: Bool,
        routerSelected: Bool,
        allowsMissingStudioDisplays: Bool
    ) -> Bool {
        guard driverInstalled else { return false }
        return routerSelected || allowsMissingStudioDisplays
    }

    static func shouldPublishRouter(studioDisplayCount: Int) -> Bool {
        studioDisplayCount >= 2
    }

    static func shouldShowFullMenuBarMenu(isInitialOnboardingInProgress: Bool) -> Bool {
        !isInitialOnboardingInProgress
    }
}
