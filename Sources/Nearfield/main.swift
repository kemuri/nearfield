import AppKit
import Darwin

if CommandLine.arguments.contains(CoreAudioReadinessProbe.commandLineArgument) {
    Darwin.exit(CoreAudioReadinessProbe.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
