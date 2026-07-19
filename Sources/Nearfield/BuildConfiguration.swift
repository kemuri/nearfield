enum BuildConfiguration {
    #if NEARFIELD_DISTRIBUTION
    static let isDistribution = true
    static let debugToolsEnabled = false
    #else
    static let isDistribution = false
    static let debugToolsEnabled = true
    #endif
}
