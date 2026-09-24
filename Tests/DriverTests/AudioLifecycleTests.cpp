// Exercise the real driver callbacks without initializing a HAL plug-in or
// selecting, installing, or modifying any system audio device.
//
// ./script/test_router_driver.sh builds this three times: plain (including
// the allocation guard), with Address/Undefined Behavior Sanitizer, and with
// Thread Sanitizer for the tests that run audio threads concurrently.
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <future>
#include <iostream>
#include <limits>
#include <mutex>
#include <pthread.h>
#include <random>
#include <string>
#include <thread>
#include <vector>
#include "../../Vendor/app-router-audio-device/proxyAudioDevice/ProxyAudioDevice.cpp"

#define CHECK(condition)                                                                                  \
    do {                                                                                                  \
        if (!(condition)) {                                                                               \
            std::fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition);           \
            std::abort();                                                                                 \
        }                                                                                                 \
    } while (0)

// MARK: Fake plug-in host

namespace {

struct FakeHostState {
    std::mutex mutex;
    CFMutableDictionaryRef storage = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                                               &kCFTypeDictionaryValueCallBacks);
    int settingsWrites = 0;
    std::vector<AudioObjectPropertySelector> changedSelectors;
    std::vector<UInt64> configurationRequests;

    void reset() {
        std::lock_guard<std::mutex> lock(mutex);
        CFDictionaryRemoveAllValues(storage);
        settingsWrites = 0;
        changedSelectors.clear();
        configurationRequests.clear();
    }

    bool sawChange(AudioObjectPropertySelector selector) {
        std::lock_guard<std::mutex> lock(mutex);
        return std::find(changedSelectors.begin(), changedSelectors.end(), selector) != changedSelectors.end();
    }
};

// Never destroyed: notifications queued by leaked drivers may still arrive
// while the process exits.
FakeHostState &gHost = *new FakeHostState;

OSStatus fakePropertiesChanged(AudioServerPlugInHostRef, AudioObjectID, UInt32 count, const AudioObjectPropertyAddress *addresses) {
    std::lock_guard<std::mutex> lock(gHost.mutex);
    for (UInt32 index = 0; index < count; ++index) {
        gHost.changedSelectors.push_back(addresses[index].mSelector);
    }
    return noErr;
}

OSStatus fakeCopyFromStorage(AudioServerPlugInHostRef, CFStringRef key, CFPropertyListRef *outData) {
    std::lock_guard<std::mutex> lock(gHost.mutex);
    CFPropertyListRef value = CFDictionaryGetValue(gHost.storage, key);
    *outData = value ? CFPropertyListCreateDeepCopy(NULL, value, kCFPropertyListImmutable) : NULL;
    return noErr;
}

OSStatus fakeWriteToStorage(AudioServerPlugInHostRef, CFStringRef key, CFPropertyListRef data) {
    std::lock_guard<std::mutex> lock(gHost.mutex);
    CFDictionarySetValue(gHost.storage, key, data);
    if (CFEqual(key, CFSTR("settings"))) {
        ++gHost.settingsWrites;
    }
    return noErr;
}

OSStatus fakeDeleteFromStorage(AudioServerPlugInHostRef, CFStringRef key) {
    std::lock_guard<std::mutex> lock(gHost.mutex);
    CFDictionaryRemoveValue(gHost.storage, key);
    return noErr;
}

OSStatus fakeRequestConfigurationChange(AudioServerPlugInHostRef, AudioObjectID, UInt64 action, void *) {
    std::lock_guard<std::mutex> lock(gHost.mutex);
    gHost.configurationRequests.push_back(action);
    return noErr;
}

const AudioServerPlugInHostInterface gFakeHost = {
    fakePropertiesChanged, fakeCopyFromStorage, fakeWriteToStorage, fakeDeleteFromStorage, fakeRequestConfigurationChange,
};

constexpr UInt32 kFrames = 512;
constexpr double kRate = 48000.0;

// The driver is a process-lifetime singleton in coreaudiod; tests leak it the
// same way so work queued on its dispatch queue never outlives it.
struct DriverFixture {
    ProxyAudioDevice &device = *new ProxyAudioDevice;
    Float32 samples[kFrames * 2];
    Float32 output[kFrames * 2] = {};
    Float64 nextFrame = 0;

    explicit DriverFixture(bool loadStorage = true) {
        if (loadStorage) {
            gHost.reset();
        }
        device.gPlugIn_Host = &gFakeHost;
        device.manageOutputDevice = false;
        device.initializedHostTime = mach_absolute_time();
        device.audioOutputQueue = dispatch_queue_create("nearfield.driver-tests", DISPATCH_QUEUE_SERIAL);
        device.engineSignalSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, device.audioOutputQueue);
        ProxyAudioDevice *driver = &device;
        dispatch_source_set_event_handler(device.engineSignalSource, ^{
            driver->handleEngineSignals(dispatch_source_get_data(driver->engineSignalSource));
        });
        dispatch_resume(device.engineSignalSource);
        device.loadSettingsFromStorage();
        device.loadOwnTeamIdentifier();
        device.renderBuffer = new Float32[nearfield::kMaxRenderFrames * 2]();
        const Float64 rate = device.settings.sampleRate > 0 ? device.settings.sampleRate : kRate;
        device.gDevice_SampleRate = rate;
        device.deviceClock.setHostTicksPerFrame(hostTicksPerSecond() / rate);
        device.engine.configure(rate);
        device.engine.setOutputFormat(rate, kFrames, 0);
        fill(0.5f, 0.5f);
    }

    ~DriverFixture() { drain(); }

    void drain() { dispatch_sync(device.audioOutputQueue, ^{}); }

    void fill(Float32 left, Float32 right) {
        for (UInt32 frame = 0; frame < kFrames; ++frame) {
            samples[frame * 2] = left;
            samples[frame * 2 + 1] = right;
        }
    }

    void start(UInt32 client) {
        CHECK(device.StartIO(gAudioServerPlugInDriverRef, kObjectID_Device, client) == noErr);
        drain();
        nextFrame = 0;
    }

    void stop(UInt32 client) {
        CHECK(device.StopIO(gAudioServerPlugInDriverRef, kObjectID_Device, client) == noErr);
        drain();
    }

    void addClient(UInt32 client, pid_t pid, CFStringRef bundleID) {
        const AudioServerPlugInClientInfo info = {client, pid, true, bundleID};
        CHECK(device.AddDeviceClient(gAudioServerPlugInDriverRef, kObjectID_Device, &info) == noErr);
    }

    void removeClient(UInt32 client, pid_t pid) {
        const AudioServerPlugInClientInfo info = {client, pid, true, NULL};
        CHECK(device.RemoveDeviceClient(gAudioServerPlugInDriverRef, kObjectID_Device, &info) == noErr);
    }

    AudioServerPlugInIOCycleInfo cycle(Float64 frame) {
        AudioServerPlugInIOCycleInfo info = {};
        info.mOutputTime.mSampleTime = frame;
        info.mOutputTime.mHostTime = mach_absolute_time();
        info.mOutputTime.mRateScalar = 1;
        info.mOutputTime.mFlags = kAudioTimeStampSampleHostTimeValid | kAudioTimeStampRateScalarValid;
        info.mCurrentTime = info.mOutputTime;
        return info;
    }

    void processOutput(UInt32 client, Float32 *buffer, Float64 frame) {
        AudioServerPlugInIOCycleInfo info = cycle(frame);
        CHECK(device.DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device, kObjectID_Stream_Output, client,
                                   kAudioServerPlugInIOOperationProcessOutput, kFrames, &info, buffer, nullptr) == noErr);
    }

    void writeMix(const Float32 *buffer, Float64 frame) {
        AudioServerPlugInIOCycleInfo info = cycle(frame);
        CHECK(device.DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device, kObjectID_Stream_Output, 1,
                                   kAudioServerPlugInIOOperationWriteMix, kFrames, &info, (void *)buffer, nullptr) == noErr);
    }

    // One IO cycle of a single client: its audio, routed, becomes the mix.
    void write(UInt32 client = 1) {
        Float32 buffer[kFrames * 2];
        std::copy(samples, samples + kFrames * 2, buffer);
        processOutput(client, buffer, nextFrame);
        writeMix(buffer, nextFrame);
        nextFrame += kFrames;
    }

    void render() {
        std::fill(output, output + kFrames * 2, 0.0f);
        AudioBufferList buffers = {1, {{2, sizeof(output), output}}};
        AudioTimeStamp now = {};
        now.mHostTime = mach_absolute_time();
        AudioTimeStamp outputTime = now;
        outputTime.mRateScalar = 1;
        outputTime.mFlags = kAudioTimeStampSampleHostTimeValid | kAudioTimeStampRateScalarValid;
        CHECK(device.outputDeviceIOProc(0, &now, nullptr, nullptr, &buffers, &outputTime) == noErr);
    }

    // Writes and renders one cycle each, as the two IO threads would.
    void cycleOnce(UInt32 client = 1) {
        write(client);
        render();
    }

    OSStatus applySettings(CFDictionaryRef dictionary) {
        nearfield::SettingsUpdate update;
        if (!nearfield::parseSettingsUpdate(dictionary, update)) {
            return kAudioHardwareIllegalOperationError;
        }
        const OSStatus status = device.applySettings(update, getpid());
        drain();
        return status;
    }

    OSStatus setBoxProperty(AudioObjectPropertySelector selector, UInt32 size, const void *data, pid_t pid = getpid()) {
        AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        return device.SetPropertyData(gAudioServerPlugInDriverRef, kObjectID_Box, pid, &address, 0, nullptr, size, data);
    }

    CFTypeRef copyBoxProperty(AudioObjectPropertySelector selector, pid_t pid = getpid()) {
        AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        CFTypeRef value = NULL;
        UInt32 size = 0;
        CHECK(device.GetPropertyData(gAudioServerPlugInDriverRef, kObjectID_Box, pid, &address, 0, nullptr,
                                     sizeof(value), &size, &value) == noErr);
        return value;
    }
};

