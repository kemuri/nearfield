import Foundation

/// Makes Nearfield the Mac's output and remembers which displays are prepared
/// for it (unmuted at full volume, with Nearfield controlling the volume).
///
/// The displays' settings are captured first, then Nearfield is selected, and
/// only then are the displays raised. Until they are, Nearfield plays quieter
/// than intended, never louder, and sound still playing on a display that was
/// the output does not jump in volume. If any step fails, the displays are
/// put back as they were.
///
/// Restoring the displays always goes through here, so the preparation is
/// never considered current after their settings were put back.
@MainActor
final class RouterOutputActivation {
    struct Operations {
        /// Nearfield's volume before anything changes, for continuity.
        var currentRouterVolume: () -> Float32?
        /// Records the displays' volume and mute; returns their average volume
        /// when this is the first capture.
        var captureDisplays: () throws -> Float32?
        /// Sets Nearfield's volume (from the current and captured volumes) and balance.
        var setRouterVolume: (_ currentRouterVolume: Float32?, _ capturedDisplayVolume: Float32?) throws -> Void
        var selectRouter: () throws -> Void
        /// Unmutes the displays and sets them to full volume.
        var raiseDisplays: () throws -> Void
        /// Puts the displays back to their captured settings.
        var restoreDisplays: () throws -> Void
        var routerIsDefault: () -> Bool
        var applyBalance: () throws -> Void
    }

    private let operations: Operations
    /// The displays prepared for Nearfield, in order.
    private(set) var preparedDisplayUIDs: [String]?

    init(operations: Operations) {
        self.operations = operations
    }

    func activate(displayUIDs: [String]) throws {
        preparedDisplayUIDs = nil
        let currentRouterVolume = operations.currentRouterVolume()
        let capturedDisplayVolume = try operations.captureDisplays()
        do {
            try operations.setRouterVolume(currentRouterVolume, capturedDisplayVolume)
            try operations.selectRouter()
            try operations.raiseDisplays()
        } catch {
            try? restoreDisplays()
            throw error
        }
        preparedDisplayUIDs = displayUIDs
    }

    /// Activates unless Nearfield is already the output with these displays
    /// prepared, in which case only the balance is applied.
    func activateIfNeeded(displayUIDs: [String]) throws {
        if preparedDisplayUIDs == displayUIDs, operations.routerIsDefault() {
            try operations.applyBalance()
            return
        }
        try activate(displayUIDs: displayUIDs)
    }

    func restoreDisplays() throws {
        preparedDisplayUIDs = nil
        try operations.restoreDisplays()
    }

    /// Forget the preparation, for example when Nearfield stopped being the output.
    func invalidate() {
        preparedDisplayUIDs = nil
    }
}
