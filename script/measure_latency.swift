#!/usr/bin/env swift
// Measures Nearfield's end-to-end output latency: plays quiet clicks through
// the default output (Nearfield), records them with a Studio Display
// microphone, and compares the delay with the latency Core Audio reports for
// the output device.
//
//   swift script/measure_latency.swift
//   swift script/measure_latency.swift --clicks 20 --input "Studio Display"
//   swift script/measure_latency.swift --output "Studio Display Speakers" --click-level -44
//       (control: one display directly, at the level Nearfield's volume gives)
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
// Plays on the named device instead of the default output (a control
// measurement, for example one Studio Display directly).
let outputNameHint = value(after: "--output")
let clickDecibels = min(0, value(after: "--click-level").flatMap(Double.init) ?? -6)

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
let namedOutput = outputNameHint.flatMap { hint in
    objects(system, kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal).first { device in
        !objects(device, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput).isEmpty &&
            string(device, kAudioObjectPropertyName).localizedCaseInsensitiveContains(hint)
    }
}
if let outputNameHint, namedOutput == nil {
    fail("no output device named like \"\(outputNameHint)\"")
}
guard let outputDevice: AudioObjectID = namedOutput ?? read(system, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, 0),
      outputDevice != kAudioObjectUnknown else {
    fail("no default output device")
}
let outputUID = string(outputDevice, kAudioDevicePropertyDeviceUID)
guard outputUID == nearfieldDeviceUID || allowAnyOutput || namedOutput != nil else {
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
// A plain IO callback on the microphone: it always runs in the device's own
// format and sample rate (which follows the displays when Nearfield's rate
// changes), and its input time is when the first frame was captured.
var inputProc: AudioDeviceIOProcID?
guard AudioDeviceCreateIOProcIDWithBlock(&inputProc, inputDevice, nil, { _, inputData, inputTime, _, _ in
    guard inputTime.pointee.mFlags.contains(.hostTimeValid) else { return }
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    var samples: [Float] = []
    for buffer in buffers {
        guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
        let channels = Int(buffer.mNumberChannels)
        let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        if samples.isEmpty { samples = [Float](repeating: 0, count: frames) }
        let values = data.assumingMemoryBound(to: Float.self)
        // The loudest microphone of the array.
        for frame in 0..<min(frames, samples.count) {
            for channel in 0..<channels where abs(values[frame * channels + channel]) > abs(samples[frame]) {
                samples[frame] = values[frame * channels + channel]
            }
        }
    }
    if !samples.isEmpty {
        recording.append(hostTime: inputTime.pointee.mHostTime, samples: samples)
    }
}) == noErr, let inputProc else {
    fail("could not record the microphone")
}

// MARK: Clicks

/// A 2 ms, 3 kHz burst with a Hann window: a soft tick that the matched
/// filter below finds well below the room's noise.
func clickBurst(sampleRate: Double) -> [Double] {
    let length = max(8, Int(sampleRate * 0.002))
    return (0..<length).map { index in
        let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(length - 1))
        return window * sin(2 * Double.pi * 3000 * Double(index) / sampleRate)
    }
}

final class ClickPlayer: @unchecked Sendable {
    let clickTimes: UnsafeMutablePointer<UInt64>
    let count: Int
    private(set) var emitted = 0
    private var frame: Int64 = 0
    private let interval: Int64
    private let burst: [Float]

    init(count: Int, sampleRate: Double, decibels: Double) {
        self.count = count
        clickTimes = .allocate(capacity: count)
        interval = Int64(sampleRate * 0.6)
        let peak = pow(10.0, decibels / 20.0)
        burst = clickBurst(sampleRate: sampleRate).map { Float(peak * $0) }
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
let player = ClickPlayer(count: clickCount, sampleRate: outputRate, decibels: clickDecibels)
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
if namedOutput != nil {
    func selectOutput(_ unit: AudioUnit?) -> Bool {
        guard let unit else { return false }
        var deviceID = outputDevice
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                    &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr
    }
    let selected: Bool
    if #available(macOS 27, *) {
        selected = outputEngine.outputNode.withAudioUnit { unit in selectOutput(unit) }
    } else {
        selected = selectOutput(outputEngine.outputNode.audioUnit)
    }
    guard selected else { fail("could not play on \(string(outputDevice, kAudioObjectPropertyName))") }
}
outputEngine.attach(source)
do {
    if #available(macOS 27, *) {
        try outputEngine.connectNode(source, to: outputEngine.mainMixerNode, format: outputFormat)
    } else {
        outputEngine.connect(source, to: outputEngine.mainMixerNode, format: outputFormat)
    }
    guard AudioDeviceStart(inputDevice, inputProc) == noErr else { fail("could not start the microphone") }
    try outputEngine.start()
} catch {
    fail("could not start audio: \(error)")
}