CFDictionaryRef dictionary(std::initializer_list<std::pair<CFStringRef, CFTypeRef>> entries) {
    CFMutableDictionaryRef result =
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (const auto &entry : entries) {
        CFDictionarySetValue(result, entry.first, entry.second);
    }
    return result;
}

CFArrayRef strings(std::initializer_list<CFStringRef> values) {
    std::vector<const void *> items(values.begin(), values.end());
    return CFArrayCreate(NULL, items.data(), (CFIndex)items.size(), &kCFTypeArrayCallBacks);
}

bool near(Float32 value, Float32 expected, Float32 tolerance = 1e-4f) {
    return std::fabs(value - expected) <= tolerance;
}

bool allFrames(const Float32 *buffer, Float32 left, Float32 right) {
    for (UInt32 frame = 0; frame < kFrames; ++frame) {
        if (!near(buffer[frame * 2], left) || !near(buffer[frame * 2 + 1], right)) {
            return false;
        }
    }
    return true;
}

// Writes and renders until the reader leaves its prefill and plays steadily.
void playUntilSteady(DriverFixture &f, UInt32 client = 1, Float32 left = 0.5f, Float32 right = 0.5f) {
    for (int cycle = 0; cycle < 12; ++cycle) {
        f.cycleOnce(client);
    }
    CHECK(allFrames(f.output, left, right));
}

} // namespace

// MARK: Lifecycle

static void testOverlappingClientsPreservePlayback() {
    DriverFixture f;
    f.start(1);
    playUntilSteady(f);
    CHECK(f.device.StartIO(gAudioServerPlugInDriverRef, kObjectID_Device, 2) == noErr);
    CHECK(f.device.gDevice_IOIsRunning == 2);
    f.cycleOnce();
    CHECK(allFrames(f.output, 0.5f, 0.5f));
    f.stop(2);
    CHECK(f.device.gDevice_IOIsRunning == 1 && f.device.engine.hasActiveClients());
    f.cycleOnce();
    CHECK(allFrames(f.output, 0.5f, 0.5f));
    CHECK(f.device.engine.counters().underruns.load() == 0);

    // The last client stops: everything buffered still plays, then silence.
    f.stop(1);
    CHECK(!f.device.engine.hasActiveClients() && !f.device.engine.isDrained());
    UInt32 playedFrames = 0;
    for (int cycle = 0; cycle < 20; ++cycle) {
        f.render();
        for (UInt32 frame = 0; frame < kFrames; ++frame) {
            playedFrames += f.output[frame * 2] != 0.0f ? 1 : 0;
        }
    }
    CHECK(playedFrames > kFrames * 2);
    CHECK(f.device.engine.isDrained());
    CHECK(f.device.engine.counters().underruns.load() == 0);

    // A new session is appended; its timeline starts again at zero.
    f.fill(0.25f, 0.25f);
    f.start(3);
    playUntilSteady(f, 3, 0.25f, 0.25f);
}

static void testInvalidLifecycleCallsDoNotChangeAudio() {
    DriverFixture f;
    f.start(1);
    f.write();
    CHECK(f.device.StartIO(nullptr, kObjectID_Device, 2) == kAudioHardwareBadObjectError);
    CHECK(f.device.StopIO(nullptr, kObjectID_Device, 1) == kAudioHardwareBadObjectError);
    CHECK(f.device.StartIO(gAudioServerPlugInDriverRef, kObjectID_Box, 2) == kAudioHardwareBadObjectError);
    CHECK(f.device.StopIO(gAudioServerPlugInDriverRef, kObjectID_Box, 1) == kAudioHardwareBadObjectError);
    CHECK(f.device.gDevice_IOIsRunning == 1 && f.device.engine.hasActiveClients());
    f.stop(1);
    CHECK(f.device.StopIO(gAudioServerPlugInDriverRef, kObjectID_Device, 1) == kAudioHardwareIllegalOperationError);
    f.drain();
}

// MARK: Routing

static void enableRouting(DriverFixture &f, CFStringRef rules) {
    CFDictionarySmartRef settings(dictionary({{nearfield::kSettingsRoutingEnabledKey, kCFBooleanTrue},
                                              {nearfield::kSettingsRouteRulesKey, rules}}));
    CHECK(f.applySettings(settings) == noErr);
}

static void testRoutedMixSurvivesClientStop() {
    DriverFixture f;
    enableRouting(f, CFSTR("test.left=left; test.right=right"));
    f.addClient(1, 101, CFSTR("test.left"));
    f.addClient(2, 102, CFSTR("test.right"));
    f.start(1);
    CHECK(f.device.StartIO(gAudioServerPlugInDriverRef, kObjectID_Device, 2) == noErr);

    auto mixedCycle = [&](bool secondClient) {
        Float32 first[kFrames * 2];
        Float32 second[kFrames * 2];
        std::copy(f.samples, f.samples + kFrames * 2, first);
        std::copy(f.samples, f.samples + kFrames * 2, second);
        f.processOutput(1, first, f.nextFrame);
        if (secondClient) {
            f.processOutput(2, second, f.nextFrame);
            for (UInt32 index = 0; index < kFrames * 2; ++index) {
                first[index] += second[index];
            }
        }
        f.writeMix(first, f.nextFrame);
        f.nextFrame += kFrames;
        f.render();
    };
    for (int cycle = 0; cycle < 12; ++cycle) {
        mixedCycle(true);
    }
    CHECK(allFrames(f.output, 0.5f, 0.5f));

    CHECK(f.device.StopIO(gAudioServerPlugInDriverRef, kObjectID_Device, 2) == noErr);
    f.removeClient(2, 102);
    for (int cycle = 0; cycle < 12; ++cycle) {
        mixedCycle(false);
    }
    CHECK(allFrames(f.output, 0.5f, 0.0f));
}

