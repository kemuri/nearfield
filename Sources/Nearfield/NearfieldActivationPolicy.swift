enum NearfieldActivationPolicy {
    static func shouldActivateRouter(
        defaultOutputIsNearfield: Bool,
        displaysJustReconnected: Bool,
        shouldReactivateAfterReconnect: Bool
    ) -> Bool {
        defaultOutputIsNearfield || (displaysJustReconnected && shouldReactivateAfterReconnect)
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

    static func shouldCompleteOnboardingAfterDriverInstall(
        driverInstalled: Bool,
        routerSelected: Bool,
        studioDisplayCount: Int,
        allowsMissingStudioDisplays: Bool
    ) -> Bool {
        guard driverInstalled else { return false }
        return routerSelected || (
            allowsMissingStudioDisplays &&
                !shouldConfigureRouterAfterDriverInstall(studioDisplayCount: studioDisplayCount)
        )
    }

    static func shouldPublishRouter(studioDisplayCount: Int) -> Bool {
        studioDisplayCount >= 2
    }

    static func shouldShowFullMenuBarMenu(isInitialOnboardingInProgress: Bool) -> Bool {
        !isInitialOnboardingInProgress
    }
}
