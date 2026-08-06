import Darwin
import Foundation

enum LaunchDiagnostics {
    static let relativeLogPath = "Library/Logs/Nearfield/launch-diagnostic.log"

    static func start() {
        #if NEARFIELD_LAUNCH_DIAGNOSTICS
        NSSetUncaughtExceptionHandler(nearfieldUncaughtExceptionHandler)

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let executablePath = Bundle.main.executableURL?.path ?? "unknown"
        let diagnosticArguments = ProcessInfo.processInfo.arguments
            .dropFirst()
            .filter { $0.hasPrefix("--") }
            .joined(separator: ",")

        record("=== process started ===")
        record(
            "pid=\(Darwin.getpid()) ppid=\(Darwin.getppid()) " +
                "architecture=\(architecture) translated=\(isRunningTranslated)"
        )
        record(
            "version=\(version) build=\(build) " +
                "os=\(ProcessInfo.processInfo.operatingSystemVersionString)"
        )
        record("bundle=\(Bundle.main.bundleURL.path)")
        record("executable=\(executablePath) flags=\(diagnosticArguments.nilIfEmpty ?? "none")")
        #endif
    }

    static func record(_ message: @autoclosure () -> String) {
        #if NEARFIELD_LAUNCH_DIAGNOSTICS
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let sanitizedMessage = message()
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        let line = "\(timestamp) \(sanitizedMessage)\n"
        guard let data = line.data(using: .utf8) else { return }

        try? FileHandle.standardError.write(contentsOf: data)

        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativeLogPath)
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let descriptor = logURL.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        data.withUnsafeBytes { buffer in
            guard let address = buffer.baseAddress else { return }
            _ = Darwin.write(descriptor, address, buffer.count)
        }
        #endif
    }

    #if NEARFIELD_LAUNCH_DIAGNOSTICS
    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static var isRunningTranslated: Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = Darwin.sysctlbyname(
            "sysctl.proc_translated",
            &translated,
            &size,
            nil,
            0
        )
        return result == 0 && translated == 1
    }
    #endif
}

#if NEARFIELD_LAUNCH_DIAGNOSTICS
private func nearfieldUncaughtExceptionHandler(_ exception: NSException) {
    LaunchDiagnostics.record(
        "uncaught Objective-C exception name=\(exception.name.rawValue) " +
            "reason=\(exception.reason ?? "unknown") " +
            "stack=\(exception.callStackSymbols.joined(separator: " | "))"
    )
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
#endif