static void testClosingSilentSafariClientPreservesPlayingHelper() {
    DriverFixture f;
    enableRouting(f, CFSTR("com.apple.Safari=left; com.apple.WebKit.GPU=left"));
    f.addClient(1, 101, CFSTR("com.apple.WebKit.GPU"));
    f.start(1);
    playUntilSteady(f, 1, 0.5f, 0.0f);
    f.addClient(2, 102, CFSTR("com.apple.Safari"));
    CHECK(f.device.StartIO(gAudioServerPlugInDriverRef, kObjectID_Device, 2) == noErr);
    f.cycleOnce();
    f.stop(2);
    f.removeClient(2, 102);
    for (int cycle = 0; cycle < 4; ++cycle) {
        f.cycleOnce();
        CHECK(allFrames(f.output, 0.5f, 0.0f));
    }
    CHECK(f.device.engine.hasActiveClients());
    CHECK(f.device.engine.counters().underruns.load() == 0);
}

static void testRoutingToggleAffectsAudioAlreadyPlaying() {
    DriverFixture f;
    f.addClient(1, 101, CFSTR("test.left"));
    f.start(1);
    playUntilSteady(f);
    // Turning routing on applies to the running client without restarting IO.
    enableRouting(f, CFSTR("test.left=left"));
    for (int cycle = 0; cycle < 8; ++cycle) {
        f.cycleOnce();
    }
    CHECK(allFrames(f.output, 0.5f, 0.0f));
    CFDictionarySmartRef off(dictionary({{nearfield::kSettingsRoutingEnabledKey, kCFBooleanFalse}}));
    CHECK(f.applySettings(off) == noErr);
    for (int cycle = 0; cycle < 8; ++cycle) {
        f.cycleOnce();
    }
    CHECK(allFrames(f.output, 0.5f, 0.5f));
}

static void testRouteChangesCrossfade() {
    DriverFixture f;
    enableRouting(f, CFSTR(""));
    f.addClient(1, 4242, CFSTR("test.app"));
    Float32 buffer[kFrames * 2];
    std::copy(f.samples, f.samples + kFrames * 2, buffer);
    f.processOutput(1, buffer, 0);
    CHECK(allFrames(buffer, 0.5f, 0.5f));

    // A process route (the window-following fast path) moves the client left.
    CFDictionarySmartRef routes(dictionary({{CFSTR("4242"), CFSTR("left")}}));
    CFDictionarySmartRef update(dictionary({{nearfield::kSettingsProcessRoutesKey, routes}}));
    const int writesBefore = gHost.settingsWrites;
    CHECK(f.applySettings(update) == noErr);
    CHECK(gHost.settingsWrites == writesBefore);  // never saved

    const UInt32 crossfade = f.device.engine.crossfadeFrames();
    CHECK(crossfade == 480);
    Float32 moving[kFrames * 2];
    std::copy(f.samples, f.samples + kFrames * 2, moving);
    f.processOutput(1, moving, kFrames);
    // No step: the right channel falls gradually while the left stays full.
    CHECK(moving[1] > 0.49f && moving[1] < 0.5f);
    CHECK(moving[(kFrames / 2) * 2 + 1] > 0.1f && moving[(kFrames / 2) * 2 + 1] < 0.4f);
    for (UInt32 frame = 1; frame < kFrames; ++frame) {
        CHECK(moving[frame * 2 + 1] <= moving[(frame - 1) * 2 + 1] + 1e-6f);
        CHECK(near(moving[frame * 2], 0.5f, 1e-3f));
    }
    Float32 settled[kFrames * 2];
    std::copy(f.samples, f.samples + kFrames * 2, settled);
    f.processOutput(1, settled, kFrames * 2);
    CHECK(allFrames(settled, 0.5f, 0.0f));
}

// MARK: Output

static void testRenderDoesNotWaitForConfigurationMutex() {
    DriverFixture f;
    f.start(1);
    playUntilSteady(f);
    std::promise<void> rendered;
    auto completion = rendered.get_future();
    f.device.stateMutex.lock();
    std::thread callback([&] {
        f.cycleOnce();
        rendered.set_value();
    });
    const bool completedWhileLocked = completion.wait_for(std::chrono::seconds(2)) == std::future_status::ready;
    f.device.stateMutex.unlock();
    callback.join();
    CHECK(completedWhileLocked);
    CHECK(allFrames(f.output, 0.5f, 0.5f));
}

static void testVolumeMuteAndBalanceAreSmoothed() {
    DriverFixture f;
    f.start(1);
    playUntilSteady(f);
    f.device.gVolume_Output_L_Value = 0;
    f.cycleOnce();
    // About 5 ms (240 frames) from full to silent, without a step.
    CHECK(f.output[0] > 0.49f);
    CHECK(f.output[120 * 2] > 0.1f && f.output[120 * 2] < 0.4f);
    CHECK(near(f.output[260 * 2], 0.0f));
    CHECK(near(f.output[1], 0.5f));
    f.cycleOnce();
    CHECK(allFrames(f.output, 0.0f, 0.5f));

    f.device.gVolume_Output_L_Value = 1;
    f.device.gMute_Output_Mute = true;
    f.cycleOnce();
    CHECK(f.output[1] > 0.49f);
    f.cycleOnce();
    CHECK(allFrames(f.output, 0.0f, 0.0f));
    f.device.gMute_Output_Mute = false;
    f.cycleOnce();
    f.cycleOnce();
    CHECK(allFrames(f.output, 0.5f, 0.5f));
}

static void testColdStartPlaysFromFirstSampleThenTrimsDuringSilence() {
    DriverFixture f;
    f.start(1);
    // The displays take a while to start; about 213 ms is written meanwhile.
    for (int cycle = 0; cycle < 20; ++cycle) {
        f.fill(cycle == 0 ? 0.75f : 0.5f, cycle == 0 ? 0.75f : 0.5f);
        f.write();
    }
    f.device.engine.noteOutputStarting();
    f.render();
    f.drain();
    CHECK(f.device.engine.counters().coldStarts.load() == 1);
    // The first written sample is played (after a short fade-in).
    CHECK(f.output[0] > 0.0f && f.output[0] < 0.75f);
    CHECK(near(f.output[200 * 2], 0.75f));
    const double buffered = f.device.engine.lastBufferedMilliseconds();
    CHECK(buffered > 150);

    // Once the audio is silent, the extra delay is dropped.
    f.fill(0, 0);
    for (int cycle = 0; cycle < 40; ++cycle) {
        f.cycleOnce();
    }
    CHECK(f.device.engine.counters().trimmedFrames.load() > 0);
    CHECK(f.device.engine.lastBufferedMilliseconds() < 40);
    CHECK(f.device.engine.counters().underruns.load() == 0);
}

static void testUnderrunFadesOutAndWidensTheSafetyGap() {
    DriverFixture f;
    f.start(1);
    playUntilSteady(f);
    const double gapBefore = f.device.engine.currentSafetyGapMilliseconds();
    // The writer stops while the client is still running: a real underrun.
    // Whatever is rendered last before the silence fades out instead of
    // stopping abruptly.
    Float32 previous[kFrames * 2] = {};
    bool reachedSilence = false;
    for (int cycle = 0; cycle < 8 && !reachedSilence; ++cycle) {
        f.render();
        if (allFrames(f.output, 0.0f, 0.0f)) {
            reachedSilence = true;
            UInt32 last = 0;
            for (UInt32 frame = 0; frame < kFrames; ++frame) {
                if (previous[frame * 2] != 0.0f) last = frame;
            }
            CHECK(previous[last * 2] > 0.0f && previous[last * 2] < 0.05f);
            CHECK(near(previous[0], 0.5f));
        }
        std::copy(f.output, f.output + kFrames * 2, previous);
    }
    CHECK(reachedSilence);
    f.drain();
    CHECK(f.device.engine.counters().underruns.load() == 1);
    CHECK(f.device.engine.currentSafetyGapMilliseconds() > gapBefore);
    // The writer resumes: playback restarts with a fade-in after prefilling.
    for (int cycle = 0; cycle < 12; ++cycle) {
        f.cycleOnce();
    }
    CHECK(allFrames(f.output, 0.5f, 0.5f));
    CHECK(f.device.engine.counters().underruns.load() == 1);
}

// MARK: Settings, status and the legacy channel

