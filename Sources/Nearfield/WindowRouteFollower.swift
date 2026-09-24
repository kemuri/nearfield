import CoreGraphics
import Foundation

/// Follows routed apps' windows between displays without using the main
/// thread. While window-scoped routes are active it checks every 2 seconds,
/// and immediately when asked to (playback starts, an app comes to the front,
/// the Space or the screens change). Window lists are read on its own queue
/// against cached snapshots of the running apps and the screen-to-display map.
final class WindowRouteFollower: @unchecked Sendable {
    typealias RunningApplication = WindowAudioRouteResolver.RunningApplication
    typealias DisplayTarget = WindowAudioRouteResolver.DisplayTarget

    static let checkInterval: TimeInterval = 2
    static let immediateCheckCoalescing: DispatchTimeInterval = .milliseconds(50)

    private let queue = DispatchQueue(label: "com.kemuri.Nearfield.window-routes", qos: .utility)
    private let publish: @MainActor (String) -> Void

    // Confined to |queue|.
    private var runningApplications: [RunningApplication] = []
    private var displayTargets: [DisplayTarget] = []
    private var rawRules = ""
    private var timer: DispatchSourceTimer?
    private var lastResolvedRules: String?
    private var immediateCheckScheduled = false
    private lazy var resolver = WindowAudioRouteResolver(
        runningApplications: { [unowned self] in self.runningApplications },
        windowList: {
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
        },
        displayTargets: { [unowned self] in self.displayTargets }
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
        queue.async {
            let changed = self.runningApplications != runningApplications ||
                self.displayTargets != displayTargets ||
                self.rawRules != rawRules
            self.runningApplications = runningApplications
            self.displayTargets = displayTargets
            self.rawRules = rawRules
            if changed, self.timer != nil {
                self.check()
            }
        }
    }

    /// Starts the periodic check (and checks once right away).
    func start() {
        queue.async {
            guard self.timer == nil else { return }
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
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.lastResolvedRules = nil
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
                guard self.timer != nil else { return }
                self.check()
            }
        }
    }

    private func check() {
        let resolved = resolver.resolvedRules(from: rawRules)
        guard resolved != lastResolvedRules else { return }
        lastResolvedRules = resolved
        let publish = self.publish
        DispatchQueue.main.async {
            MainActor.assumeIsolated { publish(resolved) }
        }
    }
}