print("output: \(string(outputDevice, kAudioObjectPropertyName)) at \(Int(outputRate)) Hz, reports \(String(format: "%.1f", reportedOutputSeconds * 1000)) ms")
print("input:  \(string(inputDevice, kAudioObjectPropertyName)) at \(Int(inputRate)) Hz, reports \(String(format: "%.1f", inputLatencySeconds * 1000)) ms")
print("playing \(clickCount) clicks…")
Thread.sleep(forTimeInterval: 0.6 * Double(clickCount + 2))
outputEngine.stop()
AudioDeviceStop(inputDevice, inputProc)
AudioDeviceDestroyIOProcID(inputDevice, inputProc)
guard !missingHostTime else { fail("the output did not provide host times") }

// MARK: Analysis

let ticksPerInputFrame = ticksPerSecond / inputRate
let chunks = recording.snapshot()
guard let firstChunk = chunks.first else { fail("nothing was recorded") }
// One continuous recording, timed from its first sample.
let recorded = chunks.flatMap(\.samples)
let recordingStart = Double(firstChunk.hostTime)
let template = clickBurst(sampleRate: inputRate)
let templateEnergy = sqrt(template.reduce(0) { $0 + $1 * $1 })
let peakLevel = recorded.map { abs($0) }.max() ?? 0
print(String(format: "recorded %.1f s, peak %.1f dBFS", Double(recorded.count) / inputRate, 20 * log10(max(Double(peakLevel), 1e-9))))

/// Matched filter: where the recording best matches the click, and how far
/// that match stands out from the rest of the window.
func findClick(from start: Int, count: Int) -> (index: Int, snr: Double)? {
    let end = min(recorded.count - template.count, start + count)
    guard start >= 0, end > start else { return nil }
    var scores = [Double](repeating: 0, count: end - start)
    for offset in start..<end {
        var sum = 0.0
        for (index, value) in template.enumerated() {
            sum += value * Double(recorded[offset + index])
        }
        scores[offset - start] = abs(sum) / templateEnergy
    }
    guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
    let typical = scores.sorted()[scores.count / 2]
    return (start + best, typical > 0 ? scores[best] / typical : .infinity)
}

var delays: [Double] = []
for index in 0..<player.emitted {
    let clickTime = Double(player.clickTimes[index])
    let firstFrame = Int(((clickTime - recordingStart) / ticksPerInputFrame).rounded(.down))
    guard let found = findClick(from: firstFrame, count: Int(inputRate * 0.5)) else { continue }
    guard found.snr >= 8 else {
        print(String(format: "click %d: not found (best match %.1fx the noise)", index + 1, found.snr))
        continue
    }
    let arrival = (recordingStart + Double(found.index) * ticksPerInputFrame) / ticksPerSecond - inputLatencySeconds
    let delay = arrival - clickTime / ticksPerSecond
    print(String(format: "click %d: %.1f ms (%.0fx the noise)", index + 1, delay * 1000, found.snr))
    delays.append(delay)
}

guard !delays.isEmpty else {
    fail("no clicks were detected; raise the volume or move the microphone closer")
}
let sorted = delays.sorted()
let median = sorted[sorted.count / 2]
print(String(format: "measured: median %.1f ms (min %.1f, max %.1f) from %d of %d clicks",
             median * 1000, sorted.first! * 1000, sorted.last! * 1000, delays.count, player.emitted))
// Nearfield's latency changes when it trims delay during silence, so compare
// with what it reports while the clicks play, not only before.
let reportedAfterSeconds = Double(latencyFrames(outputDevice, kAudioObjectPropertyScopeOutput)) / outputRate
let reportedDuringSeconds = (reportedOutputSeconds + reportedAfterSeconds) / 2
print(String(format: "reported: %.1f ms before, %.1f ms after; difference %+.1f ms (includes speaker-to-microphone distance)",
             reportedOutputSeconds * 1000, reportedAfterSeconds * 1000, (median - reportedDuringSeconds) * 1000))
