import AppKit
import XCTest
@testable import Nearfield

final class StatusItemMenuTests: XCTestCase {
    @MainActor
    func testStatusItemUsesNativeMenuAcrossOnboardingAndSettings() {
        let app = NSApplication.shared
        let previousMainMenu = app.mainMenu
        let delegate = AppDelegate()
        defer {
            NSStatusBar.system.removeStatusItem(delegate.statusItem)
            app.mainMenu = previousMainMenu
        }

        delegate.isInitialOnboardingInProgress = true
        delegate.configureMenu()
        XCTAssertTrue(delegate.statusItem.menu === delegate.menu)
        XCTAssertEqual(delegate.menu.items.first?.title, "Continue Setup…")
        XCTAssertEqual(delegate.menu.items.first?.action, #selector(AppDelegate.openSettings))
        XCTAssertFalse(delegate.menu.items.contains { $0.title == "Check for Updates..." })

        delegate.isInitialOnboardingInProgress = false
        delegate.applyMenuBarState()
        delegate.menuNeedsUpdate(delegate.menu)
        XCTAssertTrue(delegate.statusItem.menu === delegate.menu)
        XCTAssertEqual(delegate.menu.items.first?.title, "Settings")
        XCTAssertEqual(delegate.menu.items.first?.action, #selector(AppDelegate.openSettings))
        XCTAssertEqual(delegate.menu.items.last?.title, "Quit")
    }
}
