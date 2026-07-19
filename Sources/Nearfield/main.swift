import AppKit
import Darwin
#if NEARFIELD_DISTRIBUTION
import Sparkle
#endif

if CommandLine.arguments.contains(CoreAudioReadinessProbe.commandLineArgument) {
    Darwin.exit(CoreAudioReadinessProbe.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
#if NEARFIELD_DISTRIBUTION
let updaterController = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: nil,
    userDriverDelegate: nil
)
withExtendedLifetime(updaterController) {
    app.run()
}
#else
app.run()
#endif
