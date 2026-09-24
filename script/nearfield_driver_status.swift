#!/usr/bin/env swift
// Reads Nearfield driver 1.1.0's status, watches it, runs underrun soaks, and
// checks whether the driver accepts settings from processes other than
// Nearfield.
//
//   swift script/nearfield_driver_status.swift                 # status as JSON
//   swift script/nearfield_driver_status.swift --watch         # one line per change
//   swift script/nearfield_driver_status.swift --soak 120      # 2-hour soak, counts underruns
//   swift script/nearfield_driver_status.swift --soak 120 --sample-rate 96000 --tone
//   swift script/nearfield_driver_status.swift --probe-write   # access-control check
//
// --soak prints a line every --interval seconds (default 60) and a summary; it
// exits with status 1 when any underrun happened. Play something through
// Nearfield during the soak, or pass --tone for a quiet 440 Hz tone.
// --sample-rate sets Nearfield's sample rate for the soak and restores the
// previous rate afterwards.

import AVFoundation
import CoreAudio
import Foundation

let boxUID = "NearfieldAudioBox_UID"
let deviceUID = "NearfieldAudioDevice_UID"
let settingsSelector = AudioObjectPropertySelector(0x6E66_7374) // 'nfst'
let statusSelector = AudioObjectPropertySelector(0x6E66_7373) // 'nfss'

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("nearfield_driver_status: \(message)\n".utf8))
    exit(2)
}

func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

func translate(uid: String, selector: AudioObjectPropertySelector) -> AudioObjectID? {
    var address = address(selector)
    var uidString = uid as CFString
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let status = withUnsafeMutablePointer(to: &uidString) { uidPointer in
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &objectID
        )
    }
    return status == noErr && objectID != kAudioObjectUnknown ? objectID : nil
}

func nearfieldBox() -> AudioObjectID {
    guard let box = translate(uid: boxUID, selector: kAudioHardwarePropertyTranslateUIDToBox) else {
        fail("the Nearfield driver is not loaded")
    }
    var statusAddress = address(statusSelector)
    guard AudioObjectHasProperty(box, &statusAddress) else {
        fail("the installed driver is older than 1.1.0 and has no status property")
    }
    return box
}

func readStatus(_ box: AudioObjectID) -> [String: Any] {
    var address = address(statusSelector)
    var value: Unmanaged<CFPropertyList>?
    var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
    let status = AudioObjectGetPropertyData(box, &address, 0, nil, &size, &value)
    guard status == noErr, let dictionary = value?.takeRetainedValue() as? [String: Any] else {
        fail("could not read the driver status (\(status))")
    }
    return dictionary
}

func number(_ status: [String: Any], _ key: String) -> Double {
    (status[key] as? NSNumber)?.doubleValue ?? 0
}

func counter(_ status: [String: Any], _ key: String) -> Int {
    ((status["counters"] as? [String: Any])?[key] as? NSNumber)?.intValue ?? 0
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

func summaryLine(_ status: [String: Any]) -> String {
    let fields: [String] = [
        timestamp(),
        "ready=\(status["ready"] as? Bool ?? false)",
        "running=\(status["outputRunning"] as? Bool ?? false)",
        "rate=\(Int(number(status, "sampleRate")))",
        String(format: "latency=%.1fms", number(status, "latencyMilliseconds")),
        String(format: "buffered=%.1fms", number(status, "bufferedMilliseconds")),
        String(format: "gap=%.1fms", number(status, "safetyGapMilliseconds")),
        String(format: "clock=%+.0fppm", number(status, "clockCorrectionPPM")),
        "underruns=\(counter(status, "underruns"))",
        "overruns=\(counter(status, "overruns"))",
        "coldStarts=\(counter(status, "coldStarts"))",
        String(format: "lastColdStart=%.0fms", ((status["counters"] as? [String: Any])?["lastColdStartMilliseconds"] as? NSNumber)?.doubleValue ?? 0),
        "halRequests=\(counter(status, "halRequests"))",
    ]
    return fields.joined(separator: " ")
}

func printJSON(_ status: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) else {
        fail("the status is not JSON-compatible")
    }
    print(String(decoding: data, as: UTF8.self))
}

// MARK: Sample rate

func nominalSampleRate(_ device: AudioObjectID) -> Double {
    var address = address(kAudioDevicePropertyNominalSampleRate)
    var rate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
    return rate
}

func setNominalSampleRate(_ device: AudioObjectID, _ rate: Double) {
    var address = address(kAudioDevicePropertyNominalSampleRate)
    var value = Float64(rate)
    let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    if status != noErr {
        fail("could not set Nearfield to \(rate) Hz (\(status)); the displays may not offer it")
    }
}

// MARK: Tone

final class Tone {
    private let engine = AVAudioEngine()

