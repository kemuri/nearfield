#!/usr/bin/env swift
// Measures Nearfield's end-to-end output latency: plays quiet clicks through
// the default output (Nearfield), records them with a Studio Display
// microphone, and compares the delay with the latency Core Audio reports for
// the output device.
//
//   swift script/measure_latency.swift
//   swift script/measure_latency.swift --clicks 20 --input "Studio Display"
//
// Keep the room quiet and the volume moderate. The measured value includes
// the sound's travel time from speaker to microphone (about 1 ms at 34 cm).
// The terminal needs microphone access (System Settings > Privacy & Security).

import AVFoundation
import CoreAudio
import Foundation

let nearfieldDeviceUID = "NearfieldAudioDevice_UID"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("measure_latency: \(message)\n".utf8))
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let clickCount = value(after: "--clicks").flatMap(Int.init) ?? 12
let inputNameHint = value(after: "--input") ?? "Studio Display"
let allowAnyOutput = arguments.contains("--allow-any-output")

// MARK: Core Audio helpers

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ initial: T) -> T? {
    var address = address(selector, scope)
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String {
    var address = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return "" }
    return value.takeRetainedValue() as String
}

func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> [AudioObjectID] {
    var address = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

/// Frames between the IO time stamp and the sound at the speaker (output) or
/// from the microphone to the IO time stamp (input).
func latencyFrames(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> UInt32 {
    let deviceLatency: UInt32 = read(device, kAudioDevicePropertyLatency, scope, 0) ?? 0
    let streamLatency: UInt32 = objects(device, kAudioDevicePropertyStreams, scope).first.flatMap {
        read($0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, UInt32(0))
    } ?? 0
    return deviceLatency + streamLatency
}

let system = AudioObjectID(kAudioObjectSystemObject)
guard let outputDevice: AudioObjectID = read(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0),
      outputDevice != kAudioObjectUnknown else {
    fail("no default output device")
}
let outputUID = string(outputDevice, kAudioDevicePropertyDeviceUID)
guard outputUID == nearfieldDeviceUID || allowAnyOutput else {
    fail("the default output is \(string(outputDevice, kAudioObjectPropertyName)), not Nearfield (pass --allow-any-output to measure it anyway)")
}
let inputDevice = objects(system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal).first { device in
    !objects(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput).isEmpty &&
        string(device, kAudioObjectPropertyName).localizedCaseInsensitiveContains(inputNameHint)
}
guard let inputDevice else {
    fail("no input device named like \"\(inputNameHint)\"")
}

let outputRate: Double = read(outputDevice, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)) ?? 0
let inputRate: Double = read(inputDevice, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)) ?? 0
guard outputRate > 0, inputRate > 0 else { fail("could not read the sample rates") }
let reportedOutputSeconds = Double(latencyFrames(outputDevice, kAudioObjectPropertyScopeOutput)) / outputRate
let inputLatencySeconds = Double(latencyFrames(inputDevice, kAudioObjectPropertyScopeInput)) / inputRate

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let ticksPerSecond = 1e9 * Double(timebase.denom) / Double(timebase.numer)

// MARK: Microphone permission

let permission = DispatchSemaphore(value: 0)
var microphoneAllowed = false
AVCaptureDevice.requestAccess(for: .audio) { granted in
    microphoneAllowed = granted
    permission.signal()
}
permission.wait()
guard microphoneAllowed else { fail("microphone access was denied for this terminal") }

// MARK: Recording

final class Recording: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var chunks: [(hostTime: UInt64, samples: [Float])] = []

    func append(hostTime: UInt64, samples: [Float]) {
        lock.lock()
        chunks.append((hostTime, samples))
        lock.unlock()
    }

    func snapshot() -> [(hostTime: UInt64, samples: [Float])] {
        lock.lock()
        defer { lock.unlock() }
        return chunks
    }
}

let recording = Recording()
let inputEngine = AVAudioEngine()
func selectMicrophone(_ unit: AudioUnit?) -> Bool {
    guard let unit else { return false }
    var deviceID = inputDevice
    return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr
}
let selectedMicrophone: Bool
if #available(macOS 27, *) {
    selectedMicrophone = inputEngine.inputNode.withAudioUnit { unit in selectMicrophone(unit) }
} else {
    selectedMicrophone = selectMicrophone(inputEngine.inputNode.audioUnit)
}
guard selectedMicrophone else { fail("could not select the microphone") }

@Sendable func record(_ buffer: AVAudioPCMBuffer, _ time: AVAudioTime) {
    guard time.isHostTimeValid, let channels = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    var samples = [Float](repeating: 0, count: frames)
    // The loudest microphone of the array.
    for channel in 0..<Int(buffer.format.channelCount) {
        for frame in 0..<frames where abs(channels[channel][frame]) > abs(samples[frame]) {
            samples[frame] = channels[channel][frame]
        }
    }
    recording.append(hostTime: time.hostTime, samples: samples)
}
let inputFormat = inputEngine.inputNode.outputFormat(forBus: 0)
if #available(macOS 27, *) {
    do {
        try inputEngine.inputNode.installAudioTap(onBus: 0, bufferSize: 512, format: inputFormat) { buffer, time in
            record(AVAudioPCMBuffer(copying: buffer), time)
        }
    } catch {
        fail("could not record the microphone: \(error)")
    }
} else {
    inputEngine.inputNode.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { buffer, time in
        record(buffer, time)
    }
}