static CFStringRef stringValue(CFDictionaryRef dictionaryValue, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(dictionaryValue, key);
    return value && CFGetTypeID(value) == CFStringGetTypeID() ? (CFStringRef)value : NULL;
}

static void testSettingsApplyInOneStepAndSaveOnlyChanges() {
    DriverFixture f;
    const int initialWrites = gHost.settingsWrites;
    CFArraySmartRef targets(strings({CFSTR("left-uid"), CFSTR("right-uid")}));
    CFDictionarySmartRef routes(dictionary({{CFSTR("77"), CFSTR("right")}}));
    CFDictionarySmartRef update(dictionary({
        {nearfield::kSettingsDeviceNameKey, CFSTR("Desk")},
        {nearfield::kSettingsTargetDevicesKey, targets},
        {nearfield::kSettingsTargetModeKey, CFSTR("mono")},
        {nearfield::kSettingsRoutingEnabledKey, kCFBooleanTrue},
        {nearfield::kSettingsRouteRulesKey, CFSTR("a.app=left; pid:42=right")},
        {nearfield::kSettingsProcessRoutesKey, routes},
    }));
    const UInt64 revision = f.device.targetConfigurationRevision;
    CHECK(f.applySettings(update) == noErr);
    CHECK(gHost.settingsWrites == initialWrites + 1);
    CHECK(f.device.targetConfigurationRevision == revision + 1);
    CHECK(f.device.settings.deviceName == "Desk");
    CHECK(!f.device.settings.stereo);
    CHECK(f.device.settings.routeRules == "a.app=left");
    CHECK(f.device.processRoutes.size() == 1 && f.device.processRoutes[77] == nearfield::Route::right);

    CFDictionaryRef saved = NULL;
    fakeCopyFromStorage(&gFakeHost, CFSTR("settings"), (CFPropertyListRef *)&saved);
    CHECK(saved != NULL);
    CHECK(CFEqual(stringValue(saved, nearfield::kSettingsRouteRulesKey), CFSTR("a.app=left")));
    CHECK(!CFDictionaryContainsKey(saved, nearfield::kSettingsProcessRoutesKey));
    CFRelease(saved);

    // Sending the same settings again changes and saves nothing.
    CHECK(f.applySettings(update) == noErr);
    CHECK(gHost.settingsWrites == initialWrites + 1);
    CHECK(f.device.targetConfigurationRevision == revision + 1);

    // An invalid update is rejected as a whole.
    CFArraySmartRef badTargets(strings({CFSTR("x")}));
    CFMutableArrayRef mixed = CFArrayCreateMutableCopy(NULL, 0, badTargets);
    int number = 3;
    CFNumberSmartRef numberValue(CFNumberCreate(NULL, kCFNumberIntType, &number));
    CFArrayAppendValue(mixed, numberValue);
    CFDictionarySmartRef invalid(dictionary({{nearfield::kSettingsDeviceNameKey, CFSTR("Other")},
                                             {nearfield::kSettingsTargetDevicesKey, mixed}}));
    CFRelease(mixed);
    CFPropertyListRef invalidList = invalid;
    CHECK(f.setBoxProperty(kNearfieldPropertySettings, sizeof(invalidList), &invalidList) != noErr);
    CHECK(f.device.settings.deviceName == "Desk");

    // The device name is published through the device's name property.
    CFTypeRef name = NULL;
    UInt32 size = 0;
    AudioObjectPropertyAddress nameAddress = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
    CHECK(f.device.GetPropertyData(gAudioServerPlugInDriverRef, kObjectID_Device, 0, &nameAddress, 0, nullptr,
                                   sizeof(name), &size, &name) == noErr);
    CHECK(CFEqual(name, CFSTR("Desk")));
    CFRelease(name);

    // Settings survive a restart; process routes do not.
    DriverFixture restarted(false);
    CHECK(restarted.device.settings.deviceName == "Desk");
    CHECK(restarted.device.settings.targetDevices.size() == 2);
    CHECK(restarted.device.processRoutes.empty());
}

static void testLegacyDriverSettingsAreMigrated() {
    gHost.reset();
    CFNumberSmartRef routing(CFNumberCreate(NULL, kCFNumberSInt32Type, (const SInt32[]){1}));
    fakeWriteToStorage(&gFakeHost, CFSTR("deviceName"), CFSTR("Legacy"));
    fakeWriteToStorage(&gFakeHost, CFSTR("targetAggregateDevices"), CFSTR("a\nb"));
    fakeWriteToStorage(&gFakeHost, CFSTR("routingEnabled"), routing);
    fakeWriteToStorage(&gFakeHost, CFSTR("routeRules"), CFSTR("x.app=right; pid:5=left"));
    fakeWriteToStorage(&gFakeHost, CFSTR("outputDeviceUID"), CFSTR(kDriverTargetAggregate_UID));
    DriverFixture f(false);
    CHECK(f.device.settings.deviceName == "Legacy");
    CHECK((f.device.settings.targetDevices == std::vector<std::string>{"a", "b"}));
    CHECK(f.device.settings.routingEnabled);
    CHECK(f.device.settings.routeRules == "x.app=right");
    CHECK(f.device.settings.outputDeviceUID.empty());
    CHECK(f.device.processRoutes.empty());
}

static void testLegacyConfigurationChannelStillWorks() {
    DriverFixture f;
    const SInt32 pid = getpid();
    // Registering another process as the configurator is refused.
    const SInt32 otherPid = pid + 1;
    CHECK(f.setBoxProperty(kAudioObjectPropertyIdentify, sizeof(otherPid), &otherPid) == noErr);
    CHECK(f.device.configuratorPid == 0);
    CHECK(f.setBoxProperty(kAudioObjectPropertyIdentify, sizeof(pid), &pid) == noErr);
    CHECK(f.device.configuratorPid == pid);

    auto legacyWrite = [&](CFStringRef configuration) {
        CHECK(f.setBoxProperty(kAudioObjectPropertyName, sizeof(configuration), &configuration) == noErr);
        f.drain();
    };
    auto legacyRead = [&](ProxyAudioDevice::ConfigType type) {
        const SInt32 request = -(SInt32)type;
        CHECK(f.setBoxProperty(kAudioObjectPropertyIdentify, sizeof(request), &request) == noErr);
        return (CFStringRef)f.copyBoxProperty(kAudioObjectPropertyName);
    };

    legacyWrite(CFSTR("routingEnabled=1"));
    legacyWrite(CFSTR("routeRules=b.app=right; pid:9=left"));
    legacyWrite(CFSTR("targetAggregateDevices=left\nright"));
    legacyWrite(CFSTR("outputDevice=" kDriverTargetAggregate_UID));
    CHECK(f.device.settings.routingEnabled);
    CHECK(f.device.settings.routeRules == "b.app=right");
    CHECK(f.device.processRoutes.size() == 1 && f.device.processRoutes[9] == nearfield::Route::left);
    CHECK(f.device.settings.outputDeviceUID.empty());

    CFStringSmartRef rules(legacyRead(ProxyAudioDevice::ConfigType::routeRules));
    CHECK(CFEqual(rules, CFSTR("b.app=right; pid:9=left")));
    CFStringSmartRef capabilities(legacyRead(ProxyAudioDevice::ConfigType::driverCapabilities));
    CHECK(CFStringFind(capabilities, CFSTR("targetOutputReadiness"), 0).location != kCFNotFound);
    CHECK(CFStringFind(capabilities, CFSTR("settingsDictionary"), 0).location != kCFNotFound);

    // Rules without process entries clear the previous process routes.
    legacyWrite(CFSTR("routeRules=b.app=right"));
    CHECK(f.device.processRoutes.empty());

    // Another process reading the box name gets the name, not settings.
    CFStringSmartRef name((CFStringRef)f.copyBoxProperty(kAudioObjectPropertyName, pid + 7));
    CHECK(CFEqual(name, CFSTR("Nearfield Audio Box")));
}

