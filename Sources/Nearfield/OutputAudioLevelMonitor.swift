import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

@MainActor
final class OutputAudioLevelMonitor: ObservableObject {
    @Published private(set) var level: Double = 0
    @Published private(set) var statusText = "Off"
    @Published private(set) var requiresScreenRecordingPermission = false

    private let sampleQueue = DispatchQueue(label: "com.kemuri.Nearfield.wave-lab-output-audio")
    private let output = OutputAudioStreamOutput()
    private var stream: SCStream?
    private var startTask: Task<Void, Never>?
    private var desiredActive = false

    init() {
        output.onLevel = { [weak self] level in
            Task { @MainActor in
                self?.ingest(level)
            }
        }
    }

    func setActive(_ active: Bool) {
        guard desiredActive != active else { return }
        desiredActive = active
        startTask?.cancel()

        if active {
            requiresScreenRecordingPermission = false
            statusText = "Requesting access"
            startTask = Task { [weak self] in
                await self?.start()
            }
        } else {
            requiresScreenRecordingPermission = false
            statusText = "Off"
            level = 0
            startTask = Task { [weak self] in
                await self?.stop()
            }
        }
    }

    private func start() async {
        await stop()

        guard await waitForScreenCaptureAccess() else {
            guard !Task.isCancelled else { return }
            requiresScreenRecordingPermission = true
            statusText = "Allow Nearfield in Screen Recording"
            desiredActive = false
            level = 0
            return
        }

        guard desiredActive, !Task.isCancelled else { return }

        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw OutputAudioLevelMonitorError.noDisplay
            }

            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.queueDepth = 1
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()

            self.stream = stream
            requiresScreenRecordingPermission = false
            statusText = "Listening to current output"
        } catch {
            guard !Task.isCancelled else { return }
            statusText = "Could not start audio sampling"
            desiredActive = false
            level = 0
        }
    }

    private func waitForScreenCaptureAccess() async -> Bool {
        if WindowCaptureAccess.isGranted() {
            requiresScreenRecordingPermission = false
            return true
        }

        _ = WindowCaptureAccess.request()
        requiresScreenRecordingPermission = true
        statusText = "Waiting for Screen Recording permission"

        for _ in 0..<120 {
            guard desiredActive, !Task.isCancelled else { return false }
            if WindowCaptureAccess.isGranted() {
                requiresScreenRecordingPermission = false
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        return WindowCaptureAccess.isGranted()
    }

    private func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    private func ingest(_ incomingLevel: Double) {
        guard desiredActive else { return }
        let smoothing = incomingLevel > level ? 0.28 : 0.12
        level = level * (1 - smoothing) + incomingLevel * smoothing
    }
}

private enum OutputAudioLevelMonitorError: Error {
    case noDisplay
}

private final class OutputAudioStreamOutput: NSObject, SCStreamOutput {
    var onLevel: (@Sendable (Double) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              CMSampleBufferDataIsReady(sampleBuffer),
              let level = Self.normalizedRMSLevel(from: sampleBuffer) else {
            return
        }

        onLevel?(level)
    }

    private static func normalizedRMSLevel(from sampleBuffer: CMSampleBuffer) -> Double? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel > 0 else {
            return nil
        }

        var requiredSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, requiredSize > 0 else {
            return nil
        }

        let rawBufferList = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBufferList.deallocate() }

        let audioBufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            return nil
        }

        let sample = AudioLevelSample.sample(from: UnsafeMutableAudioBufferListPointer(audioBufferList), asbd: asbd)
        guard sample.count > 0 else {
            return nil
        }

        let rms = sqrt(sample.sumSquares / Double(sample.count))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 60) / 45, 0), 1)
    }
}

private struct AudioLevelSample {
    var sumSquares: Double
    var count: Int

    static func sample(from buffers: UnsafeMutableAudioBufferListPointer, asbd: AudioStreamBasicDescription) -> AudioLevelSample {
        var result = AudioLevelSample(sumSquares: 0, count: 0)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        let bytesPerSample = Int(max(asbd.mBitsPerChannel / 8, 1))

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            guard byteCount >= bytesPerSample else { continue }
            let sampleCount = byteCount / bytesPerSample
            let stride = max(sampleCount / 2_048, 1)

            if isFloat && bytesPerSample == MemoryLayout<Float32>.size {
                let values = data.bindMemory(to: Float32.self, capacity: sampleCount)
                for index in Swift.stride(from: 0, to: sampleCount, by: stride) {
                    result.add(Double(values[index]))
                }
            } else if isFloat && bytesPerSample == MemoryLayout<Float64>.size {
                let values = data.bindMemory(to: Float64.self, capacity: sampleCount)
                for index in Swift.stride(from: 0, to: sampleCount, by: stride) {
                    result.add(values[index])
                }
            } else if isSignedInteger && bytesPerSample == MemoryLayout<Int16>.size {
                let values = data.bindMemory(to: Int16.self, capacity: sampleCount)
                for index in Swift.stride(from: 0, to: sampleCount, by: stride) {
                    result.add(Double(values[index]) / Double(Int16.max))
                }
            } else if isSignedInteger && bytesPerSample == MemoryLayout<Int32>.size {
                let values = data.bindMemory(to: Int32.self, capacity: sampleCount)
                for index in Swift.stride(from: 0, to: sampleCount, by: stride) {
                    result.add(Double(values[index]) / Double(Int32.max))
                }
            }
        }

        return result
    }

    mutating func add(_ value: Double) {
        let clamped = min(max(value, -1), 1)
        sumSquares += clamped * clamped
        count += 1
    }
}
