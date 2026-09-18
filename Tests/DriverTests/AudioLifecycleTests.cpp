// Exercise the real driver callbacks without initializing a HAL plug-in or
// selecting, installing, or modifying any system audio device.
#include <cassert>
#include <chrono>
#include <future>
#include <iostream>
#include <thread>
#include "../../Vendor/app-router-audio-device/proxyAudioDevice/ProxyAudioDevice.cpp"

struct DriverFixture {
    ProxyAudioDevice device;
    AudioRingBuffer input{8, 88200};
    Byte work[8192] = {};
    Byte mix[8192] = {};
    Float32 samples[1024];
    Float32 output[1024] = {};

    DriverFixture() {
        device.audioOutputQueue = dispatch_queue_create("nearfield.driver-tests", DISPATCH_QUEUE_SERIAL);
        device.inputBuffer = &input;
        device.workBuffer = work;
        device.routeMixBuffer = mix;
        // The output ID stays unknown, so queued lifecycle work cannot touch HAL.
        device.outputDevice.sampleRate = 44100;
        device.outputDevice.bufferFrameSize = 512;
        std::fill(samples, samples + 1024, 0.5f);
    }

    ~DriverFixture() {
        drain();
        dispatch_release(device.audioOutputQueue);
    }

    void drain() { dispatch_sync(device.audioOutputQueue, ^{}); }
    void start(UInt32 client) {
        assert(device.StartIO(gAudioServerPlugInDriverRef, kObjectID_Device, client) == noErr);
        drain();
    }
    void stop(UInt32 client) {
        assert(device.StopIO(gAudioServerPlugInDriverRef, kObjectID_Device, client) == noErr);
        drain();
    }
    void write(Float64 frame, UInt32 operation = kAudioServerPlugInIOOperationWriteMix, UInt32 client = 1) {
        AudioServerPlugInIOCycleInfo cycle = {};
        cycle.mOutputTime.mSampleTime = frame;
        assert(device.DoIOOperation(gAudioServerPlugInDriverRef, kObjectID_Device, kObjectID_Stream_Output,
                                    client, operation, 512, &cycle, samples, nullptr) == noErr);
    }
    void render(Float64 frame) {
        std::fill(output, output + 1024, 0.0f);
        device.inputOutputSampleDelta = 0;
        AudioBufferList buffers = {1, {{2, sizeof(output), output}}};
        AudioTimeStamp timestamp = {};
        timestamp.mSampleTime = frame;
        timestamp.mRateScalar = 1;
        assert(device.outputDeviceIOProc(0, nullptr, nullptr, nullptr, &buffers, &timestamp) == noErr);
    }
};

static void testOverlappingClientsPreservePlayback() {
    DriverFixture f;
    f.start(1);
    f.write(1000);
    f.device.inputOutputSampleDelta = 100;
    f.start(2);
    assert(f.device.gDevice_IOIsRunning == 2);
    assert(!f.input.mIsEmpty && f.device.lastInputFrameTime == 1000);
    assert(f.device.inputOutputSampleDelta == 100);
    f.stop(2);
    assert(f.device.gDevice_IOIsRunning == 1 && f.device.inputIOIsActive);
    assert(f.device.inputFinalFrameTime == -1);
    f.write(1512);
    f.render(1512);
    for (Float32 sample : f.output) { assert(sample == 0.5f); }
    f.stop(1);
    assert(f.device.gDevice_IOIsRunning == 0 && !f.device.inputIOIsActive);
    assert(f.device.inputFinalFrameTime == 2024);
    f.start(3);
    assert(f.input.mIsEmpty && f.device.inputFinalFrameTime == -1);
    f.write(0);
    f.render(0);
    assert(f.output[0] == 0.5f);
}

