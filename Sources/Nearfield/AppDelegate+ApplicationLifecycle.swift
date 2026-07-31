import AppKit
import CoreServices
import Darwin

extension AppDelegate {
    func moveToApplicationsIfNeeded() -> Bool {
        guard !ProcessInfo.processInfo.arguments.contains("--skip-move-prompt") else {
            return false
        }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard bundleURL.pathExtension == "app",
              !isInApplicationsDirectory(bundleURL) else {
            return false
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Nearfield to Applications?"
        alert.informativeText = "Nearfield works best from the Applications folder. Move it there before continuing setup?"
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        let destinationURL = URL(fileURLWithPath: "/Applications/Nearfield.app", isDirectory: true)
        do {
            try ApplicationMover.installBundle(from: bundleURL, to: destinationURL)
            try relaunchFromApplications(at: destinationURL)
            NSApp.terminate(nil)
            return true
        } catch {
            let failureAlert = NSAlert(error: error)
            failureAlert.messageText = "Nearfield could not be moved"
            failureAlert.informativeText = "You can move Nearfield.app to Applications manually. Setup will continue from the current location."
            failureAlert.runModal()
            return false
        }
    }

    func isInApplicationsDirectory(_ bundleURL: URL) -> Bool {
        let parentURL = bundleURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return parentURL.path == applicationsURL.path
    }

    func relaunchFromApplications(at appURL: URL) throws {
        guard NSWorkspace.shared.open(appURL) else {
            throw NSError(
                domain: "com.kemuri.Nearfield",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not launch Nearfield from Applications."]
            )
        }
    }

    func startApplicationRemovalMonitorIfNeeded() {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard applicationRemovalMonitor == nil,
              isInApplicationsDirectory(bundleURL) else {
            return
        }

        let fileDescriptor = Darwin.open(bundleURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.delete, .rename],
            queue: .main
        )
        monitor.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleApplicationRemovalEvent(bundleURL: bundleURL)
            }
        }
        monitor.setCancelHandler {
            Darwin.close(fileDescriptor)
        }
        applicationRemovalMonitor = monitor
        monitor.resume()
    }

    func stopApplicationRemovalMonitor() {
        applicationRemovalMonitor?.cancel()
        applicationRemovalMonitor = nil
    }

    func handleApplicationRemovalEvent(bundleURL: URL) {
        guard !didPromptForDriverUninstallAfterApplicationRemoval else {
            return
        }

        // Finder, an installer, and Sparkle replace an application bundle by
        // briefly removing/renaming the old bundle before putting the new one
        // at the same path. Treat the event as a real uninstall only if the
        // path remains absent throughout a replacement grace period.
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self,
                      !self.didPromptForDriverUninstallAfterApplicationRemoval else {
                    return
                }
                if FileManager.default.fileExists(atPath: bundleURL.path) {
                    if ApplicationReplacementRelauncher
                        .replacementSatisfiesCurrentApplicationRequirement(
                            at: bundleURL
                        ) {
                        self.relaunchAfterApplicationReplacement(at: bundleURL)
                        return
                    }
                    continue
                }
            }
            if FileManager.default.fileExists(atPath: bundleURL.path),
               let self {
                self.recordRecoverableError(
                    self.applicationRemovalError(
                        "The replacement Nearfield.app could not be verified."
                    ),
                    context: "Application replacement failed"
                )
                return
            }
            self?.promptForDriverUninstallIfApplicationWasRemoved(bundleURL: bundleURL)
        }
    }

    func relaunchAfterApplicationReplacement(at bundleURL: URL) {
        guard !didPromptForDriverUninstallAfterApplicationRemoval else {
            return
        }

        do {
            try ApplicationReplacementRelauncher.scheduleRelaunch(
                afterProcessExits: ProcessInfo.processInfo.processIdentifier,
                applicationURL: bundleURL
            )
            didPromptForDriverUninstallAfterApplicationRemoval = true
            stopApplicationRemovalMonitor()
            NSApp.terminate(nil)
        } catch {
            recordRecoverableError(
                error,
                context: "Application replacement relaunch failed"
            )
        }
    }

    func promptForDriverUninstallIfApplicationWasRemoved(bundleURL: URL) {
        guard !didPromptForDriverUninstallAfterApplicationRemoval,
              !FileManager.default.fileExists(atPath: bundleURL.path) else {
            return
        }

        didPromptForDriverUninstallAfterApplicationRemoval = true
        stopApplicationRemovalMonitor()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Nearfield Drivers?"
        alert.informativeText = "Nearfield.app was removed from Applications. Do you also want to remove the Nearfield audio driver and virtual target devices from this Mac?"
        alert.addButton(withTitle: "Uninstall Drivers")
        alert.addButton(withTitle: "Keep Drivers")

        if alert.runModal() == .alertFirstButtonReturn {
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.removeDriversAndTargets()
                NSApp.terminate(nil)
            }
            return
        }
        NSApp.terminate(nil)
    }

    func currentApplicationBundleURL() -> URL {
        Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    func promptForUninstallScope() -> UninstallScope? {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Nearfield?"
        alert.informativeText = "Choose whether to remove only the Nearfield virtual audio drivers, or remove the drivers and Nearfield.app from Applications."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Drivers Only")
        alert.addButton(withTitle: "Drivers & App")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return nil
        case .alertSecondButtonReturn:
            return .driversOnly
        case .alertThirdButtonReturn:
            return .driversAndApp
        default:
            return nil
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        // First-run onboarding is already shown synchronously during launch.
        // Avoid restarting its simulation when AppKit handles the subsequent
        // open-application event.
        guard !isInitialOnboardingInProgress else {
            return true
        }
        guard onboardingWindowController?.window?.isVisible != true else {
            return true
        }

        switch NearfieldLaunchPolicy.openApplicationPresentation(
            hasCompletedOnboarding: true,
            isLoginItemLaunch: currentAppleEventIsLoginItemLaunch()
        ) {
        case .onboarding:
            openOnboarding()
            return true
        case .settings:
            openSettings()
            return true
        case .none:
            return false
        }
    }

    func currentAppleEventIsLoginItemLaunch() -> Bool {
        NSAppleEventManager.shared()
            .currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
    }

}
