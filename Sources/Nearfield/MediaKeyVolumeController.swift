import AppKit
import IOKit

final class MediaKeyVolumeController {
    private let audioManager: StudioDisplayAudioManager
    private var monitors: [Any] = []

    init(audioManager: StudioDisplayAudioManager) {
        self.audioManager = audioManager
    }

    func start() {
        guard monitors.isEmpty else { return }

        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            self?.handle(event)
        }

        if let localMonitor {
            monitors.append(localMonitor)
        }
        if let globalMonitor {
            monitors.append(globalMonitor)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    @discardableResult
    private func handle(_ event: NSEvent) -> Bool {
        guard event.subtype.rawValue == 8, isKeyDown(event) else {
            return false
        }

        let keyType = Int((event.data1 & 0xFFFF0000) >> 16)
        do {
            switch keyType {
            case Int(NX_KEYTYPE_SOUND_UP):
                try audioManager.adjustNearfieldVolume(by: 1.0 / 16.0)
                return true
            case Int(NX_KEYTYPE_SOUND_DOWN):
                try audioManager.adjustNearfieldVolume(by: -1.0 / 16.0)
                return true
            case Int(NX_KEYTYPE_MUTE):
                try audioManager.toggleNearfieldMute()
                return true
            default:
                return false
            }
        } catch {
            // Hardware-key handling should stay silent; the menu exposes explicit errors.
            return false
        }
    }

    private func isKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.data1 & 0x0000FFFF
        let keyState = (flags & 0xFF00) >> 8
        return keyState == 0x0A
    }
}
