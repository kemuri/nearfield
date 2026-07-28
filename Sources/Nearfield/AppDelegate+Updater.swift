import AppKit
#if NEARFIELD_DISTRIBUTION
import Sparkle
import UserNotifications

extension AppDelegate {
    func startUpdaterIfEligible(checkImmediately: Bool) {
        guard updaterController == nil else { return }

        let bundleURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard isInApplicationsDirectory(bundleURL) else { return }

        configureUpdateNotifications()
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        updaterController = controller

        guard checkImmediately, controller.updater.automaticallyChecksForUpdates else { return }
        controller.updater.checkForUpdatesInBackground()
    }

    func configureUpdateNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let installAction = UNNotificationAction(
            identifier: UpdateNotification.installActionIdentifier,
            title: "Install and Relaunch",
            options: [.foreground]
        )
        let laterAction = UNNotificationAction(
            identifier: UpdateNotification.laterActionIdentifier,
            title: "Later",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: UpdateNotification.categoryIdentifier,
                actions: [installAction, laterAction],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    /// What to do when a notification cannot be posted. The install-on-quit
    /// path can offer to install immediately; a scheduled reminder has nothing
    /// staged yet, so it defers to Sparkle's own update window.
    enum UpdateNotificationFallback {
        case offerPendingInstall
        case sparkleUpdateWindow
    }

    func presentUpdateNotification(version: String, fallback: UpdateNotificationFallback) {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            let canNotify: Bool
            switch settings.authorizationStatus {
            case .notDetermined:
                canNotify = (try? await center.requestAuthorization(options: [.alert, .sound])) == true
            case .authorized, .provisional, .ephemeral:
                canNotify = settings.alertSetting == .enabled
            case .denied:
                canNotify = false
            @unknown default:
                canNotify = false
            }

            guard canNotify else {
                applyUpdateNotificationFallback(fallback, version: version)
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Nearfield \(version) is ready"
            content.body = "Install the update now and relaunch Nearfield."
            content.categoryIdentifier = UpdateNotification.categoryIdentifier
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: UpdateNotification.requestIdentifier,
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                applyUpdateNotificationFallback(fallback, version: version)
            }
        }
    }

    func applyUpdateNotificationFallback(_ fallback: UpdateNotificationFallback, version: String) {
        switch fallback {
        case .offerPendingInstall:
            presentUpdateAlert(version: version)
        case .sparkleUpdateWindow:
            NSApp.activate(ignoringOtherApps: true)
            updaterController?.checkForUpdates(nil)
        }
    }

    func presentUpdateAlert(version: String) {
        guard pendingUpdateInstallation != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Nearfield \(version) is ready"
        alert.informativeText = "Install the update now and relaunch Nearfield?"
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            installPendingUpdate()
        }
    }

    func installPendingUpdate() {
        guard let install = pendingUpdateInstallation else {
            updaterController?.checkForUpdates(nil)
            return
        }
        dismissUpdateNotification()
        install()
    }

    func handleUpdateNotificationAction(_ actionIdentifier: String) {
        switch actionIdentifier {
        case UpdateNotification.installActionIdentifier:
            installPendingUpdate()
        case UNNotificationDefaultActionIdentifier:
            dismissUpdateNotification()
            NSApp.activate(ignoringOtherApps: true)
            updaterController?.checkForUpdates(nil)
        default:
            break
        }
    }

    func dismissUpdateNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [UpdateNotification.requestIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [UpdateNotification.requestIdentifier])
    }

    func clearPendingUpdate() {
        pendingUpdateInstallation = nil
        dismissUpdateNotification()
        rebuildMenu()
    }

}

extension AppDelegate: SPUUpdaterDelegate {
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        pendingUpdateInstallation = immediateInstallHandler
        rebuildMenu()
        presentUpdateNotification(version: item.displayVersionString, fallback: .offerPendingInstall)
        return true
    }
}

extension AppDelegate: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Let Sparkle present the update itself only when it already proposes
        // immediate focus. Otherwise we take over and post a gentle reminder
        // rather than pulling a menu bar app in front of the user's work.
        // Must stay side-effect free per SPUStandardUserDriverDelegate.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else {
            // We declined above, so this scheduled reminder is ours to show.
            presentUpdateNotification(
                version: update.displayVersionString,
                fallback: .sparkleUpdateWindow
            )
            return
        }
        dismissUpdateNotification()
        // Only take focus for a check the user actually asked for. Sparkle
        // guarantees handleShowingUpdate is true whenever userInitiated is.
        guard state.userInitiated else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        dismissUpdateNotification()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearPendingUpdate()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.categoryIdentifier == UpdateNotification.categoryIdentifier else {
            return
        }
        let actionIdentifier = response.actionIdentifier
        await handleUpdateNotificationAction(actionIdentifier)
    }
}
#endif
