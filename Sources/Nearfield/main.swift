import AppKit
import Darwin

if CommandLine.arguments.contains(NearfieldResources.validationCommandLineArgument) {
    guard let resourceURL = NearfieldResources.menuBarIconURL() else {
        let message = "Nearfield packaged resource validation failed: menubar.svg was not found.\n"
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        Darwin.exit(78)
    }
    try? FileHandle.standardOutput.write(contentsOf: Data("\(resourceURL.path)\n".utf8))
    Darwin.exit(0)
}

LaunchDiagnostics.start()

if CommandLine.arguments.contains(CoreAudioReadinessProbe.commandLineArgument) {
    LaunchDiagnostics.record("Core Audio readiness probe starting")
    let exitCode = CoreAudioReadinessProbe.run()
    LaunchDiagnostics.record("Core Audio readiness probe exiting code=\(exitCode)")
    Darwin.exit(exitCode)
}

LaunchDiagnostics.record("creating NSApplication.shared")
let app = NSApplication.shared
LaunchDiagnostics.record("created NSApplication.shared")
LaunchDiagnostics.record("creating AppDelegate")
let delegate = AppDelegate()
LaunchDiagnostics.record("created AppDelegate")
app.delegate = delegate
LaunchDiagnostics.record("assigned AppDelegate")
app.setActivationPolicy(.accessory)
LaunchDiagnostics.record("set accessory activation policy")
LaunchDiagnostics.record("entering AppKit run loop")
app.run()
LaunchDiagnostics.record("AppKit run loop exited")
