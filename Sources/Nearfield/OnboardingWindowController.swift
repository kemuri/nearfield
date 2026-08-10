import AppKit
import SwiftUI

enum OnboardingLayout {
    static let scale: CGFloat = 1
    static let baseSize = NSSize(width: 307, height: 536)
    static let contentWidth = baseSize.width - 32
    static let ditherImageWidth = baseSize.width + 36.5
    static let expandedHeaderHeight: CGFloat = 345
    static let windowSize = NSSize(width: baseSize.width * scale, height: baseSize.height * scale)
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private final class ShortcutWindow: NSWindow {
        var shortcutHandler: ((NSEvent) -> Bool)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if shortcutHandler?(event) == true {
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func keyDown(with event: NSEvent) {
            if shortcutHandler?(event) == true {
                return
            }
            super.keyDown(with: event)
        }
    }

    private enum Metrics {
        static let size = OnboardingLayout.windowSize
    }

    private let model: OnboardingModel
    private weak var hostingView: NSView?

    init(delegate: SettingsDelegate) {
        let model = OnboardingModel(delegate: delegate)
        self.model = model

        let contentRect = NSRect(origin: .zero, size: Metrics.size)
        let window = ShortcutWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Keep the title bar draggable, but let arrangement cards receive
        // mouse drags instead of moving the entire window.
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        let fixedFrameSize = window.frameRect(forContentRect: contentRect).size
        window.minSize = fixedFrameSize
        window.maxSize = fixedFrameSize
        window.center()

        super.init(window: window)

        window.delegate = self
        if BuildConfiguration.debugToolsEnabled {
            window.shortcutHandler = { [weak self] event in
                self?.handleStepShortcut(event) ?? false
            }
        }

        let hostingView = NSHostingView(rootView: OnboardingRootView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: Metrics.size)
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        self.hostingView = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        model.cancelInstallSimulation()
        // Stop the header animation so the helper doesn't keep rendering frames
        // for a window that's no longer on screen.
        model.headerPaused = true
        model.setWindowVisible(false)
        super.close()
    }

    func show(playsIntro: Bool = false) {
        reload()
        model.headerPaused = false
        model.setWindowVisible(true)
        let shouldFadeWindow = playsIntro || window?.isVisible != true
        if shouldFadeWindow {
            window?.alphaValue = 0
        } else {
            window?.alphaValue = 1
        }
        if playsIntro {
            model.beginIntroAnimation()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if playsIntro {
            animateWindowIntoFocus()
        } else if shouldFadeWindow {
            animateWindowFadeIn(duration: 0.18)
        }
        updateWindowLevel()
        updateWindowAppearance()
    }

    private func animateWindowFadeIn(duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window?.animator().alphaValue = 1
        }
    }

    private func animateWindowIntoFocus() {
        guard let window else { return }

        let finalFrame = window.frame
        let initialFrame = finalFrame.insetBy(dx: 4, dy: 4)
        window.setFrame(initialFrame, display: false)

        let blurFilter = CIFilter(name: "CIGaussianBlur")
        blurFilter?.name = "introWindowBlur"
        blurFilter?.setValue(14, forKey: kCIInputRadiusKey)

        if let hostingView {
            hostingView.wantsLayer = true
            hostingView.layer?.masksToBounds = true
            hostingView.layer?.filters = blurFilter.map { [$0] }
            let blurAnimation = CABasicAnimation(keyPath: "filters.introWindowBlur.inputRadius")
            blurAnimation.fromValue = 14
            blurAnimation.toValue = 0
            blurAnimation.duration = 0.72
            blurAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            hostingView.layer?.add(blurAnimation, forKey: "introWindowBlur")
            blurFilter?.setValue(0, forKey: kCIInputRadiusKey)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.78) { [weak hostingView] in
                hostingView?.layer?.filters = nil
            }
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.72
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        }
    }

    func showOnboardingSimulation() {
        model.showOnboardingSimulation()
        show(playsIntro: true)
    }

    func showSettingsStage(showsPageIndicator: Bool = true) {
        model.showSettingsStage(showsPageIndicator: showsPageIndicator)
        show()
    }

    func reload() {
        let wasInstallingDriver = model.isInstallingDriver
        model.refreshFromDelegate()
        updateWindowLevel()
        if model.isInstallingDriver, !wasInstallingDriver {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Pause the header animation whenever the window isn't actually on screen
    // (covered, minimized, on another Space, or closed) so it doesn't burn CPU.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        let isVisible = window.occlusionState.contains(.visible)
        model.headerPaused = !isVisible
        model.setWindowVisible(isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        model.headerPaused = true
        model.setWindowVisible(false)
    }

    private func handleStepShortcut(_ event: NSEvent) -> Bool {
        guard BuildConfiguration.debugToolsEnabled else { return false }
        let disallowedModifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard disallowedModifiers.isEmpty else {
            return false
        }
        let slowMotion = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 18:
            model.showStep(.welcome, slowMotion: slowMotion)
        case 19:
            model.showStep(.install, slowMotion: slowMotion)
        case 20:
            model.showStep(.settings, slowMotion: slowMotion)
        default:
            guard let characters = event.charactersIgnoringModifiers,
                  characters.count == 1 else {
                return false
            }
            switch characters.lowercased() {
            case "h":
                model.toggleHeaderGraphic()
            case "l":
                model.toggleDebugColorSchemeOverride()
                updateWindowAppearance()
            #if !NEARFIELD_DISTRIBUTION
            case "m":
                model.cycleDebugDisplayScenario()
            #endif
            case "a":
                guard model.step == .install else { return false }
                model.runInstallScenario(.smooth)
            case "s":
                guard model.step == .install else { return false }
                model.runInstallScenario(.permissionFailure)
            default:
                return false
            }
        }
        return true
    }

    private func updateWindowAppearance() {
        guard let override = model.debugColorSchemeOverride else {
            window?.appearance = nil
            return
        }
        window?.appearance = NSAppearance(named: override == .light ? .aqua : .darkAqua)
    }

    private func updateWindowLevel() {
        window?.level = model.isInstallingDriver ? .floating : .normal
    }
}