static void testLegacyReadinessRequiresCurrentConfigurationAndInitializedOutput() {
    DriverFixture f;
    using Config = ProxyAudioDevice::ConfigType;
    CFStringSmartRef initial(f.device.copyConfigurationValue(Config::targetOutputReadiness));
    CHECK(initial && CFEqual(initial, CFSTR("pending")));

    f.device.settings.targetDevices = {"left", "right"};
    f.device.readyTargetConfigurationRevision.store(f.device.targetConfigurationRevision);
    CFStringSmartRef queued(f.device.copyConfigurationValue(Config::targetOutputReadiness));
    CHECK(queued && CFEqual(queued, CFSTR("pending")));
    f.device.appliedTargetConfigurationRevision.store(f.device.targetConfigurationRevision);
    CFStringSmartRef ready(f.device.copyConfigurationValue(Config::targetOutputReadiness));
    CHECK(ready && CFEqual(ready, CFSTR("ready\nstereo\nleft\nright")));

    ++f.device.targetConfigurationRevision;
    CFStringSmartRef stale(f.device.copyConfigurationValue(Config::targetOutputReadiness));
    CHECK(stale && CFEqual(stale, CFSTR("pending")));

    f.device.readyTargetConfigurationRevision.store(f.device.targetConfigurationRevision);
    dispatch_sync(f.device.audioOutputQueue, ^{
        f.device.refreshTargetOutputReadiness();  // No IOProc or live aggregate in the fixture.
    });
    CFStringSmartRef noOutput(f.device.copyConfigurationValue(Config::targetOutputReadiness));
    CHECK(noOutput && CFEqual(noOutput, CFSTR("pending")));
}

