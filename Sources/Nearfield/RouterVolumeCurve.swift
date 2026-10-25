import Foundation

/// How Nearfield's volume control maps its scalar onto its decibel range.
enum RouterVolumeCurve: CaseIterable {
    /// Drivers before 1.2.0: linear in decibels.
    case linearDecibels
    /// Driver 1.2.0 and later: the Studio Displays' own curve, so the same
    /// volume plays as loud on Nearfield as on a display alone.
    case display

    static let firstDisplayCurveDriver = RouterDriverVersion("1.2.0")!

    func decibels(forScalar scalar: Float32, minimum: Float32, span: Float32) -> Float32 {
        let scalar = min(max(scalar, 0), 1)
        switch self {
        case .linearDecibels:
            return minimum + scalar * span
        case .display:
            return minimum + scalar.squareRoot() * span
        }
    }

    func scalar(forDecibels decibels: Float32, minimum: Float32, span: Float32) -> Float32 {
        let position = min(max((decibels - minimum) / span, 0), 1)
        switch self {
        case .linearDecibels:
            return position
        case .display:
            return position * position
        }
    }

    /// The curve that explains the decibels a driver reports for |scalar|.
    /// Core Audio does not pass the driver's own conversion through to apps.
    static func matching(
        scalar: Float32,
        reportedDecibels: Float32,
        minimum: Float32,
        span: Float32
    ) -> RouterVolumeCurve? {
        [.display, .linearDecibels].first { curve in
            abs(curve.decibels(forScalar: scalar, minimum: minimum, span: span) - reportedDecibels) < 0.5
        }
    }

    /// Whether upgrading the driver from |installed| to |available| moves
    /// Nearfield's volume onto the display curve.
    static func upgradeChangesCurve(from installed: String?, to available: String) -> Bool {
        guard let installed = installed.flatMap(RouterDriverVersion.init),
              let available = RouterDriverVersion(available) else {
            return false
        }
        return installed < firstDisplayCurveDriver && available >= firstDisplayCurveDriver
    }

    /// The display-curve scalar that plays as loud as |scalar| did on the
    /// linear curve, so a driver upgrade does not change the level.
    static func displayScalarKeepingLevel(ofLinearScalar scalar: Float32) -> Float32 {
        let scalar = min(max(scalar, 0), 1)
        return scalar * scalar
    }
}
