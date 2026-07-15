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

    static func shouldPublishRouter(studioDisplayCount: Int) -> Bool {
        studioDisplayCount >= 2
    }
}