static void testInvalidLifecycleCallsDoNotChangeAudio() {
    DriverFixture f;
    f.start(1);
    f.write(1000);
    assert(f.device.StartIO(nullptr, kObjectID_Device, 2) == kAudioHardwareBadObjectError);
    assert(f.device.StopIO(nullptr, kObjectID_Device, 1) == kAudioHardwareBadObjectError);
    assert(f.device.StartIO(gAudioServerPlugInDriverRef, kObjectID_Box, 2) == kAudioHardwareBadObjectError);
    assert(f.device.StopIO(gAudioServerPlugInDriverRef, kObjectID_Box, 1) == kAudioHardwareBadObjectError);
    assert(f.device.gDevice_IOIsRunning == 1 && !f.input.mIsEmpty);
    assert(f.device.inputFinalFrameTime == -1);
    f.stop(1);
    assert(f.device.StopIO(gAudioServerPlugInDriverRef, kObjectID_Device, 1) == kAudioHardwareIllegalOperationError);
    f.drain();
}

static void testRoutedMixSurvivesClientStop() {
    DriverFixture f;
    f.device.routingEnabled = true;
    f.device.clientsByID[1] = {1, 101, "test.left", ProxyAudioDevice::RouteDestination::left};
    f.device.clientsByID[2] = {2, 102, "test.right", ProxyAudioDevice::RouteDestination::right};
    f.device.publishRouteSnapshotNoLock();
    f.start(1);
    f.start(2);
    f.write(0, kAudioServerPlugInIOOperationMixOutput, 1);
    f.write(0, kAudioServerPlugInIOOperationMixOutput, 2);
    f.render(0);
    assert(f.output[0] == 0.5f && f.output[1] == 0.5f);
    f.stop(2);
    f.write(512, kAudioServerPlugInIOOperationMixOutput, 1);
    f.render(512);
    assert(f.output[0] == 0.5f && f.output[1] == 0.0f);
}

static void testRenderDoesNotWaitForConfigurationMutex() {
    DriverFixture f;
    f.start(1);
    f.write(0);
    std::promise<void> rendered;
    auto completion = rendered.get_future();
    f.device.stateMutex.Lock();
    std::thread callback([&] {
        f.render(0);
        rendered.set_value();
    });
    const bool completedWhileLocked = completion.wait_for(std::chrono::seconds(2)) == std::future_status::ready;
    f.device.stateMutex.Unlock();
    callback.join();
    assert(completedWhileLocked);
    assert(f.output[0] == 0.5f);
    f.device.gMute_Output_Mute = true;
    f.render(0);
    assert(f.output[0] == 0.0f);
    f.device.gMute_Output_Mute = false;
    f.device.gVolume_Output_L_Value = 0;
    f.render(0);
    assert(f.output[0] == 0.0f && f.output[1] == 0.5f);
}

static void testClosingSilentSafariClientPreservesPlayingHelper() {
    DriverFixture f;
    f.device.routingEnabled = true;
    f.device.routeRulesString = CFSTR("com.apple.Safari=left; com.apple.WebKit.GPU=left");
    f.device.rebuildRouteRulesNoLock();
    const AudioServerPlugInClientInfo playing = {1, 101, true, CFSTR("com.apple.WebKit.GPU")};
    const AudioServerPlugInClientInfo silentWindow = {2, 102, true, CFSTR("com.apple.Safari")};
    assert(f.device.AddDeviceClient(gAudioServerPlugInDriverRef, kObjectID_Device, &playing) == noErr);
    f.start(1);
    f.write(0, kAudioServerPlugInIOOperationMixOutput, 1);
    assert(f.device.AddDeviceClient(gAudioServerPlugInDriverRef, kObjectID_Device, &silentWindow) == noErr);
    f.start(2);
    f.write(512, kAudioServerPlugInIOOperationMixOutput, 1);
    f.stop(2);
    assert(f.device.RemoveDeviceClient(gAudioServerPlugInDriverRef, kObjectID_Device, &silentWindow) == noErr);
    f.write(1024, kAudioServerPlugInIOOperationMixOutput, 1);
    f.render(1024);
    for (size_t i = 0; i < 1024; i += 2) {
        assert(f.output[i] == 0.5f && f.output[i + 1] == 0.0f);
    }
    assert(f.device.inputFinalFrameTime == -1);
}

int main() {
    testOverlappingClientsPreservePlayback();
    testInvalidLifecycleCallsDoNotChangeAudio();
    testRoutedMixSurvivesClientStop();
    testRenderDoesNotWaitForConfigurationMutex();
    testClosingSilentSafariClientPreservesPlayingHelper();
    std::cout << "5 driver regression tests passed\n";
}
