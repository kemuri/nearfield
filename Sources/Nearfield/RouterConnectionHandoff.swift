import Foundation

/// Owns one connection attempt, including apps starting playback later.
/// HAL access is injected so tests exercise the same sequence as the app.
@MainActor
final class RouterConnectionHandoff {
    struct Playback: Equatable {
        let processID: Int32
        let outputUIDs: Set<String>
    }

    struct Snapshot {
        var displaysConnected: Bool
        var targetReady: Bool
        var defaultOutputUID: String?
        var playback: [Playback] = []
    }

    /// Why the handoff waits before looking again.
    enum Wait {
        /// For the display route to become ready.
        case readiness
        /// For a stale-looking app to prove it really stayed behind (1 s).
        case playbackConfirmation
        /// For anything to change while every app plays where it should.
        case playbackIdle
    }

    struct Environment {
        var snapshot: () throws -> Snapshot
        var prepare: () throws -> Void
        var activate: () throws -> Void
        var selectPreviousOutput: () throws -> Void
        var supportsPlaybackVerification = true
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
        /// Waits for a change notification. Without it the handoff polls:
        /// readiness every 100 ms and playback every second.
        var waitForChange: ((Wait) async throws -> Void)?
    }

    enum Failure: LocalizedError, Equatable {
        case targetNotReady
        case playbackDidNotFollow

        var errorDescription: String? {
            switch self {
            case .targetNotReady:
                "The Studio Display audio route did not become ready. Reconnect the displays and try again."
            case .playbackDidNotFollow:
                "An app is still using the previous sound output. If that is unexpected, select the system output in its audio settings or restart playback."
            }
        }
    }

    let previousOutputUID: String?
    let routerUID: String
    private(set) var isSwitchingOutput = true
    private(set) var isCancelled = false
    private var allowedDefaultUIDs: Set<String>

    init(previousOutputUID: String?, initialDefaultUID: String?, routerUID: String) {
        self.previousOutputUID = previousOutputUID
        self.routerUID = routerUID
        allowedDefaultUIDs = Set([initialDefaultUID, routerUID].compactMap { $0 })
    }

    func cancel() { isCancelled = true }

    func observeDefaultOutput(_ uid: String?) {
        // Called before debouncing device updates, including during the brief
        // recovery switch. An external choice must not be overwritten later.
        if let uid, !allowedDefaultUIDs.contains(uid) { cancel() }
    }

    private func checkedSnapshot(_ environment: Environment) throws -> Snapshot {
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        let snapshot = try environment.snapshot()
        observeDefaultOutput(snapshot.defaultOutputUID)
        guard snapshot.displaysConnected, !isCancelled else { throw CancellationError() }
        return snapshot
    }

    func run(_ environment: Environment) async throws {
        defer { isSwitchingOutput = false }
        let readinessDeadline = environment.now() + 10
        while true {
            try Task.checkCancellation()
            guard !isCancelled else { throw CancellationError() }
            do {
                try environment.prepare()
                break
            } catch RouterAudioDriverError.notInstalled {
                guard environment.now() < readinessDeadline else { throw Failure.targetNotReady }
                try await environment.sleep(100_000_000)
            }
        }
        try await waitUntilReady(environment, deadline: readinessDeadline)

        // Record the expected result before our own default-output notification.
        allowedDefaultUIDs = [routerUID]
        try environment.activate()
        isSwitchingOutput = false
        guard environment.supportsPlaybackVerification else { return }
        try await environment.sleep(750_000_000)

        var previousStaleProcesses = Set<Int32>()
        while true {
            let snapshot = try checkedSnapshot(environment)
            if !snapshot.targetReady {
                try await waitUntilReady(environment, deadline: environment.now() + 10)
                previousStaleProcesses = []
                continue
            }
            let staleProcesses = Set(snapshot.playback.filter {
                guard let previousOutputUID else { return false }
                return $0.outputUIDs == [previousOutputUID]
            }.map(\.processID))
            if !staleProcesses.isEmpty && !staleProcesses.isDisjoint(with: previousStaleProcesses) {
                try await recoverOnce(environment, processes: staleProcesses)
                return
            }
            previousStaleProcesses = staleProcesses
            // A healthy client does not prove that every other client followed.
            // Keep watching for apps that start playback later, until one retry
            // is used or a disconnect/manual output choice ends this handoff.
            try await wait(staleProcesses.isEmpty ? .playbackIdle : .playbackConfirmation, environment)
        }
    }

    private func waitUntilReady(_ environment: Environment, deadline: TimeInterval) async throws {
        while true {
            let snapshot = try checkedSnapshot(environment)
            if snapshot.targetReady { return }
            guard environment.now() < deadline else { throw Failure.targetNotReady }
            try await wait(.readiness, environment)
        }
    }

    private func wait(_ reason: Wait, _ environment: Environment) async throws {
        if let waitForChange = environment.waitForChange {
            try await waitForChange(reason)
            return
        }
        switch reason {
        case .readiness:
            try await environment.sleep(100_000_000)
        case .playbackConfirmation, .playbackIdle:
            try await environment.sleep(1_000_000_000)
        }
    }

    private func recoverOnce(_ environment: Environment, processes: Set<Int32>) async throws {
        guard let previousOutputUID else { throw Failure.playbackDidNotFollow }
        isSwitchingOutput = true
        allowedDefaultUIDs = [previousOutputUID]
        try environment.selectPreviousOutput()
        // Give clients a real default-device transition, then check again for
        // disconnection or a user selection before restoring Nearfield.
        try await environment.sleep(250_000_000)
        try await waitUntilReady(environment, deadline: environment.now() + 10)
        let snapshot = try checkedSnapshot(environment)
        guard snapshot.defaultOutputUID == previousOutputUID, snapshot.targetReady else {
            throw Failure.targetNotReady
        }
        allowedDefaultUIDs = [routerUID]
        try environment.activate()
        isSwitchingOutput = false

        let deadline = environment.now() + 3
        repeat {
            try await environment.sleep(250_000_000)
            let snapshot = try checkedSnapshot(environment)
            let remaining = snapshot.playback.filter { processes.contains($0.processID) }
            if !remaining.isEmpty && remaining.allSatisfy({ $0.outputUIDs == [routerUID] }) { return }
            if remaining.isEmpty { return } // Playback stopped; no further switching.
        } while environment.now() < deadline
        throw Failure.playbackDidNotFollow
    }
}
