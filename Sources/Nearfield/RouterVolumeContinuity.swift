struct RouterVolumeContinuity {
    private(set) var lastKnownVolume: Float32?

    mutating func observe(_ volume: Float32?) {
        guard let volume = Self.normalized(volume) else { return }
        lastKnownVolume = volume
    }

    /// The remembered volume, moved onto the display curve with its level kept.
    mutating func keepLevelAfterCurveChange() {
        lastKnownVolume = lastKnownVolume.map(RouterVolumeCurve.displayScalarKeepingLevel(ofLinearScalar:))
    }

    func activationVolume(
        currentRouterVolume: Float32?,
        capturedDisplayVolume: Float32?
    ) -> Float32? {
        Self.normalized(currentRouterVolume) ??
            lastKnownVolume ??
            Self.normalized(capturedDisplayVolume)
    }

    private static func normalized(_ volume: Float32?) -> Float32? {
        guard let volume, volume.isFinite else { return nil }
        return min(max(volume, 0), 1)
    }
}
