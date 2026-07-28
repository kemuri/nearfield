import AppKit
import ServiceManagement
#if NEARFIELD_DISTRIBUTION
import Sparkle
#endif

extension AppDelegate {
    func configureMenu() {
        statusItem.button?.image = menuBarIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.title = ""
        menu.delegate = self
        applyMenuBarState()
    }

    func menuBarIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "menubar", withExtension: "svg", subdirectory: "Icons") ??
            Bundle.module.url(forResource: "menubar", withExtension: "svg"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "hifispeaker.2", accessibilityDescription: "Nearfield")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Nearfield"
        return image
    }

    @objc func openSettings() {
        guard !isInitialOnboardingInProgress else {
            onboardingWindowController?.show()
            return
        }
        showOnboardingSettingsStage(showsPageIndicator: false)
    }

    @objc func openOnboarding() {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(delegate: self)
        }
        onboardingWindowController?.showOnboardingSimulation()
    }

    #if !NEARFIELD_DISTRIBUTION
    @objc func openOnboardingSettingsStage() {
        showOnboardingSettingsStage(showsPageIndicator: true)
    }
    #endif

    func showOnboardingSettingsStage(showsPageIndicator: Bool) {
        if onboardingWindowController == nil {
            onboardingWindowController = OnboardingWindowController(delegate: self)
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
        let quitItem = NSMenuItem(title: "Quit", action: #selector(confirmQuitHelper), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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
        statusItem.menu = menu
        rebuildMenu()
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
