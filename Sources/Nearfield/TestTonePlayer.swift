import AudioToolbox
import AVFAudio
import Foundation

private enum IdentificationChimePlaybackError: LocalizedError {
    case outputAudioUnitUnavailable
    case selectOutputDeviceFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .outputAudioUnitUnavailable:
            "The selected Studio Display audio output is unavailable."
        case .selectOutputDeviceFailed(let status):
            "Selecting the Studio Display audio output failed with Core Audio status \(status)."
        }
    }
}

enum IdentificationChimeGain {
    static func playerVolume(
        physicalOutputsArePrepared: Bool,
        routerAudibleGain: Float32?
    ) -> Float32 {
        guard physicalOutputsArePrepared else {
            // The physical output's own volume control remains in the signal
            // path, so play at unity and let it follow the system volume.
            return 1
        }
        return min(max(routerAudibleGain ?? 1, 0), 1)
    }
}

@MainActor
final class TestTonePlayer {
    static let identificationSoundURL = URL(
        fileURLWithPath: "/System/Library/Sounds/Glass.aiff",
        isDirectory: false
    )

    private var identificationEngine: AVAudioEngine?
    private var identificationPlayer: AVAudioPlayerNode?
    private var identificationFile: AVAudioFile?
    private var identificationCleanupTask: Task<Void, Never>?

    var isAudioGraphPrepared: Bool {
        identificationEngine != nil
    }

    func playIdentificationChime(on display: AudioDevice, volume: Float32) throws {
        identificationCleanupTask?.cancel()
        identificationCleanupTask = nil
        identificationPlayer?.stop()
        identificationEngine?.stop()
        identificationEngine = nil
        identificationPlayer = nil
        identificationFile = nil

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let outputNode = engine.outputNode
        guard let outputAudioUnit = outputNode.audioUnit else {
            throw IdentificationChimePlaybackError.outputAudioUnitUnavailable
        }

        var deviceID = display.id
        let selectStatus = AudioUnitSetProperty(
            outputAudioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard selectStatus == noErr else {
            throw IdentificationChimePlaybackError.selectOutputDeviceFailed(selectStatus)
        }

        let soundFile = try AVAudioFile(forReading: Self.identificationSoundURL)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: soundFile.processingFormat)
        player.volume = min(max(volume, 0), 1)
        engine.prepare()
        try engine.start()
        player.scheduleFile(soundFile, at: nil)
        player.play()

        identificationEngine = engine
        identificationPlayer = player
        identificationFile = soundFile
        let playbackDuration = Double(soundFile.length) / soundFile.fileFormat.sampleRate
        identificationCleanupTask = Task { @MainActor [weak self, weak engine, weak player] in
            try? await Task.sleep(
                nanoseconds: UInt64((playbackDuration + 0.1) * 1_000_000_000)
            )
            guard !Task.isCancelled,
                  let self,
                  self.identificationEngine === engine else {
                return
            }
            player?.stop()
            engine?.stop()
            self.identificationEngine = nil
            self.identificationPlayer = nil
            self.identificationFile = nil
            self.identificationCleanupTask = nil
        }
    }
}
