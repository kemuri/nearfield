import Foundation

/// Nearfield's Character setting: the share of the Studio Displays' own
/// low-volume bass boost that Nearfield removes (driver 1.3.0 and later).
enum RouterCharacter: Int, CaseIterable {
    /// The displays' own tuning: more bass the quieter they play.
    case studioDisplay
    case warm
    case balanced
    /// The balance the displays have at full volume, at every volume.
    case neutral

    /// The amount the driver takes, 0...1.
    var amount: Double {
        Double(rawValue) / Double(Self.allCases.count - 1)
    }

    var title: String {
        switch self {
        case .studioDisplay: "Studio Display"
        case .warm: "Warm"
        case .balanced: "Balanced"
        case .neutral: "Neutral"
        }
    }

    /// The nearest stop to |amount|.
    init(amount: Double) {
        let steps = Double(Self.allCases.count - 1)
        let index = Int((min(max(amount, 0), 1) * steps).rounded())
        self = Self(rawValue: index) ?? .studioDisplay
    }
}
