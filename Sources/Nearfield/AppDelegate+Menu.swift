import AppKit
import ServiceManagement
#if NEARFIELD_DISTRIBUTION
import Sparkle
#endif

enum NearfieldApplicationMenuConfiguration {
    static let quitTitle = "Quit Nearfield"
    static let quitKeyEquivalent = "q"
    static let quitModifierMask: NSEvent.ModifierFlags = [.command]
}

extension AppDelegate {
    func configureMenu() {
        configureApplicationMenu()
        statusItem.button?.image = menuBarIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""
        statusItem.button?.toolTip = "Nearfield"
        menu.delegate = self
        applyMenuBarState()
    }

    /// Accessory apps do not receive the standard application menu that
    /// normally owns Command-Q. Keep a minimal, invisible main menu so AppKit
    /// can resolve the shortcut even when the status-item menu is closed.
    func configureApplicationMenu() {
        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            makeQuitMenuItem(title: NearfieldApplicationMenuConfiguration.quitTitle)
        )

        let applicationMenuItem = NSMenuItem()
        applicationMenuItem.submenu = applicationMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem)
        NSApp.mainMenu = mainMenu
    }

    func menuBarIcon() -> NSImage? {
        guard let url = NearfieldResources.menuBarIconURL(),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "hifispeaker.2", accessibilityDescription: "Nearfield")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Nearfield"
        return image
    }

    @objc func openSettings() {
        refreshDriverInstallState()
        guard !isInitialOnboardingInProgress else {
            if let onboardingWindowController {
                onboardingWindowController.show()
            } else {
                openOnboarding()
            }
            return
        }
        showOnboardingSettingsStage(showsPageIndicator: false)
    }

    func presentPrimaryWindow() {
        switch NearfieldLaunchPolicy.reopenPresentation(
            hasCompletedOnboarding: !isInitialOnboardingInProgress
        ) {
        case .onboarding:
            if let onboardingWindowController {
                onboardingWindowController.show()
            } else {
                openOnboarding()
            }
        case .settings:
            openSettings()
        case .none:
            break
        }
    }

    @objc func openOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = makeOnboardingWindowController()
        }
        onboardingWindowController?.showOnboardingSimulation()
    }

    /// Once closed, the window, its SwiftUI views, the model, the animated
    /// header and the app icons are released. First-run onboarding keeps its
    /// window so it resumes at the same step.
    func makeOnboardingWindowController() -> OnboardingWindowController {
        // It may have changed in System Settings while the window was closed.
        cachedOpenAtLogin = nil
        let controller = OnboardingWindowController(delegate: self)
        controller.onClose = { [weak self, weak controller] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let controller,
                          self.onboardingWindowController === controller,
                          !self.isInitialOnboardingInProgress,
                          controller.window?.isVisible != true else { return }
                    self.onboardingWindowController = nil
                }
            }
        }
        return controller
    }

    #if !NEARFIELD_DISTRIBUTION
    @objc func openOnboardingSettingsStage() {
        showOnboardingSettingsStage(showsPageIndicator: true)
    }
    #endif

    func showOnboardingSettingsStage(showsPageIndicator: Bool) {
        if onboardingWindowController == nil {
            onboardingWindowController = makeOnboardingWindowController()
        }
        onboardingWindowController?.showSettingsStage(showsPageIndicator: showsPageIndicator)
    }

    #if !NEARFIELD_DISTRIBUTION
    @objc func openWaveLab() {
        if waveLabWindowController == nil {
            waveLabWindowController = WaveLabWindowController()
        }
        waveLabWindowController?.show()
    }
    #endif

    func setOpenAtLogin(_ enabled: Bool) {
        cachedOpenAtLogin = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showError(error)
        }
        refreshStatus()
    }

    func rebuildMenu() {
        menu.removeAllItems()

        guard NearfieldRouterPolicy.shouldShowFullMenuBarMenu(
            isInitialOnboardingInProgress: isInitialOnboardingInProgress
        ) else {
            let setupItem = NSMenuItem(title: "Continue Setup…", action: #selector(openSettings), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)
            menu.addItem(.separator())
            addQuitMenuItem()
            return
        }

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        #if NEARFIELD_DISTRIBUTION
        if let updaterController {
            let updatesItem = NSMenuItem(
                title: "Check for Updates...",
                action: #selector(checkForUpdates),
                keyEquivalent: ""
            )
            updatesItem.target = self
            updatesItem.isEnabled = updaterController.updater.canCheckForUpdates
            menu.addItem(updatesItem)
        }
        if pendingUpdateInstallation != nil {
            let installUpdateItem = NSMenuItem(
                title: "Install Update and Relaunch",
                action: #selector(installPendingUpdateFromMenu),
                keyEquivalent: ""
            )
            installUpdateItem.target = self
            menu.addItem(installUpdateItem)
        }
        #endif

        menu.addItem(.separator())

        #if !NEARFIELD_DISTRIBUTION
        let onboardingItem = NSMenuItem(title: "Onboarding", action: #selector(openOnboarding), keyEquivalent: "")
        onboardingItem.target = self
        menu.addItem(onboardingItem)

        let setupItem = NSMenuItem(title: "Setup", action: #selector(openOnboardingSettingsStage), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        let waveLabItem = NSMenuItem(title: "Wave Lab", action: #selector(openWaveLab), keyEquivalent: "")
        waveLabItem.target = self
        menu.addItem(waveLabItem)
        #endif

        addQuitMenuItem()
    }

    #if NEARFIELD_DISTRIBUTION
    @objc func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    @objc func installPendingUpdateFromMenu() {
        installPendingUpdate()
    }
    #endif

    func addQuitMenuItem() {
        menu.addItem(makeQuitMenuItem(title: "Quit"))
    }

    func makeQuitMenuItem(title: String) -> NSMenuItem {
        let quitItem = NSMenuItem(
            title: title,
            action: #selector(confirmQuitHelper),
            keyEquivalent: NearfieldApplicationMenuConfiguration.quitKeyEquivalent
        )
        quitItem.keyEquivalentModifierMask =
            NearfieldApplicationMenuConfiguration.quitModifierMask
        quitItem.target = self
        return quitItem
    }

    @objc func confirmQuitHelper() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Nearfield Helper?"
        alert.informativeText = "Quitting the helper will probably result in degraded performance for Nearfield. It keeps routing and audio state in sync while you use the virtual output."
        alert.addButton(withTitle: "Quit Helper")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        NSApp.terminate(nil)
    }

    func applyMenuBarState() {
        statusItem.isVisible = showMenuBarApp()
        statusItem.button?.isEnabled = true
        rebuildMenu()
        // Let AppKit own menu tracking, screen-edge placement, and appearance.
        statusItem.menu = menu
    }

    func showMenuBarApp() -> Bool {
        NearfieldPreferences.showMenuBarApp()
    }

}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }
}
