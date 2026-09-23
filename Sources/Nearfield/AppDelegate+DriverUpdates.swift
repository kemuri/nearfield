import AppKit

extension AppDelegate {
    func refreshDriverUpdateAvailability() {
        availableDriverUpdate = DriverInstaller.availableDriverUpdate()
    }

    func promptForDriverUpdateIfNeeded() {
        guard !isInitialOnboardingInProgress, !isInstallingDriver, !isRemovingDriver,
              !didPromptForDriverUpdate else { return }
        refreshDriverUpdateAvailability()
        guard availableDriverUpdate != nil else { return }
        installAndActivateRouterDriver(.driverUpgrade)
    }

    func confirmDriverUpgrade(_ update: RouterDriverUpdate) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Update Nearfield Audio Driver?"
        alert.informativeText = "Nearfield includes audio driver \(update.availableVersion) with the latest audio fixes. " +
            "Updating requires administrator approval and briefly interrupts system audio. " +
            "You can also update later in Settings."
        alert.addButton(withTitle: "Update Driver")
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