    func start() {
        let format = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        var phase = 0.0
        let increment = 2 * Double.pi * 440 / sampleRate
        let amplitude = Float(pow(10.0, -30.0 / 20.0))
        let source = AVAudioSourceNode { _, _, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for frame in 0..<Int(frameCount) {
                let sample = amplitude * Float(sin(phase))
                phase += increment
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                }
            }
            return noErr
        }
        engine.attach(source)
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        do {
            if #available(macOS 27, *) {
                try engine.connectNode(source, to: engine.mainMixerNode, format: sourceFormat)
            } else {
                engine.connect(source, to: engine.mainMixerNode, format: sourceFormat)
            }
            try engine.start()
        } catch {
            fail("could not play the tone: \(error)")
        }
    }

    func stop() {
        engine.stop()
    }
}

// MARK: Modes

func watch(_ box: AudioObjectID) -> Never {
    print(summaryLine(readStatus(box)))
    var address = address(statusSelector)
    let listener: AudioObjectPropertyListenerBlock = { _, _ in
        print(summaryLine(readStatus(box)))
    }
    guard AudioObjectAddPropertyListenerBlock(box, &address, .main, listener) == noErr else {
        fail("could not observe the driver status")
    }
    dispatchMain()
}

func soak(_ box: AudioObjectID, minutes: Double, interval: TimeInterval, sampleRate: Double?, playTone: Bool) -> Never {
    let device = translate(uid: deviceUID, selector: kAudioHardwarePropertyTranslateUIDToDevice)
    let previousRate = device.map(nominalSampleRate)
    if let sampleRate {
        guard let device else { fail("the Nearfield device is not available") }
        setNominalSampleRate(device, sampleRate)
    }
    let tone = playTone ? Tone() : nil
    tone?.start()

    let first = readStatus(box)
    let start = Date()
    var maxLatency = number(first, "latencyMilliseconds")
    var maxGap = number(first, "safetyGapMilliseconds")
    var lastUnderruns = counter(first, "underruns")
    print("soak: \(Int(minutes)) min at \(Int(number(first, "sampleRate"))) Hz, driver \(first["driverVersion"] as? String ?? "?")")
    print(summaryLine(first))

    func finish() -> Never {
        tone?.stop()
        if sampleRate != nil, let device, let previousRate, previousRate > 0 {
            setNominalSampleRate(device, previousRate)
        }
        let last = readStatus(box)
        let underruns = counter(last, "underruns") - counter(first, "underruns")
        let minutesRun = Date().timeIntervalSince(start) / 60
        print("")
        print(String(format: "summary: %.1f min, %d underruns, %d overruns, %d cold starts, max latency %.1f ms, max safety gap %.1f ms",
                     minutesRun,
                     underruns,
                     counter(last, "overruns") - counter(first, "overruns"),
                     counter(last, "coldStarts") - counter(first, "coldStarts"),
                     maxLatency,
                     maxGap))
        if counter(last, "underruns") < counter(first, "underruns") {
            print("note: the driver restarted during the soak; counters were reset")
        }
        exit(underruns > 0 ? 1 : 0)
    }

    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler { finish() }
    interrupt.resume()

    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + interval, repeating: interval)
    timer.setEventHandler {
        let status = readStatus(box)
        maxLatency = max(maxLatency, number(status, "latencyMilliseconds"))
        maxGap = max(maxGap, number(status, "safetyGapMilliseconds"))
        let underruns = counter(status, "underruns")
        print(summaryLine(status) + (underruns > lastUnderruns ? "  <- +\(underruns - lastUnderruns) underrun(s)" : ""))
        lastUnderruns = underruns
        if Date().timeIntervalSince(start) >= minutes * 60 {
            finish()
        }
    }
    timer.resume()
    dispatchMain()
}

/// Writes a setting with its current value. The driver rejects writes from
/// processes that are not Nearfield signed by the driver's team; an
/// unsigned (development) driver accepts everyone.
func probeWrite(_ box: AudioObjectID) -> Never {
    let before = readStatus(box)
    var address = address(settingsSelector)
    var settings = ["diagnostics": before["diagnostics"] as? Bool ?? false] as CFDictionary
    let status = withUnsafeMutablePointer(to: &settings) { pointer in
        AudioObjectSetPropertyData(box, &address, 0, nil, UInt32(MemoryLayout<CFDictionary>.size), pointer)
    }
    let verification = readStatus(box)["writerVerification"] as? String ?? "?"
    switch status {
    case noErr:
        print("accepted: this process may change the driver's settings (writerVerification=\(verification))")
    case OSStatus(kAudioHardwareIllegalOperationError):
        print("rejected: the driver only accepts settings from Nearfield (writerVerification=\(verification))")
    default:
        print("failed with \(status) (writerVerification=\(verification))")
    }
    exit(0)
}

// MARK: Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let box = nearfieldBox()
if arguments.contains("--watch") {
    watch(box)
} else if arguments.contains("--probe-write") {
    probeWrite(box)
} else if let minutes = value(after: "--soak").flatMap(Double.init) {
    soak(
        box,
        minutes: minutes,
        interval: value(after: "--interval").flatMap(Double.init) ?? 60,
        sampleRate: value(after: "--sample-rate").flatMap(Double.init),
        playTone: arguments.contains("--tone")
    )
} else if arguments.isEmpty {
    printJSON(readStatus(box))
} else {
    fail("usage: nearfield_driver_status.swift [--watch | --probe-write | --soak MINUTES [--interval S] [--sample-rate HZ] [--tone]]")
}
