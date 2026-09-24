import Foundation

/// Makes Nearfield the Mac's output and remembers which displays are prepared
/// for it (unmuted at full volume, with Nearfield controlling the volume).
///
/// Nothing may get louder on the way:
/// - The displays' settings are captured first, then Nearfield is selected,
///   and only then are the displays raised. Until they are, Nearfield plays
///   quieter than intended, never louder.
/// - A display another app plays on directly (an app set to use that display,
///   or one that has not followed the switch yet) is not raised, since that
///   app would get louder too. The displays wait at their own volume, and
///   Nearfield's volume makes up the difference. Once no other app plays on
///   them, Nearfield's volume is lowered by the same amount and then the
///   displays are raised. When waiting ends otherwise, the extra volume is
///   taken back.
/// - If any step fails, the displays are put back as they were.
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
        /// Target displays another app plays on directly, not through Nearfield.
        var displaysWithOtherPlayback: (_ displayUIDs: [String]) -> Set<String>
        /// Decibels that setting the displays to full volume adds (the largest among them).
        var displayRaiseDecibels: (_ displayUIDs: [String]) -> Float32
        /// Moves Nearfield's volume by some decibels, keeping the balance;
        /// returns the change applied.
        var shiftRouterVolume: (_ decibels: Float32) throws -> Float32
        /// Unmutes the displays and sets them to full volume.
        var raiseDisplays: () throws -> Void
        /// Puts the displays back to their captured settings.
        var restoreDisplays: () throws -> Void
        var routerIsDefault: () -> Bool
        var applyBalance: () throws -> Void
        /// Keeps the volume added while waiting across a quit or crash, so it
        /// can be taken back at the next launch.
        var saveWaitingCompensation: (_ decibels: Float32) -> Void = { _ in }
    }

    private let operations: Operations
    /// The displays prepared for Nearfield, in order.
    private(set) var preparedDisplayUIDs: [String]?
    /// Displays waiting to be raised until no other app plays on them.
    private(set) var waitingDisplayUIDs: [String]? {
        didSet {
            if oldValue != waitingDisplayUIDs { onWaitingChange?() }
        }
    }
    /// Decibels added to Nearfield's volume while its displays wait.
    private var waitingCompensation: Float32 = 0 {
        didSet {
            if oldValue != waitingCompensation { operations.saveWaitingCompensation(waitingCompensation) }
        }
    }
    /// Called when displays start or stop waiting.
    var onWaitingChange: (() -> Void)?

    init(operations: Operations) {
        self.operations = operations
    }

    func activate(displayUIDs: [String]) throws {
        stopWaiting()
        preparedDisplayUIDs = nil
        let currentRouterVolume = operations.currentRouterVolume()
        let capturedDisplayVolume = try operations.captureDisplays()
        do {
            try operations.setRouterVolume(currentRouterVolume, capturedDisplayVolume)
            try operations.selectRouter()
            if operations.displaysWithOtherPlayback(displayUIDs).isEmpty {
                try operations.raiseDisplays()
                preparedDisplayUIDs = displayUIDs
            } else {
                waitingDisplayUIDs = displayUIDs
                waitingCompensation = try operations.shiftRouterVolume(operations.displayRaiseDecibels(displayUIDs))
            }
        } catch {
            try? restoreDisplays()
            throw error
        }
    }

    /// Activates unless Nearfield is already the output with these displays
    /// prepared (or waiting), in which case only the balance is applied.
    func activateIfNeeded(displayUIDs: [String]) throws {
        if waitingDisplayUIDs == displayUIDs, operations.routerIsDefault() {
            try raiseWaitingDisplaysIfFree()
            try operations.applyBalance()
            return
        }
        if preparedDisplayUIDs == displayUIDs, operations.routerIsDefault() {
            try operations.applyBalance()
            return
        }
        try activate(displayUIDs: displayUIDs)
    }

    /// Raises waiting displays once no other app plays on them: Nearfield's
    /// volume is lowered first by what raising the displays adds.
    func raiseWaitingDisplaysIfFree() throws {
        guard let displayUIDs = waitingDisplayUIDs else { return }
        guard operations.routerIsDefault() else {
            stopWaiting()
            return
        }
        guard operations.displaysWithOtherPlayback(displayUIDs).isEmpty else { return }
        _ = try operations.shiftRouterVolume(-operations.displayRaiseDecibels(displayUIDs))
        waitingCompensation = 0
        waitingDisplayUIDs = nil
        // A failure leaves Nearfield quieter, never louder; the next
        // activation prepares the displays again.
        try operations.raiseDisplays()
        preparedDisplayUIDs = displayUIDs
    }

    func restoreDisplays() throws {
        stopWaiting()
        preparedDisplayUIDs = nil
        try operations.restoreDisplays()
    }

    /// Forget the preparation, for example when Nearfield stopped being the output.
    func invalidate() {
        stopWaiting()
        preparedDisplayUIDs = nil
    }

    /// Stops waiting and takes back the volume added while waiting.
    private func stopWaiting() {
        guard waitingDisplayUIDs != nil else { return }
        if waitingCompensation != 0 {
            _ = try? operations.shiftRouterVolume(-waitingCompensation)
        }
        waitingCompensation = 0
        waitingDisplayUIDs = nil
    }
}
