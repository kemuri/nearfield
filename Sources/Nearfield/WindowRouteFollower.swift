import CoreGraphics
import Foundation

/// Follows routed apps' windows between displays without using the main
/// thread. While window-scoped routes are active it checks every 2 seconds,
/// and immediately when asked to (playback starts, an app comes to the front,
/// the Space or the screens change). Window lists are read on its own queue
/// against cached snapshots of the running apps and the screen-to-display map.
///
/// Results are delivered only while they are current: stopping or changing
/// the configuration discards results computed before, even ones already on
/// their way to the main thread.
final class WindowRouteFollower: @unchecked Sendable {
    typealias RunningApplication = WindowAudioRouteResolver.RunningApplication
    typealias DisplayTarget = WindowAudioRouteResolver.DisplayTarget

    static let checkInterval: TimeInterval = 2
    static let immediateCheckCoalescing: DispatchTimeInterval = .milliseconds(50)

    private struct Configuration: Equatable {
        var runningApplications: [RunningApplication] = []
        var displayTargets: [DisplayTarget] = []
        var rawRules = ""
    }

    private let queue = DispatchQueue(label: "com.kemuri.Nearfield.window-routes", qos: .utility)
    private let publish: @MainActor (String) -> Void

    // Shared between threads; protected by |lock|. The generation changes
    // with the configuration and when following starts or stops.
    private let lock = NSLock()
    private var configuration = Configuration()
    private var generation: UInt64 = 0
    private var isActive = false

    // Confined to |queue|.
    private var checkedConfiguration = Configuration()
    private var timer: DispatchSourceTimer?
    private var lastResult: (generation: UInt64, rules: String)?
    private var immediateCheckScheduled = false
    private lazy var resolver = WindowAudioRouteResolver(
        runningApplications: { [unowned self] in self.checkedConfiguration.runningApplications },
        windowList: {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
        },
        displayTargets: { [unowned self] in self.checkedConfiguration.displayTargets }
    )

    /// |publish| receives resolved rules on the main thread when they change.
    init(publish: @escaping @MainActor (String) -> Void) {
        self.publish = publish
    }

    func update(
        runningApplications: [RunningApplication],
        displayTargets: [DisplayTarget],
        rawRules: String
    ) {
        let next = Configuration(
            runningApplications: runningApplications,
            displayTargets: displayTargets,
            rawRules: rawRules
        )
        let shouldCheck = lock.withLock {
            guard configuration != next else { return false }
            configuration = next
            generation &+= 1
            return isActive
        }
        if shouldCheck {
            queue.async { self.check() }
        }
    }

    /// Starts the periodic check (and checks once right away).
    func start() {
        let started = lock.withLock {
            guard !isActive else { return false }
            isActive = true
            generation &+= 1
            return true
        }
        guard started else { return }
        queue.async {
            self.timer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(
                deadline: .now(),
                repeating: Self.checkInterval,
                leeway: .milliseconds(250)
            )
            // Cancelled in stop(), which releases this reference.
            timer.setEventHandler { self.check() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        let stopped = lock.withLock {
            guard isActive else { return false }
            isActive = false
            generation &+= 1
            return true
        }
        guard stopped else { return }
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.lastResult = nil
        }
    }

    /// An immediate check, if following is active. Requests arriving in a
    /// burst (several apps starting at once) share one check.
    func checkNow() {
        queue.async {
            guard self.timer != nil, !self.immediateCheckScheduled else { return }
            self.immediateCheckScheduled = true
            self.queue.asyncAfter(deadline: .now() + Self.immediateCheckCoalescing) {
                self.immediateCheckScheduled = false
                self.check()
            }
        }
    }

    /// Waits until work already queued has run. For tests.
    func waitForQueuedWork() {
        queue.sync {}
    }

    private func check() {
        let (configuration, generation, isActive) = lock.withLock {
            (self.configuration, self.generation, self.isActive)
        }
        guard isActive else { return }
        checkedConfiguration = configuration
        let resolved = resolver.resolvedRules(from: configuration.rawRules)
        // A new generation always delivers: the previous generation's result
        // may have been discarded on its way.
        if let lastResult, lastResult.generation == generation, lastResult.rules == resolved {
            return
        }
        lastResult = (generation, resolved)
        let publish = self.publish
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard self.isCurrent(generation) else { return }
                publish(resolved)
            }
        }
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { isActive && self.generation == generation }
    }
}