// MARK: Clicks

final class ClickPlayer: @unchecked Sendable {
    let clickTimes: UnsafeMutablePointer<UInt64>
    let count: Int
    private(set) var emitted = 0
    private var frame: Int64 = 0
    private let interval: Int64
    private let burst: [Float]

    init(count: Int, sampleRate: Double) {
        self.count = count
        clickTimes = .allocate(capacity: count)
        interval = Int64(sampleRate * 0.6)
        // 1 ms of 4 kHz at -20 dBFS: short and quiet, with a sharp onset.
        let length = Int(sampleRate / 1000)
        burst = (0..<length).map { index in
            0.1 * Float(sin(2 * Double.pi * 4000 * Double(index) / sampleRate))
        }
    }

    func render(frames: Int, hostTime: UInt64, ticksPerFrame: Double, into buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
        for offset in 0..<frames {
            let position = frame + Int64(offset) - interval // First click after one interval.
            guard position >= 0 else { continue }
            let clickIndex = Int(position / interval)
            let within = Int(position % interval)
            guard clickIndex < count, within < burst.count else { continue }
            if within == 0 {
                clickTimes[clickIndex] = hostTime + UInt64(Double(offset) * ticksPerFrame)
                emitted = clickIndex + 1
            }
            for buffer in buffers {
                buffer.mData?.assumingMemoryBound(to: Float.self)[offset] = burst[within]
            }
        }
        frame += Int64(frames)
    }
}

let outputEngine = AVAudioEngine()
let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
let player = ClickPlayer(count: clickCount, sampleRate: outputRate)
let ticksPerOutputFrame = ticksPerSecond / outputRate
var missingHostTime = false
let source = AVAudioSourceNode(format: outputFormat) { _, timestamp, frameCount, bufferList in
    guard timestamp.pointee.mFlags.contains(.hostTimeValid) else {
        missingHostTime = true
        return noErr
    }
    player.render(frames: Int(frameCount), hostTime: timestamp.pointee.mHostTime,
                  ticksPerFrame: ticksPerOutputFrame, into: UnsafeMutableAudioBufferListPointer(bufferList))
    return noErr
}
outputEngine.attach(source)
do {
    if #available(macOS 27, *) {
        try outputEngine.connectNode(source, to: outputEngine.mainMixerNode, format: outputFormat)
    } else {
        outputEngine.connect(source, to: outputEngine.mainMixerNode, format: outputFormat)
    }
    try inputEngine.start()
    try outputEngine.start()
} catch {
    fail("could not start audio: \(error)")
}

print("output: \(string(outputDevice, kAudioObjectPropertyName)) at \(Int(outputRate)) Hz, reports \(String(format: "%.1f", reportedOutputSeconds * 1000)) ms")
print("input:  \(string(inputDevice, kAudioObjectPropertyName)) at \(Int(inputRate)) Hz, reports \(String(format: "%.1f", inputLatencySeconds * 1000)) ms")
print("playing \(clickCount) clicks…")
Thread.sleep(forTimeInterval: 0.6 * Double(clickCount + 2))
outputEngine.stop()
inputEngine.stop()
guard !missingHostTime else { fail("the output did not provide host times") }

// MARK: Analysis

let ticksPerInputFrame = ticksPerSecond / inputRate
let samples = recording.snapshot().flatMap { chunk in
    chunk.samples.enumerated().map { (UInt64(Double(chunk.hostTime) + Double($0.offset) * ticksPerInputFrame), $0.element) }
}
var delays: [Double] = []
for index in 0..<player.emitted {
    let clickTime = player.clickTimes[index]
    let before = samples.filter { $0.0 < clickTime && $0.0 + UInt64(0.2 * ticksPerSecond) >= clickTime }
    let noise = before.isEmpty ? 0 : sqrt(before.map { Double($0.1 * $0.1) }.reduce(0, +) / Double(before.count))
    let threshold = max(noise * 10, 0.002)
    let window = UInt64(0.5 * ticksPerSecond)
    guard let onset = samples.first(where: { $0.0 >= clickTime && $0.0 < clickTime + window && Double(abs($0.1)) > threshold }) else {
        continue
    }
    let arrival = Double(onset.0) / ticksPerSecond - inputLatencySeconds
    delays.append(arrival - Double(clickTime) / ticksPerSecond)
}

guard !delays.isEmpty else {
    fail("no clicks were detected; raise the volume or move the microphone closer")
}
let sorted = delays.sorted()
let median = sorted[sorted.count / 2]
print(String(format: "measured: median %.1f ms (min %.1f, max %.1f) from %d of %d clicks",
             median * 1000, sorted.first! * 1000, sorted.last! * 1000, delays.count, player.emitted))
print(String(format: "reported: %.1f ms; difference %+.1f ms (includes speaker-to-microphone distance)",
             reportedOutputSeconds * 1000, (median - reportedOutputSeconds) * 1000))