static void testStatusAndCustomProperties() {
    DriverFixture f;
    AudioObjectPropertyAddress address = {kNearfieldPropertySettings, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    CHECK(f.device.HasProperty(gAudioServerPlugInDriverRef, kObjectID_Box, 0, &address));
    Boolean settable = false;
    CHECK(f.device.IsPropertySettable(gAudioServerPlugInDriverRef, kObjectID_Box, 0, &address, &settable) == noErr && settable);
    address.mSelector = kNearfieldPropertyStatus;
    CHECK(f.device.IsPropertySettable(gAudioServerPlugInDriverRef, kObjectID_Box, 0, &address, &settable) == noErr && !settable);

    address.mSelector = kAudioObjectPropertyCustomPropertyInfoList;
    AudioServerPlugInCustomPropertyInfo info[4] = {};
    UInt32 size = 0;
    CHECK(f.device.GetPropertyData(gAudioServerPlugInDriverRef, kObjectID_Box, 0, &address, 0, nullptr, sizeof(info), &size,
                                   info) == noErr);
    CHECK(size == 2 * sizeof(AudioServerPlugInCustomPropertyInfo));
    CHECK(info[0].mSelector == kNearfieldPropertySettings && info[1].mSelector == kNearfieldPropertyStatus);
    CHECK(info[0].mPropertyDataType == kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);

    CFDictionarySmartRef status((CFDictionaryRef)f.copyBoxProperty(kNearfieldPropertyStatus));
    CHECK(status && CFGetTypeID(status) == CFDictionaryGetTypeID());
    CFNumberRef hostProcessID = (CFNumberRef)CFDictionaryGetValue(status, CFSTR("hostProcessID"));
    int64_t reportedProcessID = 0;
    CHECK(hostProcessID && CFNumberGetValue(hostProcessID, kCFNumberSInt64Type, &reportedProcessID));
    CHECK(reportedProcessID == getpid());
    CHECK(CFDictionaryGetValue(status, CFSTR("ready")) == kCFBooleanFalse);
    CFArrayRef capabilities = (CFArrayRef)CFDictionaryGetValue(status, CFSTR("capabilities"));
    CHECK(capabilities && CFArrayContainsValue(capabilities, CFRangeMake(0, CFArrayGetCount(capabilities)),
                                               CFSTR("settingsDictionary")));
    CFDictionaryRef counters = (CFDictionaryRef)CFDictionaryGetValue(status, CFSTR("counters"));
    CHECK(counters && CFDictionaryContainsKey(counters, CFSTR("underruns")));
    CHECK(CFDictionaryContainsKey(status, CFSTR("latencyFrames")));

    // Real manufacturer names (localized by the HAL), no data-source control.
    address = {kAudioObjectPropertyManufacturer, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    for (AudioObjectID object : {(AudioObjectID)kObjectID_PlugIn, (AudioObjectID)kObjectID_Box, (AudioObjectID)kObjectID_Device}) {
        CFStringRef manufacturer = NULL;
        CHECK(f.device.GetPropertyData(gAudioServerPlugInDriverRef, object, 0, &address, 0, nullptr, sizeof(manufacturer),
                                       &size, &manufacturer) == noErr);
        CHECK(CFEqual(manufacturer, CFSTR("ManufacturerName")));
    }
    address = {kAudioObjectPropertyControlList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID controls[8] = {};
    CHECK(f.device.GetPropertyData(gAudioServerPlugInDriverRef, kObjectID_Device, 0, &address, 0, nullptr, sizeof(controls),
                                   &size, controls) == noErr);
    CHECK(size == 3 * sizeof(AudioObjectID));
    address.mSelector = kAudioObjectPropertyClass;
    CHECK(!f.device.HasProperty(gAudioServerPlugInDriverRef, 8, 0, &address));

    // Only the displays' rates are offered.
    address = {kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioValueRange rates[8] = {};
    CHECK(f.device.GetPropertyData(gAudioServerPlugInDriverRef, kObjectID_Device, 0, &address, 0, nullptr, sizeof(rates), &size,
                                   rates) == noErr);
    CHECK(size == 4 * sizeof(AudioValueRange) && rates[0].mMinimum == 44100 && rates[3].mMaximum == 96000);
}

static void testSampleRateChangeIsRememberedAndResetsTheBuffer() {
    DriverFixture f;
    f.start(1);
    playUntilSteady(f);
    f.stop(1);
    CHECK(f.device.PerformDeviceConfigurationChange(gAudioServerPlugInDriverRef, kObjectID_Device, 96000, nullptr) == noErr);
    f.drain();
    CHECK(f.device.gDevice_SampleRate.load() == 96000);
    CHECK(f.device.engine.currentDeviceSampleRate() == 96000);
    CHECK(f.device.engine.writtenEnd() == 0);
    CHECK(f.device.PerformDeviceConfigurationChange(gAudioServerPlugInDriverRef, kObjectID_Device, 22050, nullptr) != noErr);

    DriverFixture restarted(false);
    CHECK(restarted.device.settings.sampleRate == 96000);
}

static void testDisplaysGoneHidesNearfieldAfterAboutASecond() {
    DriverFixture f;
    f.device.settings.targetDevices = {"missing-left", "missing-right"};
    f.device.initializedHostTime = 0;  // past the startup grace period
    CHECK(f.device.deviceIsPublished());
    dispatch_sync(f.device.audioOutputQueue, ^{ f.device.updateDisplayPresence(1); });
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    CHECK(f.device.deviceIsPublished());
    std::this_thread::sleep_for(std::chrono::milliseconds(900));
    f.drain();
    CHECK(!f.device.deviceIsPublished());
    AudioObjectPropertyAddress address = {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    UInt32 size = 99;
    CHECK(f.device.GetPropertyDataSize(gAudioServerPlugInDriverRef, kObjectID_PlugIn, 0, &address, 0, nullptr, &size) == noErr);
    CHECK(size == 0);
    CHECK(gHost.sawChange(kAudioPlugInPropertyDeviceList));
    dispatch_sync(f.device.audioOutputQueue, ^{ f.device.updateDisplayPresence(2); });
    f.drain();
    CHECK(f.device.deviceIsPublished());

    // A display coming back within the second cancels the hide.
    dispatch_sync(f.device.audioOutputQueue, ^{ f.device.updateDisplayPresence(1); });
    dispatch_sync(f.device.audioOutputQueue, ^{ f.device.updateDisplayPresence(2); });
    std::this_thread::sleep_for(std::chrono::milliseconds(1300));
    f.drain();
    CHECK(f.device.deviceIsPublished());
}

static void testUnsignedDriverAcceptsDevelopmentWriters() {
    DriverFixture f;
    CHECK(f.device.writerIsAuthorized(getpid()));
    CHECK(f.device.writerVerification == "unsigned driver");
}

// MARK: Concurrency (meaningful under Thread Sanitizer)

static void testRingBufferWithConcurrentWriterReaderAndResize() {
    nearfield::PlaybackEngine engine;
    engine.configure(48000);
    engine.setOutputFormat(48000, 256, 0);
    engine.beginClientSession();
    engine.noteOutputStarting();
    std::atomic<bool> done{false};
    std::atomic<uint64_t> badSamples{0};
    std::atomic<uint64_t> playedFrames{0};

    std::thread writer([&] {
        std::vector<float> chunk(512 * 2, 1.0f);
        double frame = 0;
        for (int cycle = 0; cycle < 3000; ++cycle) {
            // Pace like a real IO thread: never more than about half a ring ahead.
            while (engine.writtenEnd() - engine.readerPosition() > 40000 && !done.load()) {
                std::this_thread::yield();
            }
            engine.write(chunk.data(), 512, frame, mach_absolute_time(), 500.0);
            frame += 512;
        }
        engine.endClientSession();
    });
    std::thread reader([&] {
        std::vector<float> out(256 * 2);
        while (!done.load()) {
            engine.read(out.data(), 256, mach_absolute_time(), 1.0, 1.0f, 1.0f);
            for (float sample : out) {
                if (sample < 0.0f || sample > 1.0f) {
                    badSamples.fetch_add(1);
                }
                if (sample != 0.0f) {
                    playedFrames.fetch_add(1);
                }
            }
            if (engine.isDrained()) {
                break;
            }
            std::this_thread::yield();
        }
    });
    writer.join();
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    while (!engine.isDrained() && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    done.store(true);
    reader.join();
    CHECK(badSamples.load() == 0);
    CHECK(playedFrames.load() > 0);

    // Storage replacement (a sample-rate change) while both threads run.
    nearfield::PlaybackEngine resized;
    resized.configure(48000);
    resized.setOutputFormat(48000, 256, 0);
    resized.beginClientSession();
    std::atomic<bool> stop{false};
    std::thread resizingWriter([&] {
        std::vector<float> chunk(512 * 2, 0.5f);
        double frame = 0;
        while (!stop.load()) {
            resized.write(chunk.data(), 512, frame, mach_absolute_time(), 500.0);
            frame += 512;
            std::this_thread::sleep_for(std::chrono::microseconds(200));
        }
    });
    std::thread resizingReader([&] {
        std::vector<float> out(256 * 2);
        while (!stop.load()) {
            resized.read(out.data(), 256, mach_absolute_time(), 1.0, 1.0f, 1.0f);
            for (float sample : out) {
                if (sample < 0.0f || sample > 0.5f) {
                    badSamples.fetch_add(1);
                }
            }
            std::this_thread::sleep_for(std::chrono::microseconds(100));
        }
    });
    for (int change = 0; change < 20; ++change) {
        resized.configure(change % 2 ? 48000 : 96000);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    stop.store(true);
    resizingWriter.join();
    resizingReader.join();
    CHECK(badSamples.load() == 0);
}

// Driver 1.0 read the device name without the lock that renames held, so a
// rename could release the string while a client was copying it.
static void testDeviceNameReadsDoNotRaceWithRenames() {
    DriverFixture f;
    std::atomic<bool> stop{false};
    std::thread reader([&] {
        AudioObjectPropertyAddress address = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
        while (!stop.load()) {
            CFStringRef name = NULL;
            UInt32 size = 0;
            CHECK(f.device.GetPropertyData(gAudioServerPlugInDriverRef, kObjectID_Device, 0, &address, 0, nullptr,
                                           sizeof(name), &size, &name) == noErr);
            CHECK(name != NULL && CFStringGetLength(name) > 0);
            CFRelease(name);
            std::this_thread::sleep_for(std::chrono::microseconds(50));
        }
    });
    for (int rename = 0; rename < 400; ++rename) {
        nearfield::SettingsUpdate update;
        update.deviceName = rename % 2 ? "Left Desk" : "Right Desk";
        CHECK(f.device.applySettings(update, getpid()) == noErr);
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
    stop.store(true);
    reader.join();
}

// MARK: Simulated clocks

struct SimulationResult {
    uint64_t underruns = 0;
    double minimumBufferedMilliseconds = 1e9;
    double maximumBufferedMilliseconds = 0;
    double finalCorrectionPPM = 0;
};

// Runs the writer on the Nearfield clock (steered by the engine) and the
// reader on an output clock that drifts by |driftPPM|, with scheduling
// jitter, for |seconds| of simulated time.
static SimulationResult simulateClocks(double driftPPM, bool reportDrift, nearfield::UnderrunStrategy strategy,
                                       double seconds, double jitterMilliseconds) {
    nearfield::PlaybackEngine engine;
    engine.configure(kRate);
    engine.setOutputFormat(kRate, kFrames, 0);
    engine.setStrategy(strategy != nearfield::UnderrunStrategy::gap, strategy != nearfield::UnderrunStrategy::steer);
    engine.beginClientSession();
    engine.noteOutputStarting();

    const double ticksPerFrame = 500.0;  // 24 MHz host clock at 48 kHz
    const double outputTicksPerFrame = ticksPerFrame / (1.0 + driftPPM * 1e-6);
    const double reportedRateScalar = reportDrift ? outputTicksPerFrame / ticksPerFrame : 1.0;
    std::mt19937 random(7);
    std::uniform_real_distribution<double> jitter(0.0, jitterMilliseconds * 24000.0);
    std::vector<float> chunk(kFrames * 2, 0.25f);
    std::vector<float> out(kFrames * 2);

    double writerNominal = 0;
    double readerNominal = 30 * ticksPerFrame;
    double writerFrame = 0;
    const double end = seconds * kRate * ticksPerFrame;
    SimulationResult result;
    uint64_t underrunsAtWarmup = 0;
    bool warmedUp = false;
    while (writerNominal < end || readerNominal < end) {
        const double writerAt = writerNominal + jitter(random);
        const double readerAt = readerNominal + jitter(random);
        if (writerAt <= readerAt) {
            engine.write(chunk.data(), kFrames, writerFrame, (uint64_t)writerAt, ticksPerFrame * engine.clockRatio());
            writerFrame += kFrames;
            writerNominal += kFrames * ticksPerFrame * engine.clockRatio();
        } else {
            engine.read(out.data(), kFrames, (uint64_t)readerAt, reportedRateScalar, 1.0f, 1.0f);
            readerNominal += kFrames * outputTicksPerFrame;
            const double simulatedSeconds = readerNominal / (kRate * ticksPerFrame);
            if (!warmedUp && simulatedSeconds > 5) {
                warmedUp = true;
                underrunsAtWarmup = engine.counters().underruns.load();
            }
            if (warmedUp) {
                const double buffered = engine.lastBufferedMilliseconds();
                result.minimumBufferedMilliseconds = std::min(result.minimumBufferedMilliseconds, buffered);
                result.maximumBufferedMilliseconds = std::max(result.maximumBufferedMilliseconds, buffered);
            }
        }
    }
    result.underruns = engine.counters().underruns.load() - underrunsAtWarmup;
    result.finalCorrectionPPM = engine.steeringPPM();
    return result;
}

static void testSimulatedClockDriftAndBufferFill() {
    using Strategy = nearfield::UnderrunStrategy;
    // The output clock's reported rate keeps the clocks together on its own.
    SimulationResult reported = simulateClocks(80, true, Strategy::both, 600, 1.0);
    CHECK(reported.underruns == 0);
    CHECK(reported.maximumBufferedMilliseconds - reported.minimumBufferedMilliseconds < 30);

    // Without a usable rate report, steering by buffer fill absorbs 80 ppm.
    SimulationResult steered = simulateClocks(80, false, Strategy::both, 1800, 1.0);
    CHECK(steered.underruns == 0);
    CHECK(steered.finalCorrectionPPM < -40 && steered.finalCorrectionPPM > -200);
    CHECK(steered.maximumBufferedMilliseconds < 60);

    SimulationResult steeredSlow = simulateClocks(-120, false, Strategy::steer, 1800, 1.0);
    CHECK(steeredSlow.underruns == 0);
    CHECK(steeredSlow.maximumBufferedMilliseconds < 60);

    // A widening safety gap alone cannot follow a clock drift: it keeps
    // underrunning, which is why the clock is steered as well.
    SimulationResult gapOnly = simulateClocks(80, false, Strategy::gap, 600, 1.0);
    CHECK(gapOnly.underruns > 0);

    std::printf("  simulated drift: reported %.1f-%.1f ms, steered %.1f-%.1f ms (%.0f ppm), gap only %llu underruns\n",
                reported.minimumBufferedMilliseconds, reported.maximumBufferedMilliseconds,
                steered.minimumBufferedMilliseconds, steered.maximumBufferedMilliseconds, steered.finalCorrectionPPM,
                gapOnly.underruns);
}

// MARK: Allocation guard

extern "C" {
typedef void(malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2, uintptr_t arg3, uintptr_t result,
                              uint32_t num_hot_frames_to_skip);
extern malloc_logger_t *malloc_logger;
}

namespace {
std::atomic<pthread_t> gGuardedThread{nullptr};
std::atomic<int> gGuardedAllocations{0};

void allocationLogger(uint32_t type, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t) {
    constexpr uint32_t kAllocation = 2;  // MALLOC_LOG_TYPE_ALLOCATE
    if ((type & kAllocation) && gGuardedThread.load(std::memory_order_relaxed) == pthread_self()) {
        gGuardedAllocations.fetch_add(1, std::memory_order_relaxed);
    }
}

int allocationsDuring(const std::function<void()> &work) {
    gGuardedAllocations.store(0);
    gGuardedThread.store(pthread_self());
    work();
    gGuardedThread.store(nullptr);
    return gGuardedAllocations.load();
}
} // namespace

static void testAudioCallbacksDoNotAllocate() {
    malloc_logger = allocationLogger;
    // The guard itself must see allocations, or it proves nothing.
    const int probe = allocationsDuring([] {
        void *volatile allocation = malloc(64);
        free(allocation);
    });
    if (probe == 0) {
        malloc_logger = nullptr;
        std::printf("  allocation guard unavailable in this build; skipped\n");
        return;
    }

    DriverFixture f;
    enableRouting(f, CFSTR("test.app=left"));
    f.addClient(1, 101, CFSTR("test.app"));
    f.device.diagnostics.enabled.store(true);
    f.start(1);
    playUntilSteady(f, 1, 0.5f, 0.0f);  // Warm-up outside the guard.

    Float32 buffer[kFrames * 2];
    const int allocations = allocationsDuring([&] {
        for (int cycle = 0; cycle < 200; ++cycle) {
            std::copy(f.samples, f.samples + kFrames * 2, buffer);
            f.processOutput(1, buffer, f.nextFrame);
            f.writeMix(buffer, f.nextFrame);
            f.nextFrame += kFrames;
            Float64 sampleTime = 0;
            UInt64 hostTime = 0;
            UInt64 seed = 0;
            f.device.GetZeroTimeStamp(gAudioServerPlugInDriverRef, kObjectID_Device, 1, &sampleTime, &hostTime, &seed);
            f.render();
            if (cycle == 100) {
                // Volume changes and route crossfades on the audio threads.
                f.device.gVolume_Output_R_Value = 0.5f;
            }
        }
        // An underrun, its fade and the widened gap.
        for (int cycle = 0; cycle < 4; ++cycle) {
            f.render();
        }
    });
    malloc_logger = nullptr;
    f.drain();
    CHECK(f.device.engine.counters().underruns.load() == 1);
    CHECK(allocations == 0);
}

// MARK: Review regressions

static void testZeroTimeStampsAreConsistentUnderContention() {
    nearfield::DeviceClock clock;
    const uint32_t period = 16384;
    const double ticksPerFrame = 1000;
    const uint64_t anchor = 1000000000;
    // Host time advances by 1/50 of a period per call, so the timeline moves
    // while several threads ask at once.
    const uint64_t step = (uint64_t)(ticksPerFrame * period / 50);
    clock.setHostTicksPerFrame(ticksPerFrame);
    clock.reset(anchor);
    std::atomic<uint64_t> now{anchor};
    std::atomic<long> unset{0};
    std::atomic<long> inconsistent{0};
    std::atomic<long> backwards{0};
    std::vector<std::thread> threads;
    for (int thread = 0; thread < 6; ++thread) {
        threads.emplace_back([&] {
            double lastSampleTime = -1;
            for (int call = 0; call < 100000; ++call) {
                double sampleTime = std::numeric_limits<double>::quiet_NaN();
                uint64_t hostTime = UINT64_MAX;
                clock.get(period, 1.0, now.fetch_add(step, std::memory_order_relaxed), sampleTime, hostTime);
                if (std::isnan(sampleTime) || hostTime == UINT64_MAX || hostTime == 0) {
                    ++unset;
                    continue;
                }
                // Sample time and host time belong to the same stamp.
                if (std::fmod(sampleTime, period) != 0 || (double)hostTime != (double)anchor + sampleTime * ticksPerFrame) {
                    ++inconsistent;
                }
                if (sampleTime < lastSampleTime) {
                    ++backwards;
                }
                lastSampleTime = sampleTime;
            }
        });
    }
    for (std::thread &thread : threads) {
        thread.join();
    }
    CHECK(unset.load() == 0);
    CHECK(inconsistent.load() == 0);
    CHECK(backwards.load() == 0);

    // A reset starts the new timeline at once.
    clock.reset(anchor * 4);
    double sampleTime = -1;
    uint64_t hostTime = 0;
    clock.get(period, 1.0, anchor * 4 + 10, sampleTime, hostTime);
    CHECK(sampleTime == 0);
    CHECK(hostTime == anchor * 4);
}

static void testTeamIdentifierComesFromTheDriverBundle() {
    CHECK(codePathForImage("/Library/Audio/Plug-Ins/HAL/NearfieldAudioDevice.driver/Contents/MacOS/NearfieldAudioDevice") ==
          "/Library/Audio/Plug-Ins/HAL/NearfieldAudioDevice.driver");
    CHECK(codePathForImage("/tmp/driver-tests") == "/tmp/driver-tests");
    // This code was loaded from the test binary, which has no Team ID.
    const std::string ownPath = driverCodePath();
    CHECK(!ownPath.empty());
    CHECK(copyTeamIdentifier(ownPath) == NULL);
    // Neither does the audio service that hosts the driver, which is why the
    // driver's own bundle must be checked rather than the running process.
    CHECK(copyTeamIdentifier("/usr/sbin/coreaudiod") == NULL);

    const std::string bundled = "/Applications/Nearfield.app/Contents/Resources/Drivers/NearfieldAudioDevice.driver";
    if (access(bundled.c_str(), R_OK) != 0) {
        std::printf("  no Developer ID signed Nearfield.app installed; bundle check skipped\n");
        return;
    }
    CFStringRef team = copyTeamIdentifier(bundled);
    CFStringRef teamFromExecutable = copyTeamIdentifier(codePathForImage(bundled + "/Contents/MacOS/NearfieldAudioDevice"));
    CHECK(team != NULL);
    CHECK(teamFromExecutable != NULL && CFEqual(team, teamFromExecutable));
    CFRelease(team);
    CFRelease(teamFromExecutable);
}

static void testMalformedNumbersAreRejected() {
    const auto parses = [](CFDictionaryRef values, nearfield::SettingsUpdate &update) {
        update = nearfield::SettingsUpdate();
        return nearfield::parseSettingsUpdate(values, update);
    };
    const auto rejects = [&](CFStringRef key, CFTypeRef value) {
        CFDictionarySmartRef values(dictionary({{key, value}}));
        nearfield::SettingsUpdate update;
        return !parses(values, update);
    };
    const auto rejectsProcessRoute = [&](CFTypeRef processID) {
        const void *keys[] = {processID};
        const void *routes[] = {CFSTR("left")};
        CFDictionarySmartRef processRoutes(
            CFDictionaryCreate(NULL, keys, routes, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
        return rejects(nearfield::kSettingsProcessRoutesKey, processRoutes);
    };
    const double nan = std::numeric_limits<double>::quiet_NaN();
    const double infinity = std::numeric_limits<double>::infinity();
    CFNumberSmartRef nanNumber(CFNumberCreate(NULL, kCFNumberDoubleType, &nan));
    CFNumberSmartRef infinityNumber(CFNumberCreate(NULL, kCFNumberDoubleType, &infinity));
    const CFTypeRef notFinite[] = {CFSTR("nan"), CFSTR("inf"), CFSTR("-inf"), nanNumber.ref(), infinityNumber.ref()};
    for (CFTypeRef value : notFinite) {
        CHECK(rejects(nearfield::kSettingsOutputBufferFrameSizeKey, value));
        CHECK(rejects(nearfield::kSettingsSafetyGapKey, value));
        CHECK(rejects(nearfield::kSettingsActiveConditionKey, value));
        CHECK(rejectsProcessRoute(value));
    }
    CHECK(rejects(nearfield::kSettingsRoutingEnabledKey, nanNumber.ref()));
    CHECK(rejects(nearfield::kSettingsActiveConditionKey, CFSTR("3")));
    CHECK(rejects(nearfield::kSettingsActiveConditionKey, CFSTR("1.5")));
    CHECK(rejects(nearfield::kSettingsSafetyGapKey, CFSTR("101")));
    for (CFStringRef processID : {CFSTR("0"), CFSTR("-3"), CFSTR("1.5"), CFSTR("1e20"), CFSTR("4294967297")}) {
        CHECK(rejectsProcessRoute(processID));
    }

    // Valid values still parse; frame sizes are clamped as before.
    CFDictionarySmartRef routes(dictionary({{CFSTR("101"), CFSTR("left")}}));
    CFDictionarySmartRef valid(dictionary({
        {nearfield::kSettingsOutputBufferFrameSizeKey, CFSTR("100000")},
        {nearfield::kSettingsActiveConditionKey, CFSTR("2")},
        {nearfield::kSettingsSafetyGapKey, CFSTR("4.5")},
        {nearfield::kSettingsProcessRoutesKey, routes},
    }));
    nearfield::SettingsUpdate update;
    CHECK(parses(valid, update));
    CHECK(update.outputBufferFrameSize && *update.outputBufferFrameSize == nearfield::kMaximumOutputBufferFrameSize);
    CHECK(update.activeCondition && *update.activeCondition == 2);
    CHECK(update.safetyGapMilliseconds && *update.safetyGapMilliseconds == 4.5);
    CHECK(update.processRoutes && update.processRoutes->size() == 1 && update.processRoutes->count(101) == 1);

    // Process rules in the legacy rules string that overflow a pid are ignored, not truncated.
    const nearfield::ParsedRouteRules rules = nearfield::parseRouteRules("pid:4294967338=left; pid:42=right");
    CHECK(rules.processRoutes.size() == 1 && rules.processRoutes.count(42) == 1);

    // Saved settings with impossible sample rates keep the defaults.
    CFNumberSmartRef rate(CFNumberCreate(NULL, kCFNumberDoubleType, &infinity));
    CFArraySmartRef rates(CFArrayCreate(NULL, (const void *[]){nanNumber.ref(), rate.ref()}, 2, &kCFTypeArrayCallBacks));
    CFDictionarySmartRef saved(dictionary({
        {nearfield::kSettingsSampleRateKey, rate},
        {nearfield::kSettingsAvailableSampleRatesKey, rates},
    }));
    nearfield::DriverSettings settings;
    CHECK(nearfield::loadPersistentSettings(saved, settings));
    CHECK(settings.sampleRate == 0);
    CHECK(settings.availableSampleRates.empty());
}

static void testFailedOutputCallbackIsRetried() {
    // A device whose IO callback could not be created is never "set up".
    CHECK(!outputSetupIsCurrent(true, 50, 512, false, 50, 512));
    CHECK(outputSetupIsCurrent(true, 50, 512, true, 50, 512));
    CHECK(!outputSetupIsCurrent(true, 50, 512, true, 51, 512));
    CHECK(!outputSetupIsCurrent(true, 50, 512, true, 50, 256));
    CHECK(!outputSetupIsCurrent(false, 50, 512, true, 50, 512));
    // Retries back off to four seconds and stop after twelve attempts.
    const double delays[] = {0.25, 0.5, 1, 2, 4, 4, 4, 4, 4, 4, 4, 4};
    for (int attempt = 0; attempt < 12; ++attempt) {
        CHECK(outputSetupRetryDelay(attempt) == delays[attempt]);
    }
    CHECK(outputSetupRetryDelay(12) < 0);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const std::string suite = argc > 1 ? argv[1] : "all";
    const std::string filter = argc > 2 ? argv[2] : "";
    struct Test {
        const char *name;
        void (*run)();
        bool concurrency;
        bool allocation;
    };
    const Test tests[] = {
        {"overlapping clients preserve playback", testOverlappingClientsPreservePlayback, false, false},
        {"invalid lifecycle calls", testInvalidLifecycleCallsDoNotChangeAudio, false, false},
        {"routed mix survives client stop", testRoutedMixSurvivesClientStop, false, false},
        {"closing silent Safari client", testClosingSilentSafariClientPreservesPlayingHelper, false, false},
        {"routing toggle affects playing audio", testRoutingToggleAffectsAudioAlreadyPlaying, false, false},
        {"route changes crossfade", testRouteChangesCrossfade, false, false},
        {"render never waits for the state mutex", testRenderDoesNotWaitForConfigurationMutex, true, false},
        {"volume, mute and balance are smoothed", testVolumeMuteAndBalanceAreSmoothed, false, false},
        {"cold start plays from the first sample", testColdStartPlaysFromFirstSampleThenTrimsDuringSilence, false, false},
        {"underrun fades and widens the gap", testUnderrunFadesOutAndWidensTheSafetyGap, false, false},
        {"settings apply in one step", testSettingsApplyInOneStepAndSaveOnlyChanges, false, false},
        {"legacy driver settings migrate", testLegacyDriverSettingsAreMigrated, false, false},
        {"legacy configuration channel", testLegacyConfigurationChannelStillWorks, false, false},
        {"legacy readiness", testLegacyReadinessRequiresCurrentConfigurationAndInitializedOutput, false, false},
        {"status and custom properties", testStatusAndCustomProperties, false, false},
        {"sample rate is remembered", testSampleRateChangeIsRememberedAndResetsTheBuffer, false, false},
        {"displays gone hides Nearfield", testDisplaysGoneHidesNearfieldAfterAboutASecond, false, false},
        {"unsigned driver accepts writers", testUnsignedDriverAcceptsDevelopmentWriters, false, false},
        {"ring buffer with two threads and resizing", testRingBufferWithConcurrentWriterReaderAndResize, true, false},
        {"device name reads and renames", testDeviceNameReadsDoNotRaceWithRenames, true, false},
        {"simulated clock drift and buffer fill", testSimulatedClockDriftAndBufferFill, false, false},
        {"audio callbacks do not allocate", testAudioCallbacksDoNotAllocate, false, true},
        {"zero time stamps under contention", testZeroTimeStampsAreConsistentUnderContention, true, false},
        {"team identifier from the driver bundle", testTeamIdentifierComesFromTheDriverBundle, false, false},
        {"malformed numbers are rejected", testMalformedNumbersAreRejected, false, false},
        {"failed output callback is retried", testFailedOutputCallbackIsRetried, false, false},
    };
    int run = 0;
    for (const Test &test : tests) {
        if (suite == "concurrency" && !test.concurrency) continue;
        if (suite == "sanitized" && test.allocation) continue;
        if (!filter.empty() && std::string(test.name).find(filter) == std::string::npos) continue;
        std::printf("- %s\n", test.name);
        test.run();
        ++run;
    }
    std::printf("%d driver tests passed (%s)\n", run, suite.c_str());
    return 0;
}
