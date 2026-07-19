import AVFAudio
import Foundation

enum TestToneChannel {
    case stereo
    case left
    case right
}

final class TestTonePlayer {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    var isAudioGraphPrepared: Bool {
        engine != nil
    }

    func play(channel: TestToneChannel) throws {
        let (engine, player) = audioGraph()
        let sampleRate = 48_000.0
        let duration = 0.55
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else {
            return
        }

        buffer.frameLength = frameCount
        let frequency = 660.0
        let amplitude: Float = 0.28
        for frame in 0..<Int(frameCount) {
            let envelope = min(1, Float(frame) / 2_400) * min(1, Float(Int(frameCount) - frame) / 2_400)
            let sample = amplitude * envelope * Float(sin(2.0 * .pi * frequency * Double(frame) / sampleRate))
            channels[0][frame] = channel == .right ? 0 : sample
            channels[1][frame] = channel == .left ? 0 : sample
        }

        if !engine.isRunning {
            try engine.start()
        }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }

    private func audioGraph() -> (AVAudioEngine, AVAudioPlayerNode) {
        if let engine, let player {
            return (engine, player)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
        self.engine = engine
        self.player = player
        return (engine, player)
    }
}
