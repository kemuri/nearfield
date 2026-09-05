enum BalanceMath {
    static func adjustedChannelVolumes(
        currentLeft: Float32,
        currentRight: Float32,
        delta: Float32,
        balance: Float32
    ) -> (left: Float32, right: Float32) {
        let nextVolume = min(max(max(currentLeft, currentRight) + delta, 0), 1)
        return channelVolumes(currentLeft: nextVolume, currentRight: nextVolume, balance: balance)
    }

    static func channelVolumes(
        currentLeft: Float32?,
        currentRight: Float32?,
        balance: Float32,
        minimumBaseVolume: Float32 = 0
    ) -> (left: Float32, right: Float32) {
        let clamped = min(max(balance, -1), 1)
        let baseVolume = max(currentLeft ?? 0, currentRight ?? 0, minimumBaseVolume)
        let left = baseVolume * (clamped > 0 ? 1 - clamped : 1)
        let right = baseVolume * (clamped < 0 ? 1 + clamped : 1)
        return (left, right)
    }
}
