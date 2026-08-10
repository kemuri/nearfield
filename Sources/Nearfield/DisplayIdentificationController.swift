import AppKit
import CoreGraphics
import IOKit
import SwiftUI

enum DisplayIdentificationSide: Equatable {
    case left
    case center
    case right
}

@MainActor
final class DisplayIdentificationController {
    private var panel: NSPanel?
    private var fadeTask: Task<Void, Never>?

    func show(displayUID: String, fallbackSide: DisplayIdentificationSide) {
        hide(animated: false)
        guard let screen = StudioDisplayScreenMatcher.screen(forAudioDeviceUID: displayUID)
            ?? screen(for: fallbackSide) else {
            return
        }

        let panel = makePanel(on: screen)
        self.panel = panel
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        fadeTask = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: 1_050_000_000)
            guard !Task.isCancelled, let self, let panel else { return }
            self.fadeOut(panel)
        }
    }

    private func screen(for side: DisplayIdentificationSide) -> NSScreen? {
        let supportedScreens = NSScreen.screens.filter { screen in
            if screen.localizedName.localizedCaseInsensitiveContains("Studio Display") {
                return true
            }
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(displayID) != 0
        }
        let candidateScreens = supportedScreens.count >= 2
            ? supportedScreens
            : NSScreen.screens
        let sortedScreens = candidateScreens.sorted {
            if $0.frame.midX == $1.frame.midX {
                return $0.frame.midY < $1.frame.midY
            }
            return $0.frame.midX < $1.frame.midX
        }

        guard sortedScreens.count >= 2 else { return nil }
        switch side {
        case .left:
            return sortedScreens[0]
        case .center:
            return sortedScreens.count >= 3 ? sortedScreens[1] : nil
        case .right:
            return sortedScreens[sortedScreens.count >= 3 ? 2 : 1]
        }
    }

    private func fadeOut(_ panel: NSPanel) {
        fadeTask = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.65
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                panel?.orderOut(nil)
                if self?.panel === panel {
                    self?.panel = nil
                }
            }
        }
    }

    private func hide(animated: Bool) {
        fadeTask?.cancel()
        fadeTask = nil
        guard let panel else { return }
        self.panel = nil

        if animated {
            fadeOut(panel)
        } else {
            panel.orderOut(nil)
        }
    }

    private func makePanel(on screen: NSScreen) -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: screen.frame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        // Position with the screen's global frame after constructing the
        // panel. Passing a non-main screen frame as a content rect can offset
        // the panel twice on multi-display arrangements.
        panel.setFrame(screen.frame, display: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.contentView = NSHostingView(rootView: DisplayIdentificationHalo())
        return panel
    }
}

enum StudioDisplayScreenMatcher {
    static func screen(forAudioDeviceUID audioDeviceUID: String) -> NSScreen? {
        if isBuiltInAudioDeviceUID(audioDeviceUID) {
            return NSScreen.screens.first { screen in
                guard let displayID = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? CGDirectDisplayID else {
                    return false
                }
                return CGDisplayIsBuiltin(displayID) != 0
            }
        }
        guard let usbSerial = usbSerial(fromAudioDeviceUID: audioDeviceUID),
              let containerIdentifier = usbContainerIdentifier(forSerial: usbSerial),
              let displaySerial = displaySerial(containing: containerIdentifier) else {
            return nil
        }

        return NSScreen.screens.first { screen in
            guard let displayID = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplaySerialNumber(displayID) == displaySerial
        }
    }

    static func isBuiltInAudioDeviceUID(_ audioDeviceUID: String) -> Bool {
        audioDeviceUID.localizedCaseInsensitiveContains("BuiltInSpeaker") ||
            audioDeviceUID.localizedCaseInsensitiveContains("Built-in")
    }

    static func usbSerial(fromAudioDeviceUID audioDeviceUID: String) -> String? {
        audioDeviceUID
            .split(separator: ":")
            .map(String.init)
            .first { $0.hasPrefix("00008030-") }
    }

    static func edid(
        _ edid: Data,
        containsContainerIdentifier containerIdentifier: UUID
    ) -> Bool {
        var identifierBytes = containerIdentifier.uuid
        return withUnsafeBytes(of: &identifierBytes) { bytes in
            edid.range(of: Data(bytes)) != nil
        }
    }

    private static func usbContainerIdentifier(forSerial serial: String) -> UUID? {
        services(matching: "IOUSBHostDevice") { service in
            guard property("USB Product Name", of: service) as? String == "Studio Display",
                  property("USB Serial Number", of: service) as? String == serial,
                  let identifier = property("kUSBContainerID", of: service) as? String else {
                return nil
            }
            return UUID(uuidString: identifier)
        }
    }

    private static func displaySerial(containing containerIdentifier: UUID) -> UInt32? {
        services(matching: "IOPortTransportStateDisplayPort") { service in
            guard let metadata = property("Metadata", of: service) as? [String: Any],
                  metadata["ProductName"] as? String == "StudioDisplay",
                  let serialNumber = metadata["SerialNumber"] as? NSNumber,
                  let edidData = metadata["EDID"] as? Data,
                  edid(edidData, containsContainerIdentifier: containerIdentifier) else {
                return nil
            }
            return serialNumber.uint32Value
        }
    }

    private static func services<Result>(
        matching className: String,
        find: (io_service_t) -> Result?
    ) -> Result? {
        guard let matchingDictionary = IOServiceMatching(className) else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matchingDictionary,
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            let result = find(service)
            IOObjectRelease(service)
            if let result {
                return result
            }
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    private static func property(_ key: String, of service: io_registry_entry_t) -> Any? {
        IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
    }
}

private struct DisplayIdentificationHalo: View {
    private let accentColor = Color(nsColor: .controlAccentColor)

    var body: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(Color.white.opacity(0.94), lineWidth: 4)
            .shadow(color: .white.opacity(0.86), radius: 12)
            .shadow(color: accentColor.opacity(0.72), radius: 26)
            .padding(12)
            .allowsHitTesting(false)
    }
}
