import CoreAudio
import Darwin
import Foundation

enum CoreAudioStartupError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Core Audio did not become ready in time. Quit and reopen Nearfield after Core Audio has restarted."
    }
}

enum CoreAudioReadinessProbe {
    static let commandLineArgument = "--core-audio-readiness-probe"

    static func run() -> Int32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard hasUsableDeviceInventory(sizeStatus: status, dataSize: dataSize) else {
            return EXIT_FAILURE
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = Array(repeating: AudioObjectID(0), count: deviceCount)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        return hasUsableDeviceInventory(
            sizeStatus: status,
            dataSize: dataSize,
            dataStatus: dataStatus,
            deviceIDs: deviceIDs
        ) ? EXIT_SUCCESS : EXIT_FAILURE
    }

    static func hasUsableDeviceInventory(
        sizeStatus: OSStatus,
        dataSize: UInt32,
        dataStatus: OSStatus = noErr,
        deviceIDs: [AudioObjectID]? = nil
    ) -> Bool {
        let objectSize = UInt32(MemoryLayout<AudioObjectID>.size)
        guard sizeStatus == noErr,
              dataStatus == noErr,
              dataSize >= objectSize,
              dataSize.isMultiple(of: objectSize) else {
            return false
        }
        guard let deviceIDs else {
            return true
        }
        return !deviceIDs.isEmpty && deviceIDs.contains(where: { $0 != kAudioObjectUnknown })
    }

    static func waitUntilReady(timeout: TimeInterval = 5) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runChildProcess(timeout: timeout))
            }
        }
    }

    private static func runChildProcess(timeout: TimeInterval) -> Bool {
        guard let executableURL = Bundle.main.executableURL else {
            return false
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [commandLineArgument]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard process.isRunning else {
            return process.terminationStatus == EXIT_SUCCESS
        }

        process.terminate()
        let terminationDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        return false
    }
}
