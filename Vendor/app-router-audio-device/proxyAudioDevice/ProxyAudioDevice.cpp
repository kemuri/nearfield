#include "ProxyAudioDevice.h"

#include <Security/Security.h>
#include <algorithm>
#include <cstdlib>
#include <libproc.h>
#include <string>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>

#include "AudioDevice.h"
#include "CFTypeHelpers.h"
#include "debugHelpers.h"

#pragma mark Utility Functions

std::string CFStringToStdString(CFStringRef s);

std::string CFStringToStdString(CFStringRef s) {
    if (!s) {
        return std::string("<null>");
    }
    const std::string value = nearfield::stringFromCF(s);
    return value.empty() && CFStringGetLength(s) > 0 ? std::string("<invalid>") : value;
}

#pragma mark The Interface

static AudioServerPlugInDriverInterface gAudioServerPlugInDriverInterface = {
    NULL,
    ProxyAudioDevice::ProxyAudio_QueryInterface,
    ProxyAudioDevice::ProxyAudio_AddRef,
    ProxyAudioDevice::ProxyAudio_Release,
    ProxyAudioDevice::ProxyAudio_Initialize,
    ProxyAudioDevice::ProxyAudio_CreateDevice,
    ProxyAudioDevice::ProxyAudio_DestroyDevice,
    ProxyAudioDevice::ProxyAudio_AddDeviceClient,
    ProxyAudioDevice::ProxyAudio_RemoveDeviceClient,
    ProxyAudioDevice::ProxyAudio_PerformDeviceConfigurationChange,
    ProxyAudioDevice::ProxyAudio_AbortDeviceConfigurationChange,
    ProxyAudioDevice::ProxyAudio_HasProperty,
    ProxyAudioDevice::ProxyAudio_IsPropertySettable,
    ProxyAudioDevice::ProxyAudio_GetPropertyDataSize,
    ProxyAudioDevice::ProxyAudio_GetPropertyData,
    ProxyAudioDevice::ProxyAudio_SetPropertyData,
    ProxyAudioDevice::ProxyAudio_StartIO,
    ProxyAudioDevice::ProxyAudio_StopIO,
    ProxyAudioDevice::ProxyAudio_GetZeroTimeStamp,
    ProxyAudioDevice::ProxyAudio_WillDoIOOperation,
    ProxyAudioDevice::ProxyAudio_BeginIOOperation,
    ProxyAudioDevice::ProxyAudio_DoIOOperation,
    ProxyAudioDevice::ProxyAudio_EndIOOperation};
static AudioServerPlugInDriverInterface *gAudioServerPlugInDriverInterfacePtr = &gAudioServerPlugInDriverInterface;
static AudioServerPlugInDriverRef gAudioServerPlugInDriverRef = &gAudioServerPlugInDriverInterfacePtr;

#pragma mark Factory

void *ProxyAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    //    This is the CFPlugIn factory function. Its job is to create the implementation for the given
    //    type provided that the type is supported. Because this driver is simple and all its
    //    initialization is handled via static iniitalization when the bundle is loaded, all that
    //    needs to be done is to return the AudioServerPlugInDriverRef that points to the driver's
    //    interface. A more complicated driver would create any base line objects it needs to satisfy
    //    the IUnknown methods that are used to discover that actual interface to talk to the driver.
    //    The majority of the driver's initilization should be handled in the Initialize() method of
    //    the driver's AudioServerPlugInDriverInterface.

#pragma unused(inAllocator)
    void *theAnswer = NULL;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        theAnswer = gAudioServerPlugInDriverRef;
    }
    return theAnswer;
}

ProxyAudioDevice *ProxyAudioDevice::deviceForDriver(void *inDriver) {
#pragma unused(inDriver)
    static ProxyAudioDevice *mainDevice = nullptr;

    if (!mainDevice) {
        mainDevice = new ProxyAudioDevice;
    }

    return mainDevice;
}

HRESULT ProxyAudioDevice::ProxyAudio_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return E_NOINTERFACE;
    }

    return device->QueryInterface(inDriver, inUUID, outInterface);
}

ULONG ProxyAudioDevice::ProxyAudio_AddRef(void *inDriver) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return 0;
    }

    return device->AddRef(inDriver);
}

ULONG ProxyAudioDevice::ProxyAudio_Release(void *inDriver) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return 0;
    }

    return device->Release(inDriver);
}

OSStatus ProxyAudioDevice::ProxyAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->Initialize(inDriver, inHost);
}

OSStatus ProxyAudioDevice::ProxyAudio_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                                   CFDictionaryRef inDescription,
                                                   const AudioServerPlugInClientInfo *inClientInfo,
                                                   AudioObjectID *outDeviceObjectID) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->CreateDevice(inDriver, inDescription, inClientInfo, outDeviceObjectID);
}

OSStatus ProxyAudioDevice::ProxyAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                                    AudioObjectID inDeviceObjectID) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->DestroyDevice(inDriver, inDeviceObjectID);
}

OSStatus ProxyAudioDevice::ProxyAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                      AudioObjectID inDeviceObjectID,
                                                      const AudioServerPlugInClientInfo *inClientInfo) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->AddDeviceClient(inDriver, inDeviceObjectID, inClientInfo);
}

OSStatus ProxyAudioDevice::ProxyAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                         AudioObjectID inDeviceObjectID,
                                                         const AudioServerPlugInClientInfo *inClientInfo) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->RemoveDeviceClient(inDriver, inDeviceObjectID, inClientInfo);
}

OSStatus ProxyAudioDevice::ProxyAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                       AudioObjectID inDeviceObjectID,
                                                                       UInt64 inChangeAction,
                                                                       void *inChangeInfo) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->PerformDeviceConfigurationChange(inDriver, inDeviceObjectID, inChangeAction, inChangeInfo);
}

OSStatus ProxyAudioDevice::ProxyAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                     AudioObjectID inDeviceObjectID,
                                                                     UInt64 inChangeAction,
                                                                     void *inChangeInfo) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->AbortDeviceConfigurationChange(inDriver, inDeviceObjectID, inChangeAction, inChangeInfo);
}

Boolean ProxyAudioDevice::ProxyAudio_HasProperty(AudioServerPlugInDriverRef inDriver,
                                                 AudioObjectID inObjectID,
                                                 pid_t inClientProcessID,
                                                 const AudioObjectPropertyAddress *inAddress) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return false;
    }

    return device->HasProperty(inDriver, inObjectID, inClientProcessID, inAddress);
}

OSStatus ProxyAudioDevice::ProxyAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                                         AudioObjectID inObjectID,
                                                         pid_t inClientProcessID,
                                                         const AudioObjectPropertyAddress *inAddress,
                                                         Boolean *outIsSettable) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->IsPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
}

OSStatus ProxyAudioDevice::ProxyAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                          AudioObjectID inObjectID,
                                                          pid_t inClientProcessID,
                                                          const AudioObjectPropertyAddress *inAddress,
                                                          UInt32 inQualifierDataSize,
                                                          const void *inQualifierData,
                                                          UInt32 *outDataSize) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->GetPropertyDataSize(
        inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
}

OSStatus ProxyAudioDevice::ProxyAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                                      AudioObjectID inObjectID,
                                                      pid_t inClientProcessID,
                                                      const AudioObjectPropertyAddress *inAddress,
                                                      UInt32 inQualifierDataSize,
                                                      const void *inQualifierData,
                                                      UInt32 inDataSize,
                                                      UInt32 *outDataSize,
                                                      void *outData) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->GetPropertyData(inDriver,
                                   inObjectID,
                                   inClientProcessID,
                                   inAddress,
                                   inQualifierDataSize,
                                   inQualifierData,
                                   inDataSize,
                                   outDataSize,
                                   outData);
}

OSStatus ProxyAudioDevice::ProxyAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                                      AudioObjectID inObjectID,
                                                      pid_t inClientProcessID,
                                                      const AudioObjectPropertyAddress *inAddress,
                                                      UInt32 inQualifierDataSize,
                                                      const void *inQualifierData,
                                                      UInt32 inDataSize,
                                                      const void *inData) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->SetPropertyData(
        inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, inData);
}

OSStatus ProxyAudioDevice::ProxyAudio_StartIO(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inDeviceObjectID,
                                              UInt32 inClientID) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->StartIO(inDriver, inDeviceObjectID, inClientID);
}

OSStatus ProxyAudioDevice::ProxyAudio_StopIO(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inDeviceObjectID,
                                             UInt32 inClientID) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->StopIO(inDriver, inDeviceObjectID, inClientID);
}

OSStatus ProxyAudioDevice::ProxyAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                                       AudioObjectID inDeviceObjectID,
                                                       UInt32 inClientID,
                                                       Float64 *outSampleTime,
                                                       UInt64 *outHostTime,
                                                       UInt64 *outSeed) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->GetZeroTimeStamp(inDriver, inDeviceObjectID, inClientID, outSampleTime, outHostTime, outSeed);
}

OSStatus ProxyAudioDevice::ProxyAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                        AudioObjectID inDeviceObjectID,
                                                        UInt32 inClientID,
                                                        UInt32 inOperationID,
                                                        Boolean *outWillDo,
                                                        Boolean *outWillDoInPlace) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->WillDoIOOperation(
        inDriver, inDeviceObjectID, inClientID, inOperationID, outWillDo, outWillDoInPlace);
}

OSStatus ProxyAudioDevice::ProxyAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                                       AudioObjectID inDeviceObjectID,
                                                       UInt32 inClientID,
                                                       UInt32 inOperationID,
                                                       UInt32 inIOBufferFrameSize,
                                                       const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->BeginIOOperation(
        inDriver, inDeviceObjectID, inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo);
}

OSStatus ProxyAudioDevice::ProxyAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                    AudioObjectID inDeviceObjectID,
                                                    AudioObjectID inStreamObjectID,
                                                    UInt32 inClientID,
                                                    UInt32 inOperationID,
                                                    UInt32 inIOBufferFrameSize,
                                                    const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                                    void *ioMainBuffer,
                                                    void *ioSecondaryBuffer) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->DoIOOperation(inDriver,
                                 inDeviceObjectID,
                                 inStreamObjectID,
                                 inClientID,
                                 inOperationID,
                                 inIOBufferFrameSize,
                                 inIOCycleInfo,
                                 ioMainBuffer,
                                 ioSecondaryBuffer);
}

OSStatus ProxyAudioDevice::ProxyAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID,
                                                     UInt32 inClientID,
                                                     UInt32 inOperationID,
                                                     UInt32 inIOBufferFrameSize,
                                                     const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    ProxyAudioDevice *device = ProxyAudioDevice::deviceForDriver(inDriver);

    if (!device) {
        return kAudioHardwareBadObjectError;
    }

    return device->EndIOOperation(
        inDriver, inDeviceObjectID, inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo);
}

#pragma mark Inheritence

HRESULT ProxyAudioDevice::QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    //    This function is called by the HAL to get the interface to talk to the plug-in through.
    //    AudioServerPlugIns are required to support the IUnknown interface and the
    //    AudioServerPlugInDriverInterface. As it happens, all interfaces must also provide the
    //    IUnknown interface, so we can always just return the single interface we made with
    //    gAudioServerPlugInDriverInterfacePtr regardless of which one is asked for.

    //    declare the local variables
    HRESULT theAnswer = 0;
    CFUUIDRef theRequestedUUID = NULL;

    //    validate the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "ProxyAudio_QueryInterface: bad driver reference");
    FailWithAction(outInterface == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "ProxyAudio_QueryInterface: no place to store the returned interface");

    //    make a CFUUIDRef from inUUID
    theRequestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    FailWithAction(theRequestedUUID == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "ProxyAudio_QueryInterface: failed to create the CFUUIDRef");

    //    AudioServerPlugIns only support two interfaces, IUnknown (which has to be supported by all
    //    CFPlugIns and AudioServerPlugInDriverInterface (which is the actual interface the HAL will
    //    use).
    if (CFEqual(theRequestedUUID, IUnknownUUID) || CFEqual(theRequestedUUID, kAudioServerPlugInDriverInterfaceUUID)) {
        StateLocker locker(stateMutex);
        ++gPlugIn_RefCount;
        *outInterface = gAudioServerPlugInDriverRef;
    } else {
        theAnswer = E_NOINTERFACE;
    }

    //    make sure to release the UUID we created
    CFRelease(theRequestedUUID);

Done:
    return theAnswer;
}

ULONG ProxyAudioDevice::AddRef(void *inDriver) {
    //    This call returns the resulting reference count after the increment.

    //    declare the local variables
    ULONG theAnswer = 0;

    //    check the arguments
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "ProxyAudio_AddRef: bad driver reference");

    //    decrement the refcount
    {
        StateLocker locker(stateMutex);
        if (gPlugIn_RefCount < UINT32_MAX) {
            ++gPlugIn_RefCount;
        }
        theAnswer = gPlugIn_RefCount;
    }
Done:
    return theAnswer;
}

ULONG ProxyAudioDevice::Release(void *inDriver) {
    //    This call returns the resulting reference count after the decrement.

    //    declare the local variables
    ULONG theAnswer = 0;

    //    check the arguments
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "ProxyAudio_Release: bad driver reference");

    //    increment the refcount
    {
        StateLocker locker(stateMutex);
        if (gPlugIn_RefCount > 0) {
            --gPlugIn_RefCount;
            //    Note that we don't do anything special if the refcount goes to zero as the HAL
            //    will never fully release a plug-in it opens. We keep managing the refcount so that
            //    the API semantics are correct though.
        }
        theAnswer = gPlugIn_RefCount;
    }

Done:
    return theAnswer;
}

#pragma mark Basic Operations

static Float64 hostTicksPerSecond() {
    struct mach_timebase_info theTimeBaseInfo;
    mach_timebase_info(&theTimeBaseInfo);
    return ((Float64)theTimeBaseInfo.denom / theTimeBaseInfo.numer) * 1000000000.0;
}

static void engineSignalHandler(void *context, uintptr_t signals) {
    // Called on the audio threads: only merges bits into a dispatch source.
    dispatch_source_t source = static_cast<ProxyAudioDevice *>(context)->engineSignalSource;
    if (source) {
        dispatch_source_merge_data(source, signals);
    }
}

ProxyAudioDevice::ProxyAudioDevice() {
    engine.setSignalHandler(engineSignalHandler, this);
    engine.setDiagnostics(&diagnostics);
}

OSStatus ProxyAudioDevice::Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    //    The job of this method is, as the name implies, to get the driver initialized. One specific
    //    thing that needs to be done is to store the AudioServerPlugInHostRef so that it can be used
    //    later. Note that when this call returns, the HAL will scan the various lists the driver
    //    maintains (such as the device list) to get the inital set of objects the driver is
    //    publishing. So, there is no need to notifiy the HAL about any objects created as part of the
    //    execution of this method.
    DebugMsg("ProxyAudio: ProxyAudio_Initialize");

    if (inDriver != gAudioServerPlugInDriverRef) {
        return kAudioHardwareBadObjectError;
    }

    gPlugIn_Host = inHost;
    initializedHostTime = mach_absolute_time();

    //    initialize the box acquired property from the settings
    CFPropertyListRef theSettingsData = NULL;
    gPlugIn_Host->CopyFromStorage(gPlugIn_Host, CFSTR("box acquired"), &theSettingsData);
    if (theSettingsData != NULL) {
        if (CFGetTypeID(theSettingsData) == CFBooleanGetTypeID()) {
            gBox_Acquired = CFBooleanGetValue((CFBooleanRef)theSettingsData);
        } else if (CFGetTypeID(theSettingsData) == CFNumberGetTypeID()) {
            SInt32 theValue = 0;
            CFNumberGetValue((CFNumberRef)theSettingsData, kCFNumberSInt32Type, &theValue);
            gBox_Acquired = theValue ? 1 : 0;
        }
        CFRelease(theSettingsData);
    }

    //    initialize the box name from the settings
    theSettingsData = NULL;
    gPlugIn_Host->CopyFromStorage(gPlugIn_Host, CFSTR("box name"), &theSettingsData);
    if (theSettingsData != NULL) {
        if (CFGetTypeID(theSettingsData) == CFStringGetTypeID()) {
            boxName = CFStringCreateCopy(NULL, (CFStringRef)theSettingsData);
        }
        CFRelease(theSettingsData);
    }
    if (boxName == NULL) {
        boxName = CFStringCreateCopy(NULL, CFSTR("Nearfield Audio Box"));
    }

    dispatch_queue_attr_t priorityAttribute = dispatch_queue_attr_make_with_qos_class(
        DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, -1
    );
    audioOutputQueue = dispatch_queue_create("com.kemuri.Nearfield.AudioDevice.audioOutputQueue", priorityAttribute);

    // The audio threads report events (latency changes, underruns, drained
    // buffers) by merging bits into this source; the work runs on the queue.
    engineSignalSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_OR, 0, 0, audioOutputQueue);
    dispatch_source_set_event_handler(engineSignalSource, ^{
        handleEngineSignals(dispatch_source_get_data(engineSignalSource));
    });
    dispatch_resume(engineSignalSource);

    loadSettingsFromStorage();
    // Read once, before any client can write settings.
    loadOwnTeamIdentifier();

    Float64 sampleRate = 48000.0;
    {
        StateLocker locker(stateMutex);
        if (settings.sampleRate > 0) {
            sampleRate = settings.sampleRate;
        }
    }
    if (!isSupportedSampleRate(sampleRate)) {
        sampleRate = isSupportedSampleRate(48000.0) ? 48000.0 : currentAvailableSampleRates().front();
    }
    gDevice_SampleRate = sampleRate;
    deviceClock.setHostTicksPerFrame(hostTicksPerSecond() / sampleRate);
    engine.configure(sampleRate);
    {
        StateLocker locker(stateMutex);
        applyPlaybackSettingsNoLock();
    }
    renderBuffer = new Float32[nearfield::kMaxRenderFrames * nearfield::kStreamChannels]();

    syslog(LOG_NOTICE, "NearfieldAudioDevice: initialized at %.0f Hz", sampleRate);
    initializeOutputDevice();
    return 0;
}

void ProxyAudioDevice::loadSettingsFromStorage() {
    StateLocker locker(stateMutex);

    CFPropertyListRef stored = NULL;
    gPlugIn_Host->CopyFromStorage(gPlugIn_Host, CFSTR("settings"), &stored);
    const bool loaded = nearfield::loadPersistentSettings(stored, settings);
    if (stored) {
        if (loaded && CFGetTypeID(stored) == CFDictionaryGetTypeID()) {
            lastPersistedSettings = (CFDictionaryRef)CFRetain(stored);
        }
        CFRelease(stored);
    }

    if (!loaded) {
        // Migrate the individual keys written by driver 1.0.x. They stay in
        // storage so an older driver still finds them after a downgrade.
        auto copyStored = [this](CFStringRef key) -> CFPropertyListRef {
            CFPropertyListRef value = NULL;
            gPlugIn_Host->CopyFromStorage(gPlugIn_Host, key, &value);
            return value;
        };
        CFMutableDictionaryRef legacy =
            CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const std::pair<CFStringRef, CFStringRef> keys[] = {
            {CFSTR("deviceName"), nearfield::kSettingsDeviceNameKey},
            {CFSTR("targetAggregateDevices"), nearfield::kSettingsTargetDevicesKey},
            {CFSTR("targetAggregateMode"), nearfield::kSettingsTargetModeKey},
            {CFSTR("routingEnabled"), nearfield::kSettingsRoutingEnabledKey},
            {CFSTR("routeRules"), nearfield::kSettingsRouteRulesKey},
            {CFSTR("outputDeviceBufferFrameSize"), nearfield::kSettingsOutputBufferFrameSizeKey},
            {CFSTR("outputDeviceUID"), nearfield::kSettingsOutputDeviceKey},
            {CFSTR("outputDeviceActiveCondition"), nearfield::kSettingsActiveConditionKey},
        };
        for (const auto &key : keys) {
            CFPropertyListRef value = copyStored(key.first);
            if (value) {
                CFDictionarySetValue(legacy, key.second, value);
                CFRelease(value);
            }
        }
        nearfield::SettingsUpdate update;
        if (nearfield::parseSettingsUpdate(legacy, update)) {
            std::map<pid_t, nearfield::Route> ignoredProcessRoutes;
            if (update.outputDeviceUID && *update.outputDeviceUID == kDriverTargetAggregate_UID) {
                update.outputDeviceUID.reset();
            }
            nearfield::applySettingsUpdate(settings, ignoredProcessRoutes, update);
        }
        CFRelease(legacy);
        syslog(LOG_NOTICE, "NearfieldAudioDevice: migrated settings from driver 1.0");
    }

    bundleRoutes = nearfield::parseRouteRules(settings.routeRules).bundleRoutes;
    persistSettingsIfChangedNoLock();
}

void ProxyAudioDevice::persistSettingsIfChangedNoLock() {
    if (!gPlugIn_Host) {
        return;
    }
    CFDictionaryRef current = nearfield::createPersistentSettings(settings);
    if (!current) {
        return;
    }
    if (lastPersistedSettings && CFEqual(current, lastPersistedSettings)) {
        CFRelease(current);
        return;
    }
    gPlugIn_Host->WriteToStorage(gPlugIn_Host, CFSTR("settings"), current);
    if (lastPersistedSettings) {
        CFRelease(lastPersistedSettings);
    }
    lastPersistedSettings = current;
}

void ProxyAudioDevice::applyPlaybackSettingsNoLock() {
    const bool steer = settings.underrunStrategy != nearfield::UnderrunStrategy::gap;
    const bool gap = settings.underrunStrategy != nearfield::UnderrunStrategy::steer;
    engine.setStrategy(steer, gap);
    engine.setBaseSafetyGapMilliseconds(settings.safetyGapMilliseconds);
    diagnostics.enabled.store(settings.diagnostics || NEARFIELD_DRIVER_DIAGNOSTICS != 0);
}

OSStatus ProxyAudioDevice::CreateDevice(AudioServerPlugInDriverRef inDriver,
                                        CFDictionaryRef inDescription,
                                        const AudioServerPlugInClientInfo *inClientInfo,
                                        AudioObjectID *outDeviceObjectID) {
    //    This method is used to tell a driver that implements the Transport Manager semantics to
    //    create an AudioEndpointDevice from a set of AudioEndpoints. Since this driver is not a
    //    Transport Manager, we just check the arguments and return
    //    kAudioHardwareUnsupportedOperationError.

#pragma unused(inDescription, inClientInfo, outDeviceObjectID)

    //    declare the local variables
    OSStatus theAnswer = kAudioHardwareUnsupportedOperationError;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "ProxyAudio_CreateDevice: bad driver reference");

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    //    This method is used to tell a driver that implements the Transport Manager semantics to
    //    destroy an AudioEndpointDevice. Since this driver is not a Transport Manager, we just check
    //    the arguments and return kAudioHardwareUnsupportedOperationError.

#pragma unused(inDeviceObjectID)

    //    declare the local variables
    OSStatus theAnswer = kAudioHardwareUnsupportedOperationError;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "ProxyAudio_DestroyDevice: bad driver reference");

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inDeviceObjectID,
                                           const AudioServerPlugInClientInfo *inClientInfo) {
    //    Clients are tracked so App Audio Routing can send each app's audio to
    //    its display.

    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    if (inClientInfo != NULL) {
        StateLocker locker(stateMutex);
        ClientInfo client;
        client.clientID = inClientInfo->mClientID;
        client.processID = inClientInfo->mProcessID;
        if (inClientInfo->mBundleID != NULL) {
            client.bundleID = CFStringToStdString(inClientInfo->mBundleID);
        }
        client.route = routeForClientNoLock(client.bundleID, client.processID);
        clientsByID[client.clientID] = client;
        if (!routeTable.assign(client.clientID, client.route)) {
            syslog(LOG_WARNING, "NearfieldAudioDevice: route table full; client %u keeps its stereo image", client.clientID);
        }
        syslog(LOG_NOTICE,
               "NearfieldAudioDevice: client added id=%u pid=%d bundle=%s route=%s",
               client.clientID,
               client.processID,
               client.bundleID.c_str(),
               nearfield::routeName(client.route));
    }
    return 0;
}

OSStatus ProxyAudioDevice::RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inDeviceObjectID,
                                              const AudioServerPlugInClientInfo *inClientInfo) {
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    if (inClientInfo != NULL) {
        StateLocker locker(stateMutex);
        clientsByID.erase(inClientInfo->mClientID);
        routeTable.release(inClientInfo->mClientID);
        syslog(LOG_NOTICE,
               "NearfieldAudioDevice: client removed id=%u pid=%d",
               inClientInfo->mClientID,
               inClientInfo->mProcessID);
    }
    return 0;
}

nearfield::Route ProxyAudioDevice::routeForClientNoLock(const std::string &bundleID, pid_t processID) const {
    if (!settings.routingEnabled) {
        return nearfield::Route::pair;
    }
    auto processRule = processRoutes.find(processID);
    if (processRule != processRoutes.end()) {
        return processRule->second;
    }
    if (!bundleID.empty()) {
        auto bundleRule = bundleRoutes.find(bundleID);
        if (bundleRule != bundleRoutes.end()) {
            return bundleRule->second;
        }
    }
    return nearfield::Route::pair;
}

void ProxyAudioDevice::updateClientRoutesNoLock() {
    // Takes effect on the next IO cycle, crossfaded by the IO thread.
    for (auto &entry : clientsByID) {
        entry.second.route = routeForClientNoLock(entry.second.bundleID, entry.second.processID);
        routeTable.setRoute(entry.first, entry.second.route);
    }
}

OSStatus ProxyAudioDevice::PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                            AudioObjectID inDeviceObjectID,
                                                            UInt64 inChangeAction,
                                                            void *inChangeInfo) {
    //    The HAL stops IO while this runs. Only sample rate changes use this
    //    path; the new rate is passed in inChangeAction.

#pragma unused(inChangeInfo)

    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    const Float64 sampleRate = (Float64)inChangeAction;
    if (!isSupportedSampleRate(sampleRate)) {
        return kAudioHardwareBadObjectError;
    }

    {
        StateLocker locker(stateMutex);
        gDevice_SampleRate = sampleRate;
        settings.sampleRate = sampleRate;
        persistSettingsIfChangedNoLock();
    }
    deviceClock.setHostTicksPerFrame(hostTicksPerSecond() / sampleRate);
    deviceClock.requestReset();
    // Buffered audio at the previous rate cannot be played at the new one.
    engine.configure(sampleRate);
    diagnostics.record(nearfield::kDiagnosticSampleRate, 0, 0, 0, sampleRate, 0);
    syslog(LOG_NOTICE, "NearfieldAudioDevice: sample rate is now %.0f Hz", sampleRate);

    // Apps choose Nearfield's rate; pass it on to the displays.
    ExecuteInAudioOutputThread(^{
        applyRequestedSampleRateToOutput(sampleRate);
        matchOutputDeviceSampleRate();
        notifyLatencyChanged();
    });
    notifyStatusChanged();
    return 0;
}

OSStatus ProxyAudioDevice::AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                          AudioObjectID inDeviceObjectID,
                                                          UInt64 inChangeAction,
                                                          void *inChangeInfo) {
    //    This method is called to tell the driver that a request for a config change has been denied.
    //    This provides the driver an opportunity to clean up any state associated with the request.
    //    For this driver, an aborted config change requires no action. So we just check the arguments
    //    and return

#pragma unused(inChangeAction, inChangeInfo)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "ProxyAudio_PerformDeviceConfigurationChange: bad driver reference");
    FailWithAction(inDeviceObjectID != kObjectID_Device,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "ProxyAudio_PerformDeviceConfigurationChange: bad device ID");

    syslog(LOG_ERR,
           "NearfieldAudioDevice: the sample rate change to %llu Hz was not performed",
           inChangeAction);

Done:
    return theAnswer;
}

#pragma mark Property Operations

Boolean ProxyAudioDevice::HasProperty(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress) {
    //    This method returns whether or not the given object has the given property.

    //    declare the local variables
    Boolean theAnswer = false;

    //    check the arguments
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "ProxyAudio_HasProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "ProxyAudio_HasProperty: no address");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the ProxyAudio_GetPropertyData() method.
    switch (inObjectID) {
        case kObjectID_PlugIn:
            theAnswer = HasPlugInProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;

        case kObjectID_Box:
            theAnswer = HasBoxProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;

        case kObjectID_Device:
            theAnswer = HasDeviceProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;

        case kObjectID_Stream_Output:
            theAnswer = HasStreamProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;

        case kObjectID_Volume_Output_L:
        case kObjectID_Volume_Output_R:
        case kObjectID_Mute_Output_Master:
            theAnswer = HasControlProperty(inDriver, inObjectID, inClientProcessID, inAddress);
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inObjectID,
                                              pid_t inClientProcessID,
                                              const AudioObjectPropertyAddress *inAddress,
                                              Boolean *outIsSettable) {
    //    This method returns whether or not the given property on the object can have its value
    //    changed.

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "IsPropertySettable: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "IsPropertySettable: no address");
    FailWithAction(outIsSettable == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "IsPropertySettable: no place to put the return value");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetPropertyData() method.
    switch (inObjectID) {
        case kObjectID_PlugIn:
            theAnswer = IsPlugInPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;

        case kObjectID_Box:
            theAnswer = IsBoxPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;

        case kObjectID_Device:
            theAnswer = IsDevicePropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;

        case kObjectID_Stream_Output:
            theAnswer = IsStreamPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;

        case kObjectID_Volume_Output_L:
        case kObjectID_Volume_Output_R:
        case kObjectID_Mute_Output_Master:
            theAnswer = IsControlPropertySettable(inDriver, inObjectID, inClientProcessID, inAddress, outIsSettable);
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t inClientProcessID,
                                               const AudioObjectPropertyAddress *inAddress,
                                               UInt32 inQualifierDataSize,
                                               const void *inQualifierData,
                                               UInt32 *outDataSize) {
    //    This method returns the byte size of the property's data.

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetPropertyDataSize: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "GetPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetPropertyDataSize: no place to put the return value");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetPropertyData() method.
    switch (inObjectID) {
        case kObjectID_PlugIn:
            theAnswer = GetPlugInPropertyDataSize(
                inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;

        case kObjectID_Box:
            theAnswer = GetBoxPropertyDataSize(
                inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;

        case kObjectID_Device:
            theAnswer = GetDevicePropertyDataSize(
                inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;

        case kObjectID_Stream_Output:
            theAnswer = GetStreamPropertyDataSize(
                inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;

        case kObjectID_Volume_Output_L:
        case kObjectID_Volume_Output_R:
        case kObjectID_Mute_Output_Master:
            theAnswer = GetControlPropertyDataSize(
                inDriver, inObjectID, inClientProcessID, inAddress, inQualifierDataSize, inQualifierData, outDataSize);
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void *inQualifierData,
                                           UInt32 inDataSize,
                                           UInt32 *outDataSize,
                                           void *outData) {
    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetPropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "GetPropertyData: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetPropertyData: no place to put the return value");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required.
    //
    //    Also, since most of the data that will get returned is static, there are few instances where
    //    it is necessary to lock the state mutex.
    switch (inObjectID) {
        case kObjectID_PlugIn:
            theAnswer = GetPlugInPropertyData(inDriver,
                                              inObjectID,
                                              inClientProcessID,
                                              inAddress,
                                              inQualifierDataSize,
                                              inQualifierData,
                                              inDataSize,
                                              outDataSize,
                                              outData);
            break;

        case kObjectID_Box:
            theAnswer = GetBoxPropertyData(inDriver,
                                           inObjectID,
                                           inClientProcessID,
                                           inAddress,
                                           inQualifierDataSize,
                                           inQualifierData,
                                           inDataSize,
                                           outDataSize,
                                           outData);
            break;

        case kObjectID_Device:
            theAnswer = GetDevicePropertyData(inDriver,
                                              inObjectID,
                                              inClientProcessID,
                                              inAddress,
                                              inQualifierDataSize,
                                              inQualifierData,
                                              inDataSize,
                                              outDataSize,
                                              outData);
            break;

        case kObjectID_Stream_Output:
            theAnswer = GetStreamPropertyData(inDriver,
                                              inObjectID,
                                              inClientProcessID,
                                              inAddress,
                                              inQualifierDataSize,
                                              inQualifierData,
                                              inDataSize,
                                              outDataSize,
                                              outData);
            break;

        case kObjectID_Volume_Output_L:
        case kObjectID_Volume_Output_R:
        case kObjectID_Mute_Output_Master:
            theAnswer = GetControlPropertyData(inDriver,
                                               inObjectID,
                                               inClientProcessID,
                                               inAddress,
                                               inQualifierDataSize,
                                               inQualifierData,
                                               inDataSize,
                                               outDataSize,
                                               outData);
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientProcessID,
                                           const AudioObjectPropertyAddress *inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void *inQualifierData,
                                           UInt32 inDataSize,
                                           const void *inData) {
    //    declare the local variables
    OSStatus theAnswer = 0;
    UInt32 theNumberPropertiesChanged = 0;
    AudioObjectPropertyAddress theChangedAddresses[2];

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "SetPropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SetPropertyData: no address");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetPropertyData() method.
    switch (inObjectID) {
        case kObjectID_PlugIn:
            theAnswer = SetPlugInPropertyData(inDriver,
                                              inObjectID,
                                              inClientProcessID,
                                              inAddress,
                                              inQualifierDataSize,
                                              inQualifierData,
                                              inDataSize,
                                              inData,
                                              &theNumberPropertiesChanged,
                                              theChangedAddresses);
            break;

        case kObjectID_Box:
            theAnswer = SetBoxPropertyData(inDriver,
                                           inObjectID,
                                           inClientProcessID,
                                           inAddress,
                                           inQualifierDataSize,
                                           inQualifierData,
                                           inDataSize,
                                           inData,
                                           &theNumberPropertiesChanged,
                                           theChangedAddresses);
            break;

        case kObjectID_Device:
            theAnswer = SetDevicePropertyData(inDriver,
                                              inObjectID,
                                              inClientProcessID,
                                              inAddress,
                                              inQualifierDataSize,
                                              inQualifierData,
                                              inDataSize,
                                              inData,
                                              &theNumberPropertiesChanged,
                                              theChangedAddresses);
            break;

        case kObjectID_Stream_Output:
            theAnswer = SetStreamPropertyData(inDriver,
                                              inObjectID,
                                              inClientProcessID,
                                              inAddress,
                                              inQualifierDataSize,
                                              inQualifierData,
                                              inDataSize,
                                              inData,
                                              &theNumberPropertiesChanged,
                                              theChangedAddresses);
            break;

        case kObjectID_Volume_Output_L:
        case kObjectID_Volume_Output_R:
        case kObjectID_Mute_Output_Master:
            theAnswer = SetControlPropertyData(inDriver,
                                               inObjectID,
                                               inClientProcessID,
                                               inAddress,
                                               inQualifierDataSize,
                                               inQualifierData,
                                               inDataSize,
                                               inData,
                                               &theNumberPropertiesChanged,
                                               theChangedAddresses);
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

    //    send any notifications
    if (theNumberPropertiesChanged > 0) {
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, inObjectID, theNumberPropertiesChanged, theChangedAddresses);
    }

Done:
    return theAnswer;
}

#pragma mark PlugIn Property Operations

Boolean ProxyAudioDevice::HasPlugInProperty(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inObjectID,
                                            pid_t inClientProcessID,
                                            const AudioObjectPropertyAddress *inAddress) {
    //    This method returns whether or not the plug-in object has the given property.

#pragma unused(inClientProcessID)

    //    declare the local variables
    Boolean theAnswer = false;

    //    check the arguments
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "HasPlugInProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "HasPlugInProperty: no address");
    FailIf(inObjectID != kObjectID_PlugIn, Done, "HasPlugInProperty: not the plug-in object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetPlugInPropertyData() method.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            theAnswer = true;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver,
                                                    AudioObjectID inObjectID,
                                                    pid_t inClientProcessID,
                                                    const AudioObjectPropertyAddress *inAddress,
                                                    Boolean *outIsSettable) {
    //    This method returns whether or not the given property on the plug-in object can have its
    //    value changed.

#pragma unused(inClientProcessID)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "IsPlugInPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "IsPlugInPropertySettable: no address");
    FailWithAction(outIsSettable == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "IsPlugInPropertySettable: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_PlugIn,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "IsPlugInPropertySettable: not the plug-in object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetPlugInPropertyData() method.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyTranslateUIDToBox:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            *outIsSettable = false;
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inObjectID,
                                                     pid_t inClientProcessID,
                                                     const AudioObjectPropertyAddress *inAddress,
                                                     UInt32 inQualifierDataSize,
                                                     const void *inQualifierData,
                                                     UInt32 *outDataSize) {
    //    This method returns the byte size of the property's data.

#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetPlugInPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetPlugInPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetPlugInPropertyDataSize: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_PlugIn,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetPlugInPropertyDataSize: not the plug-in object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetPlugInPropertyData() method.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = (deviceIsPublished() ? 2 : 1) * sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyBoxList:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyTranslateUIDToBox:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyDeviceList:
            *outDataSize = deviceIsPublished() ? sizeof(AudioObjectID) : 0;
            break;

        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyResourceBundle:
            *outDataSize = sizeof(CFStringRef);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver,
                                                 AudioObjectID inObjectID,
                                                 pid_t inClientProcessID,
                                                 const AudioObjectPropertyAddress *inAddress,
                                                 UInt32 inQualifierDataSize,
                                                 const void *inQualifierData,
                                                 UInt32 inDataSize,
                                                 UInt32 *outDataSize,
                                                 void *outData) {
#pragma unused(inClientProcessID)

    //    declare the local variables
    OSStatus theAnswer = 0;
    UInt32 theNumberItemsToFetch;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetPlugInPropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "GetPlugInPropertyData: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetPlugInPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetPlugInPropertyData: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_PlugIn,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetPlugInPropertyData: not the plug-in object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required.
    //
    //    Also, since most of the data that will get returned is static, there are few instances where
    //    it is necessary to lock the state mutex.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            //    The base class for kAudioPlugInClassID is kAudioObjectClassID
            FailWithAction(inDataSize < sizeof(AudioClassID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetPlugInPropertyData: not enough space for the return value of "
                           "kAudioObjectPropertyBaseClass for the plug-in");
            *((AudioClassID *)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            //    The class is always kAudioPlugInClassID for regular drivers
            FailWithAction(inDataSize < sizeof(AudioClassID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyClass "
                           "for the plug-in");
            *((AudioClassID *)outData) = kAudioPlugInClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            //    The plug-in doesn't have an owning object
            FailWithAction(inDataSize < sizeof(AudioObjectID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetPlugInPropertyData: not enough space for the return value of kAudioObjectPropertyOwner "
                           "for the plug-in");
            *((AudioObjectID *)outData) = kAudioObjectUnknown;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyManufacturer:
            //    This is the human readable name of the maker of the plug-in.
            FailWithAction(inDataSize < sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetPlugInPropertyData: not enough space for the return value of "
                           "kAudioObjectPropertyManufacturer for the plug-in");
            //    Localized by the HAL from the plug-in's Localizable.strings.
            *((CFStringRef *)outData) = CFSTR("ManufacturerName");
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            //    Calculate the number of items that have been requested. Note that this
            //    number is allowed to be smaller than the actual size of the list. In such
            //    case, only that number of items will be returned
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

            //    The box, and the device while it is published
            if (theNumberItemsToFetch > (deviceIsPublished() ? 2 : 1)) {
                theNumberItemsToFetch = (deviceIsPublished() ? 2 : 1);
            }

            //    Write the devices' object IDs into the return value
            if (theNumberItemsToFetch > 1) {
                ((AudioObjectID *)outData)[0] = kObjectID_Box;
                ((AudioObjectID *)outData)[1] = kObjectID_Device;
            } else if (theNumberItemsToFetch > 0) {
                ((AudioObjectID *)outData)[0] = kObjectID_Box;
            }

            //    Return how many bytes we wrote to
            *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyBoxList:
            //    Calculate the number of items that have been requested. Note that this
            //    number is allowed to be smaller than the actual size of the list. In such
            //    case, only that number of items will be returned
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

            //    Clamp that to the number of boxes this driver implements (which is just 1)
            if (theNumberItemsToFetch > 1) {
                theNumberItemsToFetch = 1;
            }

            //    Write the devices' object IDs into the return value
            if (theNumberItemsToFetch > 0) {
                ((AudioObjectID *)outData)[0] = kObjectID_Box;
            }

            //    Return how many bytes we wrote to
            *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyTranslateUIDToBox:
            //    This property takes the CFString passed in the qualifier and converts that
            //    to the object ID of the box it corresponds to. For this driver, there is
            //    just the one box. Note that it is not an error if the string in the
            //    qualifier doesn't match any devices. In such case, kAudioObjectUnknown is
            //    the object ID to return.
            FailWithAction(inDataSize < sizeof(AudioObjectID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetPlugInPropertyData: not enough space for the return value of "
                           "kAudioPlugInPropertyTranslateUIDToBox");
            FailWithAction(
                inQualifierDataSize != sizeof(CFStringRef),
                theAnswer = kAudioHardwareBadPropertySizeError,
                Done,
                "GetPlugInPropertyData: the qualifier is the wrong size for kAudioPlugInPropertyTranslateUIDToBox");
            FailWithAction(inQualifierData == NULL,
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetPlugInPropertyData: no qualifier for kAudioPlugInPropertyTranslateUIDToBox");
            
            if (CFStringCompare(*((CFStringRef *)inQualifierData), CFSTR(kBox_UID), 0) == kCFCompareEqualTo) {
                *((AudioObjectID *)outData) = kObjectID_Box;
            } else {
                *((AudioObjectID *)outData) = kAudioObjectUnknown;
            }
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyDeviceList:
            //    Calculate the number of items that have been requested. Note that this
            //    number is allowed to be smaller than the actual size of the list. In such
            //    case, only that number of items will be returned
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

            //    The device is listed while it is published and the displays are present
            if (theNumberItemsToFetch > (deviceIsPublished() ? 1 : 0)) {
                theNumberItemsToFetch = (deviceIsPublished() ? 1 : 0);
            }

            //    Write the devices' object IDs into the return value
            if (theNumberItemsToFetch > 0) {
                ((AudioObjectID *)outData)[0] = kObjectID_Device;
            }

            //    Return how many bytes we wrote to
            *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyTranslateUIDToDevice:
            //    This property takes the CFString passed in the qualifier and converts that
            //    to the object ID of the device it corresponds to. For this driver, there is
            //    just the one device. Note that it is not an error if the string in the
            //    qualifier doesn't match any devices. In such case, kAudioObjectUnknown is
            //    the object ID to return.
            FailWithAction(inDataSize < sizeof(AudioObjectID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetPlugInPropertyData: not enough space for the return value of "
                           "kAudioPlugInPropertyTranslateUIDToDevice");
            FailWithAction(
                inQualifierDataSize != sizeof(CFStringRef),
                theAnswer = kAudioHardwareBadPropertySizeError,
                Done,
                "GetPlugInPropertyData: the qualifier is the wrong size for kAudioPlugInPropertyTranslateUIDToDevice");
            FailWithAction(inQualifierData == NULL,
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetPlugInPropertyData: no qualifier for kAudioPlugInPropertyTranslateUIDToDevice");
            
            if (CFStringCompare(*((CFStringRef *)inQualifierData), CFSTR(kDevice_UID), 0) == kCFCompareEqualTo) {
                *((AudioObjectID *)outData) = kObjectID_Device;
            } else {
                *((AudioObjectID *)outData) = kAudioObjectUnknown;
            }
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioPlugInPropertyResourceBundle:
            //    The resource bundle is a path relative to the path of the plug-in's bundle.
            //    To specify that the plug-in bundle itself should be used, we just return the
            //    empty string.
            FailWithAction(
                inDataSize < sizeof(AudioObjectID),
                theAnswer = kAudioHardwareBadPropertySizeError,
                Done,
                "GetPlugInPropertyData: not enough space for the return value of kAudioPlugInPropertyResourceBundle");
            *((CFStringRef *)outData) = CFSTR("");
            *outDataSize = sizeof(CFStringRef);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver,
                                                 AudioObjectID inObjectID,
                                                 pid_t inClientProcessID,
                                                 const AudioObjectPropertyAddress *inAddress,
                                                 UInt32 inQualifierDataSize,
                                                 const void *inQualifierData,
                                                 UInt32 inDataSize,
                                                 const void *inData,
                                                 UInt32 *outNumberPropertiesChanged,
                                                 AudioObjectPropertyAddress outChangedAddresses[2]) {
#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData, inDataSize, inData)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "SetPlugInPropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SetPlugInPropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "SetPlugInPropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "SetPlugInPropertyData: no place to return the properties that changed");
    FailWithAction(inObjectID != kObjectID_PlugIn,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "SetPlugInPropertyData: not the plug-in object");

    //    initialize the returned number of changed properties
    *outNumberPropertiesChanged = 0;

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetPlugInPropertyData() method.
    switch (inAddress->mSelector) {
        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

#pragma mark Box Property Operations

static const AudioServerPlugInCustomPropertyInfo kBoxCustomProperties[] = {
    {kNearfieldPropertySettings, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
     kAudioServerPlugInCustomPropertyDataTypeNone},
    {kNearfieldPropertyStatus, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
     kAudioServerPlugInCustomPropertyDataTypeNone},
};

Boolean ProxyAudioDevice::HasBoxProperty(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inObjectID,
                                         pid_t inClientProcessID,
                                         const AudioObjectPropertyAddress *inAddress) {
    //    This method returns whether or not the box object has the given property.

#pragma unused(inClientProcessID)

    //    declare the local variables
    Boolean theAnswer = false;

    //    check the arguments
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "HasBoxProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "HasBoxProperty: no address");
    FailIf(inObjectID != kObjectID_Box, Done, "HasBoxProperty: not the box object");

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyIdentify:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyAcquisitionFailed:
        case kAudioBoxPropertyDeviceList:
        case kNearfieldPropertySettings:
        case kNearfieldPropertyStatus:
            theAnswer = true;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver,
                                                 AudioObjectID inObjectID,
                                                 pid_t inClientProcessID,
                                                 const AudioObjectPropertyAddress *inAddress,
                                                 Boolean *outIsSettable) {
#pragma unused(inClientProcessID)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "IsBoxPropertySettable: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "IsBoxPropertySettable: no address");
    FailWithAction(outIsSettable == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "IsBoxPropertySettable: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Box,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "IsBoxPropertySettable: not the plug-in object");

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioBoxPropertyBoxUID:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquisitionFailed:
        case kAudioBoxPropertyDeviceList:
        case kNearfieldPropertyStatus:
            *outIsSettable = false;
            break;

        case kAudioObjectPropertyName:
        case kAudioObjectPropertyIdentify:
        case kAudioBoxPropertyAcquired:
        case kNearfieldPropertySettings:
            *outIsSettable = true;
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                  AudioObjectID inObjectID,
                                                  pid_t inClientProcessID,
                                                  const AudioObjectPropertyAddress *inAddress,
                                                  UInt32 inQualifierDataSize,
                                                  const void *inQualifierData,
                                                  UInt32 *outDataSize) {
#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetBoxPropertyDataSize: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "GetBoxPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetBoxPropertyDataSize: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Box,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetBoxPropertyDataSize: not the plug-in object");

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyName:
        case kAudioObjectPropertyModelName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertySerialNumber:
        case kAudioObjectPropertyFirmwareVersion:
        case kAudioBoxPropertyBoxUID:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            break;

        case kAudioObjectPropertyCustomPropertyInfoList:
            *outDataSize = sizeof(kBoxCustomProperties);
            break;

        case kAudioObjectPropertyIdentify:
        case kAudioBoxPropertyTransportType:
        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquired:
        case kAudioBoxPropertyAcquisitionFailed:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyDeviceList:
            *outDataSize = deviceIsPublished() ? sizeof(AudioObjectID) : 0;
            break;

        case kNearfieldPropertySettings:
        case kNearfieldPropertyStatus:
            *outDataSize = sizeof(CFPropertyListRef);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetBoxPropertyData(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inObjectID,
                                              pid_t inClientProcessID,
                                              const AudioObjectPropertyAddress *inAddress,
                                              UInt32 inQualifierDataSize,
                                              const void *inQualifierData,
                                              UInt32 inDataSize,
                                              UInt32 *outDataSize,
                                              void *outData) {
#pragma unused(inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetBoxPropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "GetBoxPropertyData: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetBoxPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetBoxPropertyData: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Box,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetBoxPropertyData: not the plug-in object");

    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            FailWithAction(inDataSize < sizeof(AudioClassID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioObjectPropertyBaseClass");
            *((AudioClassID *)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            FailWithAction(inDataSize < sizeof(AudioClassID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioObjectPropertyClass");
            *((AudioClassID *)outData) = kAudioBoxClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            FailWithAction(inDataSize < sizeof(AudioObjectID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioObjectPropertyOwner");
            *((AudioObjectID *)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyName:
            FailWithAction(inDataSize < sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioObjectPropertyName");
            {
                // Legacy configuration channel: the registered configurator
                // reads the requested setting through the box name.
                const int pendingRead = nextConfigurationToRead.load();
                bool isConfiguratorRead = false;
                {
                    StateLocker locker(stateMutex);
                    isConfiguratorRead = inClientProcessID == configuratorPid && configuratorPid != 0;
                }
                if (isConfiguratorRead && pendingRead != (int)ConfigType::none) {
                    *((CFStringRef *)outData) = copyConfigurationValue((ConfigType)pendingRead);
                } else {
                    StateLocker locker(stateMutex);
                    *((CFStringRef *)outData) =
                        boxName ? CFStringCreateCopy(NULL, boxName) : CFSTR("Nearfield Audio Box");
                }
            }
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyModelName:
            FailWithAction(inDataSize < sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioObjectPropertyModelName");
            *((CFStringRef *)outData) = CFSTR("Nearfield");
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyManufacturer:
            //    Localized by the HAL from the plug-in's Localizable.strings.
            FailWithAction(inDataSize < sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioObjectPropertyManufacturer");
            *((CFStringRef *)outData) = CFSTR("ManufacturerName");
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            //    Boxes don't own anything.
            *outDataSize = 0;
            break;

        case kAudioObjectPropertyIdentify:
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioObjectPropertyIdentify");
            *((UInt32 *)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioObjectPropertySerialNumber:
            FailWithAction(inDataSize < sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioObjectPropertySerialNumber");
            *((CFStringRef *)outData) = CFSTR("00000001");
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyFirmwareVersion:
            FailWithAction(inDataSize < sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioObjectPropertyFirmwareVersion");
            *((CFStringRef *)outData) = CFSTR("1.0");
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyCustomPropertyInfoList: {
            const UInt32 count = std::min<UInt32>(inDataSize / sizeof(AudioServerPlugInCustomPropertyInfo),
                                                  sizeof(kBoxCustomProperties) / sizeof(kBoxCustomProperties[0]));
            memcpy(outData, kBoxCustomProperties, count * sizeof(AudioServerPlugInCustomPropertyInfo));
            *outDataSize = count * sizeof(AudioServerPlugInCustomPropertyInfo);
        } break;

        case kAudioBoxPropertyBoxUID:
            FailWithAction(inDataSize < sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioBoxPropertyBoxUID");
            *((CFStringRef *)outData) = CFSTR(kBox_UID);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioBoxPropertyTransportType:
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioBoxPropertyTransportType");
            *((UInt32 *)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyHasAudio:
        case kAudioBoxPropertyHasVideo:
        case kAudioBoxPropertyHasMIDI:
        case kAudioBoxPropertyIsProtected:
        case kAudioBoxPropertyAcquisitionFailed:
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for a box flag");
            *((UInt32 *)outData) = inAddress->mSelector == kAudioBoxPropertyHasAudio ? 1 : 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyAcquired:
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for kAudioBoxPropertyAcquired");
            {
                StateLocker locker(stateMutex);
                *((UInt32 *)outData) = gBox_Acquired ? 1 : 0;
            }
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioBoxPropertyDeviceList:
            //    The device is listed while Nearfield publishes it and the
            //    displays are present.
            if (deviceIsPublished()) {
                FailWithAction(inDataSize < sizeof(AudioObjectID),
                               theAnswer = kAudioHardwareBadPropertySizeError,
                               Done,
                               "GetBoxPropertyData: not enough space for kAudioBoxPropertyDeviceList");
                *((AudioObjectID *)outData) = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
            } else {
                *outDataSize = 0;
            }
            break;

        case kNearfieldPropertySettings:
            FailWithAction(inDataSize < sizeof(CFPropertyListRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for the settings");
            {
                StateLocker locker(stateMutex);
                *((CFPropertyListRef *)outData) = nearfield::createPersistentSettings(settings);
            }
            *outDataSize = sizeof(CFPropertyListRef);
            break;

        case kNearfieldPropertyStatus:
            FailWithAction(inDataSize < sizeof(CFPropertyListRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetBoxPropertyData: not enough space for the status");
            *((CFPropertyListRef *)outData) = copyStatusDictionary();
            *outDataSize = sizeof(CFPropertyListRef);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::SetBoxPropertyData(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inObjectID,
                                              pid_t inClientProcessID,
                                              const AudioObjectPropertyAddress *inAddress,
                                              UInt32 inQualifierDataSize,
                                              const void *inQualifierData,
                                              UInt32 inDataSize,
                                              const void *inData,
                                              UInt32 *outNumberPropertiesChanged,
                                              AudioObjectPropertyAddress outChangedAddresses[2]) {
#pragma unused(inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "SetBoxPropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SetBoxPropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "SetBoxPropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "SetBoxPropertyData: no place to return the properties that changed");
    FailWithAction(inObjectID != kObjectID_Box,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "SetBoxPropertyData: not the box object");

    //    initialize the returned number of changed properties
    *outNumberPropertiesChanged = 0;

    switch (inAddress->mSelector) {
        case kNearfieldPropertySettings: {
            FailWithAction(inDataSize != sizeof(CFPropertyListRef) || inData == NULL,
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "SetBoxPropertyData: wrong size for the settings");
            CFPropertyListRef propertyList = *((const CFPropertyListRef *)inData);
            nearfield::SettingsUpdate update;
            if (!propertyList || CFGetTypeID(propertyList) != CFDictionaryGetTypeID() ||
                !nearfield::parseSettingsUpdate((CFDictionaryRef)propertyList, update)) {
                theAnswer = kAudioHardwareIllegalOperationError;
                break;
            }
            theAnswer = applySettings(update, inClientProcessID);
        } break;

        case kAudioObjectPropertyName: {
            FailWithAction(inDataSize != sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "SetBoxPropertyData: wrong size for the data for kAudioObjectPropertyName");
            CFStringRef *newValue = (CFStringRef *)inData;
            FailWithAction((newValue == NULL || *newValue == NULL || CFGetTypeID(*newValue) != CFStringGetTypeID()),
                           theAnswer = kAudioHardwareIllegalOperationError,
                           Done,
                           "SetBoxPropertyData: bad value for kAudioObjectPropertyName");

            bool isConfigurator = false;
            {
                StateLocker locker(stateMutex);
                isConfigurator = configuratorPid != 0 && inClientProcessID == configuratorPid;
            }
            if (isConfigurator) {
                // Legacy configuration channel: "setting=value" written as the
                // box name by the registered configurator.
                CFStringSmartRef value;
                ConfigType action = ConfigType::none;
                parseConfigurationString(*newValue, action, value.item);
                if (action != ConfigType::none && value) {
                    setConfigurationValue(action, value, inClientProcessID);
                }
            } else {
                StateLocker locker(stateMutex);
                if (boxName != NULL) {
                    CFRelease(boxName);
                }
                boxName = CFStringCreateCopy(NULL, *newValue);
                gPlugIn_Host->WriteToStorage(gPlugIn_Host, CFSTR("box name"), boxName);
                *outNumberPropertiesChanged = 1;
                outChangedAddresses[0].mSelector = kAudioObjectPropertyName;
                outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
            }
        } break;

        case kAudioObjectPropertyIdentify:
            FailWithAction(inDataSize != sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "SetBoxPropertyData: wrong size for the data for kAudioObjectPropertyIdentify");
            {
                // Legacy configuration channel, kept for one release: a
                // process writes its own pid to register as the configurator,
                // then a negative ConfigType to choose what the box name
                // returns on its next read.
                const SInt32 signedValue = *((const SInt32 *)inData);
                if (signedValue < 0) {
                    bool isConfigurator = false;
                    {
                        StateLocker locker(stateMutex);
                        isConfigurator = configuratorPid != 0 && inClientProcessID == configuratorPid;
                    }
                    if (isConfigurator) {
                        nextConfigurationToRead.store(-signedValue);
                    }
                } else if (signedValue > 1 && signedValue == inClientProcessID && writerIsAuthorized(inClientProcessID)) {
                    StateLocker locker(stateMutex);
                    configuratorPid = signedValue;
                }
            }
            theAnswer = noErr;
            break;

        case kAudioBoxPropertyAcquired:
            //    When the box is acquired, the device is published to the system.
            {
                FailWithAction(inDataSize != sizeof(UInt32),
                               theAnswer = kAudioHardwareBadPropertySizeError,
                               Done,
                               "SetBoxPropertyData: wrong size for the data for kAudioBoxPropertyAcquired");
                bool changed = false;
                {
                    StateLocker locker(stateMutex);
                    const bool acquired = *((const UInt32 *)inData) != 0;
                    if (gBox_Acquired != acquired) {
                        gBox_Acquired = acquired;
                        gPlugIn_Host->WriteToStorage(
                            gPlugIn_Host, CFSTR("box acquired"), gBox_Acquired ? kCFBooleanTrue : kCFBooleanFalse);
                        changed = true;
                    }
                }
                if (changed) {
                    *outNumberPropertiesChanged = 1;
                    outChangedAddresses[0].mSelector = kAudioBoxPropertyAcquired;
                    outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                    outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                    notifyDeviceListChanged();
                    notifyStatusChanged();
                }
            }
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

#pragma mark Device Property Operations

Boolean ProxyAudioDevice::HasDeviceProperty(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inObjectID,
                                            pid_t inClientProcessID,
                                            const AudioObjectPropertyAddress *inAddress) {
    //    This method returns whether or not the given object has the given property.

#pragma unused(inClientProcessID)

    //    declare the local variables
    Boolean theAnswer = false;

    //    check the arguments
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "HasDeviceProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "HasDeviceProperty: no address");
    FailIf(inObjectID != kObjectID_Device, Done, "HasDeviceProperty: not the device object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetDevicePropertyData() method.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyIcon:
        case kAudioDevicePropertyStreams:
            theAnswer = true;
            break;

        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            theAnswer = (inAddress->mScope == kAudioObjectPropertyScopeInput)
                        || (inAddress->mScope == kAudioObjectPropertyScopeOutput);
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver,
                                                    AudioObjectID inObjectID,
                                                    pid_t inClientProcessID,
                                                    const AudioObjectPropertyAddress *inAddress,
                                                    Boolean *outIsSettable) {
    //    This method returns whether or not the given property on the object can have its value
    //    changed.

#pragma unused(inClientProcessID)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "IsDevicePropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "IsDevicePropertySettable: no address");
    FailWithAction(outIsSettable == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "IsDevicePropertySettable: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Device,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "IsDevicePropertySettable: not the device object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetDevicePropertyData() method.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyIcon:
            *outIsSettable = false;
            break;

        case kAudioDevicePropertyNominalSampleRate:
            *outIsSettable = true;
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inObjectID,
                                                     pid_t inClientProcessID,
                                                     const AudioObjectPropertyAddress *inAddress,
                                                     UInt32 inQualifierDataSize,
                                                     const void *inQualifierData,
                                                     UInt32 *outDataSize) {
    //    This method returns the byte size of the property's data.

#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetDevicePropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetDevicePropertyDataSize: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetDevicePropertyDataSize: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Device,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetDevicePropertyDataSize: not the device object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetDevicePropertyData() method.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            switch (inAddress->mScope) {
                case kAudioObjectPropertyScopeGlobal:
                    *outDataSize = 4 * sizeof(AudioObjectID);
                    break;

                case kAudioObjectPropertyScopeInput:
                    *outDataSize = 0;
                    break;

                case kAudioObjectPropertyScopeOutput:
                    *outDataSize = 4 * sizeof(AudioObjectID);
                    break;
            };
            break;

        case kAudioDevicePropertyDeviceUID:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyTransportType:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioDevicePropertyClockDomain:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceIsAlive:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioDevicePropertyDeviceIsRunning:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyLatency:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyStreams:
            switch (inAddress->mScope) {
                case kAudioObjectPropertyScopeGlobal:
                    *outDataSize = sizeof(AudioObjectID);
                    break;

                case kAudioObjectPropertyScopeInput:
                    *outDataSize = 0;
                    break;

                case kAudioObjectPropertyScopeOutput:
                    *outDataSize = sizeof(AudioObjectID);
                    break;
            };
            break;

        case kAudioObjectPropertyControlList:
            *outDataSize = 3 * sizeof(AudioObjectID);
            break;

        case kAudioDevicePropertySafetyOffset:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            break;

        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = (UInt32)currentAvailableSampleRates().size() * sizeof(AudioValueRange);
            break;

        case kAudioDevicePropertyIsHidden:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyPreferredChannelsForStereo:
            *outDataSize = 2 * sizeof(UInt32);
            break;

        case kAudioDevicePropertyPreferredChannelLayout:
            *outDataSize = offsetof(AudioChannelLayout, mChannelDescriptions)
                           + (gDevice_ChannelsPerFrame * sizeof(AudioChannelDescription));
            break;

        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyIcon:
            *outDataSize = sizeof(CFURLRef);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetDevicePropertyData(AudioServerPlugInDriverRef inDriver,
                                                 AudioObjectID inObjectID,
                                                 pid_t inClientProcessID,
                                                 const AudioObjectPropertyAddress *inAddress,
                                                 UInt32 inQualifierDataSize,
                                                 const void *inQualifierData,
                                                 UInt32 inDataSize,
                                                 UInt32 *outDataSize,
                                                 void *outData) {
#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;
    UInt32 theNumberItemsToFetch;
    UInt32 theItemIndex;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetDevicePropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "GetDevicePropertyData: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetDevicePropertyData: no place to put the return value size");
    FailWithAction(outData == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetDevicePropertyData: no place to put the return value");
    FailWithAction(inObjectID != kObjectID_Device,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetDevicePropertyData: not the device object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required.
    //
    //    Also, since most of the data that will get returned is static, there are few instances where
    //    it is necessary to lock the state mutex.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            //    The base class for kAudioDeviceClassID is kAudioObjectClassID
            FailWithAction(inDataSize < sizeof(AudioClassID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioObjectPropertyBaseClass for the device");
            *((AudioClassID *)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            //    The class is always kAudioDeviceClassID for devices created by drivers
            FailWithAction(inDataSize < sizeof(AudioClassID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyClass "
                           "for the device");
            *((AudioClassID *)outData) = kAudioDeviceClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            //    The device's owner is the plug-in object
            FailWithAction(inDataSize < sizeof(AudioObjectID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of kAudioObjectPropertyOwner "
                           "for the device");
            *((AudioObjectID *)outData) = kObjectID_PlugIn;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyName:
            //    This is the human readable name of the device.
            FailWithAction(inDataSize < sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioObjectPropertyManufacturer for the device");
            *((CFStringRef *)outData) = copyDeviceName();
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyManufacturer:
            //    This is the human readable name of the maker of the plug-in.
            FailWithAction(inDataSize < sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioObjectPropertyManufacturer for the device");
            *((CFStringRef *)outData) = CFSTR("ManufacturerName");
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioObjectPropertyOwnedObjects:
            //    Calculate the number of items that have been requested. Note that this
            //    number is allowed to be smaller than the actual size of the list. In such
            //    case, only that number of items will be returned
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

            //    The device owns its streams and controls. Note that what is returned here
            //    depends on the scope requested.
            switch (inAddress->mScope) {
                case kAudioObjectPropertyScopeGlobal:
                    //    global scope means return all objects
                    if (theNumberItemsToFetch > 4) {
                        theNumberItemsToFetch = 4;
                    }

                    //    fill out the list with as many objects as requested, which is everything
                    for (theItemIndex = 0; theItemIndex < theNumberItemsToFetch; ++theItemIndex) {
                        ((AudioObjectID *)outData)[theItemIndex] = kObjectID_Stream_Output + theItemIndex;
                    }
                    break;

                case kAudioObjectPropertyScopeInput:
                    theNumberItemsToFetch = 0;
                    break;

                case kAudioObjectPropertyScopeOutput:
                    //    output scope means just the objects on the output side
                    if (theNumberItemsToFetch > 4) {
                        theNumberItemsToFetch = 4;
                    }

                    //    fill out the list with the right objects
                    for (theItemIndex = 0; theItemIndex < theNumberItemsToFetch; ++theItemIndex) {
                        ((AudioObjectID *)outData)[theItemIndex] = kObjectID_Stream_Output + theItemIndex;
                    }
                    break;
            };

            //    report how much we wrote
            *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
            break;

        case kAudioDevicePropertyDeviceUID:
            //    This is a CFString that is a persistent token that can identify the same
            //    audio device across boot sessions. Note that two instances of the same
            //    device must have different values for this property.
            FailWithAction(inDataSize < sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyDeviceUID for the device");
            *((CFStringRef *)outData) = CFSTR(kDevice_UID);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyModelUID:
            //    This is a CFString that is a persistent token that can identify audio
            //    devices that are the same kind of device. Note that two instances of the
            //    save device must have the same value for this property.
            FailWithAction(inDataSize < sizeof(CFStringRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyModelUID for the device");
            *((CFStringRef *)outData) = CFSTR(kDevice_ModelUID);
            *outDataSize = sizeof(CFStringRef);
            break;

        case kAudioDevicePropertyTransportType:
            //    This value represents how the device is attached to the system. This can be
            //    any 32 bit integer, but common values for this property are defined in
            //    <CoreAudio/AudioHardwareBase.h>
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyTransportType for the device");
            *((UInt32 *)outData) = kAudioDeviceTransportTypeVirtual;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyRelatedDevices:
            //    The related devices property identifys device objects that are very closely
            //    related. Generally, this is for relating devices that are packaged together
            //    in the hardware such as when the input side and the output side of a piece
            //    of hardware can be clocked separately and therefore need to be represented
            //    as separate AudioDevice objects. In such case, both devices would report
            //    that they are related to each other. Note that at minimum, a device is
            //    related to itself, so this list will always be at least one item long.

            //    Calculate the number of items that have been requested. Note that this
            //    number is allowed to be smaller than the actual size of the list. In such
            //    case, only that number of items will be returned
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

            //    we only have the one device...
            if (theNumberItemsToFetch > 1) {
                theNumberItemsToFetch = 1;
            }

            //    Write the devices' object IDs into the return value
            if (theNumberItemsToFetch > 0) {
                ((AudioObjectID *)outData)[0] = kObjectID_Device;
            }

            //    report how much we wrote
            *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
            break;

        case kAudioDevicePropertyClockDomain:
            //    This property allows the device to declare what other devices it is
            //    synchronized with in hardware. The way it works is that if two devices have
            //    the same value for this property and the value is not zero, then the two
            //    devices are synchronized in hardware. Note that a device that either can't
            //    be synchronized with others or doesn't know should return 0 for this
            //    property.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyClockDomain for the device");
            *((UInt32 *)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceIsAlive:
            //    This property returns whether or not the device is alive. Note that it is
            //    note uncommon for a device to be dead but still momentarily availble in the
            //    device list. In the case of this device, it will always be alive.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyDeviceIsAlive for the device");
            *((UInt32 *)outData) = 1;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceIsRunning:
            //    This property returns whether or not IO is running for the device. Note that
            //    we need to take both the state lock to check this value for thread safety.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyDeviceIsRunning for the device");
            {
                StateLocker locker(stateMutex);
                *((UInt32 *)outData) = ((gDevice_IOIsRunning > 0) > 0) ? 1 : 0;
            }
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            //    This property returns whether or not the device wants to be able to be the
            //    default device for content. This is the device that iTunes and QuickTime
            //    will use to play their content on and FaceTime will use as it's microhphone.
            //    Nearly all devices should allow for this.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyDeviceCanBeDefaultDevice for the device");
            *((UInt32 *)outData) = 1;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            //    This property returns whether or not the device wants to be the system
            //    default device. This is the device that is used to play interface sounds and
            //    other incidental or UI-related sounds on. Most devices should allow this
            //    although devices with lots of latency may not want to.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyDeviceCanBeDefaultSystemDevice for the device");
            *((UInt32 *)outData) = 1;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyLatency:
            //    The measured delay from Nearfield's clock to the displays'
            //    speakers: the buffered audio plus the displays' own latency.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyLatency for the device");
            {
                const UInt32 reported = reportedLatencyFrames.load();
                *((UInt32 *)outData) = reported > 0 ? reported : currentLatencyFrames();
            }
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyStreams:
            //    Calculate the number of items that have been requested. Note that this
            //    number is allowed to be smaller than the actual size of the list. In such
            //    case, only that number of items will be returned
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);

            //    Note that what is returned here depends on the scope requested.
            switch (inAddress->mScope) {
                case kAudioObjectPropertyScopeGlobal:
                    //    global scope means return all streams
                    if (theNumberItemsToFetch > 1) {
                        theNumberItemsToFetch = 1;
                    }

                    //    fill out the list with as many objects as requested
                    if (theNumberItemsToFetch > 0) {
                        ((AudioObjectID *)outData)[0] = kObjectID_Stream_Output;
                    }
                    // if (theNumberItemsToFetch > 1) {
                    //    ((AudioObjectID *)outData)[1] = kObjectID_Stream_Output;
                    //}
                    break;

                case kAudioObjectPropertyScopeInput:
                    theNumberItemsToFetch = 0;
                    break;

                case kAudioObjectPropertyScopeOutput:
                    //    output scope means just the objects on the output side
                    if (theNumberItemsToFetch > 1) {
                        theNumberItemsToFetch = 1;
                    }

                    //    fill out the list with as many objects as requested
                    if (theNumberItemsToFetch > 0) {
                        ((AudioObjectID *)outData)[0] = kObjectID_Stream_Output;
                    }
                    break;
            };

            //    report how much we wrote
            *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyControlList:
            //    Calculate the number of items that have been requested. Note that this
            //    number is allowed to be smaller than the actual size of the list. In such
            //    case, only that number of items will be returned
            theNumberItemsToFetch = inDataSize / sizeof(AudioObjectID);
            if (theNumberItemsToFetch > 3) {
                theNumberItemsToFetch = 3;
            }

            //    fill out the list with as many objects as requested, which is everything
            for (theItemIndex = 0; theItemIndex < theNumberItemsToFetch; ++theItemIndex) {
                ((AudioObjectID *)outData)[theItemIndex] = kObjectID_Volume_Output_L + theItemIndex;
            }

            //    report how much we wrote
            *outDataSize = theNumberItemsToFetch * sizeof(AudioObjectID);
            break;

        case kAudioDevicePropertySafetyOffset:
            //    This property returns the how close to now the HAL can read and write. For
            //    this, device, the value is 0 due to the fact that it always vends silence.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertySafetyOffset for the device");
            *((UInt32 *)outData) = gDevice_SafetyOffset;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyNominalSampleRate:
            //    This property returns the nominal sample rate of the device. Note that we
            //    only need to take the state lock to get this value.
            FailWithAction(inDataSize < sizeof(Float64),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyNominalSampleRate for the device");
            {
                StateLocker locker(stateMutex);
                *((Float64 *)outData) = gDevice_SampleRate;
            }
            *outDataSize = sizeof(Float64);
            break;

        case kAudioDevicePropertyAvailableNominalSampleRates:
            //    This returns all nominal sample rates the device supports as an array of
            //    AudioValueRangeStructs. Note that for discrete sampler rates, the range
            //    will have the minimum value equal to the maximum value.

            //    Calculate the number of items that have been requested. Note that this
            //    number is allowed to be smaller than the actual size of the list. In such
            //    case, only that number of items will be returned
            //    Only the rates the displays support.
            {
                const std::vector<Float64> rates = currentAvailableSampleRates();
                theNumberItemsToFetch = (UInt32)std::min<size_t>(inDataSize / sizeof(AudioValueRange), rates.size());
                for (unsigned int i = 0; i < theNumberItemsToFetch; ++i) {
                    ((AudioValueRange *)outData)[i].mMinimum = rates[i];
                    ((AudioValueRange *)outData)[i].mMaximum = rates[i];
                }
            }

            //    report how much we wrote
            *outDataSize = theNumberItemsToFetch * sizeof(AudioValueRange);
            break;

        case kAudioDevicePropertyIsHidden:
            //    This returns whether or not the device is visible to clients.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyIsHidden for the device");
            *((UInt32 *)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyPreferredChannelsForStereo:
            //    This property returns which two channesl to use as left/right for stereo
            //    data by default. Note that the channel numbers are 1-based.xz
            FailWithAction(inDataSize < (2 * sizeof(UInt32)),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyPreferredChannelsForStereo for the device");
            ((UInt32 *)outData)[0] = 1;
            ((UInt32 *)outData)[1] = 2;
            *outDataSize = 2 * sizeof(UInt32);
            break;

        case kAudioDevicePropertyPreferredChannelLayout:
            //    This property returns the default AudioChannelLayout to use for the device
            //    by default. For this device, we return a stereo ACL.
            {
                //    calcualte how big the
                UInt32 theACLSize =
                    offsetof(AudioChannelLayout, mChannelDescriptions) + (2 * sizeof(AudioChannelDescription));
                FailWithAction(inDataSize < theACLSize,
                               theAnswer = kAudioHardwareBadPropertySizeError,
                               Done,
                               "GetDevicePropertyData: not enough space for the return value of "
                               "kAudioDevicePropertyPreferredChannelLayout for the device");
                ((AudioChannelLayout *)outData)->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                ((AudioChannelLayout *)outData)->mChannelBitmap = 0;
                ((AudioChannelLayout *)outData)->mNumberChannelDescriptions = gDevice_ChannelsPerFrame;
                for (theItemIndex = 0; theItemIndex < gDevice_ChannelsPerFrame; ++theItemIndex) {
                    ((AudioChannelLayout *)outData)->mChannelDescriptions[theItemIndex].mChannelLabel =
                        kAudioChannelLabel_Left + theItemIndex;
                    ((AudioChannelLayout *)outData)->mChannelDescriptions[theItemIndex].mChannelFlags = 0;
                    ((AudioChannelLayout *)outData)->mChannelDescriptions[theItemIndex].mCoordinates[0] = 0;
                    ((AudioChannelLayout *)outData)->mChannelDescriptions[theItemIndex].mCoordinates[1] = 0;
                    ((AudioChannelLayout *)outData)->mChannelDescriptions[theItemIndex].mCoordinates[2] = 0;
                }
                *outDataSize = theACLSize;
            }
            break;

        case kAudioDevicePropertyZeroTimeStampPeriod:
            //    This property returns how many frames the HAL should expect to see between
            //    successive sample times in the zero time stamps this device provides.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyZeroTimeStampPeriod for the device");
            *((UInt32 *)outData) = kDevice_ZeroTimeStampPeriod;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioDevicePropertyIcon: {
            //    This is a CFURL that points to the device's Icon in the plug-in's resource bundle.
            FailWithAction(inDataSize < sizeof(CFURLRef),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetDevicePropertyData: not enough space for the return value of "
                           "kAudioDevicePropertyDeviceUID for the device");
            CFBundleRef theBundle = CFBundleGetBundleWithIdentifier(CFSTR(kPlugIn_BundleID));
            FailWithAction(theBundle == NULL,
                           theAnswer = kAudioHardwareUnspecifiedError,
                           Done,
                           "GetDevicePropertyData: could not get the plug-in bundle for kAudioDevicePropertyIcon");
            CFURLRef theURL = CFBundleCopyResourceURL(theBundle, CFSTR("DeviceIcon.icns"), NULL, NULL);
            FailWithAction(theURL == NULL,
                           theAnswer = kAudioHardwareUnspecifiedError,
                           Done,
                           "GetDevicePropertyData: could not get the URL for kAudioDevicePropertyIcon");
            *((CFURLRef *)outData) = theURL;
            *outDataSize = sizeof(CFURLRef);
        } break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::SetDevicePropertyData(AudioServerPlugInDriverRef inDriver,
                                                 AudioObjectID inObjectID,
                                                 pid_t inClientProcessID,
                                                 const AudioObjectPropertyAddress *inAddress,
                                                 UInt32 inQualifierDataSize,
                                                 const void *inQualifierData,
                                                 UInt32 inDataSize,
                                                 const void *inData,
                                                 UInt32 *outNumberPropertiesChanged,
                                                 AudioObjectPropertyAddress outChangedAddresses[2]) {
#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;
    Float64 theOldSampleRate;
    UInt64 theNewSampleRate;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "SetDevicePropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SetDevicePropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "SetDevicePropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "SetDevicePropertyData: no place to return the properties that changed");
    FailWithAction(inObjectID != kObjectID_Device,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "SetDevicePropertyData: not the device object");

    //    initialize the returned number of changed properties
    *outNumberPropertiesChanged = 0;

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetDevicePropertyData() method.
    switch (inAddress->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            //    Changing the sample rate needs to be handled via the
            //    RequestConfigChange/PerformConfigChange machinery.

            //    check the arguments
            FailWithAction(inDataSize != sizeof(Float64),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "SetDevicePropertyData: wrong size for the data for kAudioDevicePropertyNominalSampleRate");
            FailWithAction(!isSupportedSampleRate(*(const Float64 *)inData),
                           theAnswer = kAudioHardwareIllegalOperationError,
                           Done,
                           "SetDevicePropertyData: unsupported value for kAudioDevicePropertyNominalSampleRate");

            //    make sure that the new value is different than the old value
            {
                StateLocker locker(stateMutex);
                theOldSampleRate = gDevice_SampleRate;
            }

            if (*((const Float64 *)inData) != theOldSampleRate) {
                //    we dispatch this so that the change can happen asynchronously
                theOldSampleRate = *((const Float64 *)inData);
                theNewSampleRate = (UInt64)theOldSampleRate;
                ExecuteInAudioOutputThread(^{
                    gPlugIn_Host->RequestDeviceConfigurationChange(
                        gPlugIn_Host, kObjectID_Device, theNewSampleRate, NULL);
                });
            }
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

#pragma mark Stream Property Operations

Boolean ProxyAudioDevice::HasStreamProperty(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inObjectID,
                                            pid_t inClientProcessID,
                                            const AudioObjectPropertyAddress *inAddress) {
    //    This method returns whether or not the given object has the given property.

#pragma unused(inClientProcessID)

    //    declare the local variables
    Boolean theAnswer = false;

    //    check the arguments
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "HasStreamProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "HasStreamProperty: no address");
    FailIf((inObjectID != kObjectID_Stream_Output), Done, "HasStreamProperty: not a stream object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetStreamPropertyData() method.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            theAnswer = true;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver,
                                                    AudioObjectID inObjectID,
                                                    pid_t inClientProcessID,
                                                    const AudioObjectPropertyAddress *inAddress,
                                                    Boolean *outIsSettable) {
    //    This method returns whether or not the given property on the object can have its value
    //    changed.

#pragma unused(inClientProcessID)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "IsStreamPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "IsStreamPropertySettable: no address");
    FailWithAction(outIsSettable == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "IsStreamPropertySettable: no place to put the return value");
    FailWithAction((inObjectID != kObjectID_Stream_Output),
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "IsStreamPropertySettable: not a stream object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetStreamPropertyData() method.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outIsSettable = false;
            break;

        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outIsSettable = true;
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inObjectID,
                                                     pid_t inClientProcessID,
                                                     const AudioObjectPropertyAddress *inAddress,
                                                     UInt32 inQualifierDataSize,
                                                     const void *inQualifierData,
                                                     UInt32 *outDataSize) {
    //    This method returns the byte size of the property's data.

#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetStreamPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetStreamPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetStreamPropertyDataSize: no place to put the return value");
    FailWithAction((inObjectID != kObjectID_Stream_Output),
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetStreamPropertyDataSize: not a stream object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetStreamPropertyData() method.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0 * sizeof(AudioObjectID);
            break;

        case kAudioStreamPropertyIsActive:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyDirection:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyTerminalType:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyStartingChannel:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            break;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = (UInt32)(currentAvailableSampleRates().size() * sizeof(AudioStreamRangedDescription));
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetStreamPropertyData(AudioServerPlugInDriverRef inDriver,
                                                 AudioObjectID inObjectID,
                                                 pid_t inClientProcessID,
                                                 const AudioObjectPropertyAddress *inAddress,
                                                 UInt32 inQualifierDataSize,
                                                 const void *inQualifierData,
                                                 UInt32 inDataSize,
                                                 UInt32 *outDataSize,
                                                 void *outData) {
#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;
    UInt32 theNumberItemsToFetch;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetStreamPropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "GetStreamPropertyData: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetStreamPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetStreamPropertyData: no place to put the return value");
    FailWithAction((inObjectID != kObjectID_Stream_Output),
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetStreamPropertyData: not a stream object");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required.
    //
    //    Also, since most of the data that will get returned is static, there are few instances where
    //    it is necessary to lock the state mutex.
    switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            //    The base class for kAudioStreamClassID is kAudioObjectClassID
            FailWithAction(inDataSize < sizeof(AudioClassID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetStreamPropertyData: not enough space for the return value of "
                           "kAudioObjectPropertyBaseClass for the stream");
            *((AudioClassID *)outData) = kAudioObjectClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyClass:
            //    The class is always kAudioStreamClassID for streams created by drivers
            FailWithAction(inDataSize < sizeof(AudioClassID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyClass "
                           "for the stream");
            *((AudioClassID *)outData) = kAudioStreamClassID;
            *outDataSize = sizeof(AudioClassID);
            break;

        case kAudioObjectPropertyOwner:
            //    The stream's owner is the device object
            FailWithAction(inDataSize < sizeof(AudioObjectID),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetStreamPropertyData: not enough space for the return value of kAudioObjectPropertyOwner "
                           "for the stream");
            *((AudioObjectID *)outData) = kObjectID_Device;
            *outDataSize = sizeof(AudioObjectID);
            break;

        case kAudioObjectPropertyOwnedObjects:
            //    Streams do not own any objects
            *outDataSize = 0 * sizeof(AudioObjectID);
            break;

        case kAudioStreamPropertyIsActive:
            //    This property tells the device whether or not the given stream is going to
            //    be used for IO. Note that we need to take the state lock to examine this
            //    value.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetStreamPropertyData: not enough space for the return value of "
                           "kAudioStreamPropertyIsActive for the stream");
            {
                StateLocker locker(stateMutex);
                *((UInt32 *)outData) = gStream_Output_IsActive;
            }
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyDirection:
            //    This returns whether the stream is an input stream or an output stream.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetStreamPropertyData: not enough space for the return value of "
                           "kAudioStreamPropertyDirection for the stream");
            *((UInt32 *)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyTerminalType:
            //    This returns a value that indicates what is at the other end of the stream
            //    such as a speaker or headphones, or a microphone. Values for this property
            //    are defined in <CoreAudio/AudioHardwareBase.h>
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetStreamPropertyData: not enough space for the return value of "
                           "kAudioStreamPropertyTerminalType for the stream");
            *((UInt32 *)outData) = kAudioStreamTerminalTypeSpeaker;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyStartingChannel:
            //    This property returns the absolute channel number for the first channel in
            //    the stream. For exmaple, if a device has two output streams with two
            //    channels each, then the starting channel number for the first stream is 1
            //    and ths starting channel number fo the second stream is 3.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetStreamPropertyData: not enough space for the return value of "
                           "kAudioStreamPropertyStartingChannel for the stream");
            *((UInt32 *)outData) = 1;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyLatency:
            //    This property returns any additonal presentation latency the stream has.
            FailWithAction(inDataSize < sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetStreamPropertyData: not enough space for the return value of "
                           "kAudioStreamPropertyStartingChannel for the stream");
            *((UInt32 *)outData) = 0;
            *outDataSize = sizeof(UInt32);
            break;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            //    This returns the current format of the stream in an
            //    AudioStreamBasicDescription. Note that we need to hold the state lock to get
            //    this value.
            //    Note that for devices that don't override the mix operation, the virtual
            //    format has to be the same as the physical format.
            FailWithAction(inDataSize < sizeof(AudioStreamBasicDescription),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "GetStreamPropertyData: not enough space for the return value of "
                           "kAudioStreamPropertyVirtualFormat for the stream");
            {
                StateLocker locker(stateMutex);
                ((AudioStreamBasicDescription *)outData)->mSampleRate = gDevice_SampleRate;
                ((AudioStreamBasicDescription *)outData)->mFormatID = kAudioFormatLinearPCM;
                ((AudioStreamBasicDescription *)outData)->mFormatFlags =
                    kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
                ((AudioStreamBasicDescription *)outData)->mBytesPerFrame =
                    gDevice_BytesPerFrameInChannel * gDevice_ChannelsPerFrame;
                ((AudioStreamBasicDescription *)outData)->mChannelsPerFrame = gDevice_ChannelsPerFrame;
                ((AudioStreamBasicDescription *)outData)->mBitsPerChannel = gDevice_BytesPerFrameInChannel * 8;
                ((AudioStreamBasicDescription *)outData)->mBytesPerPacket =
                    gDevice_BytesPerFrameInChannel * gDevice_ChannelsPerFrame;
                ((AudioStreamBasicDescription *)outData)->mFramesPerPacket = 1;
            }
            *outDataSize = sizeof(AudioStreamBasicDescription);
            break;

        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            //    This returns an array of AudioStreamRangedDescriptions that describe what
            //    formats are supported.

            //    Calculate the number of items that have been requested. Note that this
            //    number is allowed to be smaller than the actual size of the list. In such
            //    case, only that number of items will be returned
            {
            const std::vector<Float64> rates = currentAvailableSampleRates();
            theNumberItemsToFetch =
                (UInt32)std::min<size_t>(inDataSize / sizeof(AudioStreamRangedDescription), rates.size());

            for (unsigned int i = 0; i < theNumberItemsToFetch; ++i) {
                ((AudioStreamRangedDescription *)outData)[i].mFormat.mSampleRate = rates[i];
                ((AudioStreamRangedDescription *)outData)[i].mFormat.mFormatID = kAudioFormatLinearPCM;
                ((AudioStreamRangedDescription *)outData)[i].mFormat.mFormatFlags =
                    kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
                ((AudioStreamRangedDescription *)outData)[i].mFormat.mBytesPerPacket =
                    gDevice_BytesPerFrameInChannel * gDevice_ChannelsPerFrame;
                ((AudioStreamRangedDescription *)outData)[i].mFormat.mFramesPerPacket = 1;
                ((AudioStreamRangedDescription *)outData)[i].mFormat.mBytesPerFrame =
                    gDevice_BytesPerFrameInChannel * gDevice_ChannelsPerFrame;
                ((AudioStreamRangedDescription *)outData)[i].mFormat.mChannelsPerFrame = gDevice_ChannelsPerFrame;
                ((AudioStreamRangedDescription *)outData)[i].mFormat.mBitsPerChannel =
                    gDevice_BytesPerFrameInChannel * 8;
                ((AudioStreamRangedDescription *)outData)[i].mSampleRateRange.mMinimum = rates[i];
                ((AudioStreamRangedDescription *)outData)[i].mSampleRateRange.mMaximum = rates[i];
            }
            }

            //    report how much we wrote
            *outDataSize = theNumberItemsToFetch * sizeof(AudioStreamRangedDescription);
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::SetStreamPropertyData(AudioServerPlugInDriverRef inDriver,
                                                 AudioObjectID inObjectID,
                                                 pid_t inClientProcessID,
                                                 const AudioObjectPropertyAddress *inAddress,
                                                 UInt32 inQualifierDataSize,
                                                 const void *inQualifierData,
                                                 UInt32 inDataSize,
                                                 const void *inData,
                                                 UInt32 *outNumberPropertiesChanged,
                                                 AudioObjectPropertyAddress outChangedAddresses[2]) {
#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;
    Float64 theOldSampleRate;
    UInt64 theNewSampleRate;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "SetStreamPropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SetStreamPropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "SetStreamPropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "SetStreamPropertyData: no place to return the properties that changed");
    FailWithAction((inObjectID != kObjectID_Stream_Output),
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "SetStreamPropertyData: not a stream object");

    //    initialize the returned number of changed properties
    *outNumberPropertiesChanged = 0;

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetStreamPropertyData() method.
    switch (inAddress->mSelector) {
        case kAudioStreamPropertyIsActive:
            //    Changing the active state of a stream doesn't affect IO or change the structure
            //    so we can just save the state and send the notification.
            FailWithAction(inDataSize != sizeof(UInt32),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "SetStreamPropertyData: wrong size for the data for kAudioDevicePropertyNominalSampleRate");
            {
                StateLocker locker(stateMutex);
                if (gStream_Output_IsActive != (*((const UInt32 *)inData) != 0)) {
                    gStream_Output_IsActive = *((const UInt32 *)inData) != 0;
                    *outNumberPropertiesChanged = 1;
                    outChangedAddresses[0].mSelector = kAudioStreamPropertyIsActive;
                    outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                    outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                }
            }
            break;

        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            //    Changing the stream format needs to be handled via the
            //    RequestConfigChange/PerformConfigChange machinery. Note that because this
            //    device only supports 2 channel 32 bit float data, the only thing that can
            //    change is the sample rate.
            FailWithAction(inDataSize != sizeof(AudioStreamBasicDescription),
                           theAnswer = kAudioHardwareBadPropertySizeError,
                           Done,
                           "SetStreamPropertyData: wrong size for the data for kAudioStreamPropertyPhysicalFormat");
            FailWithAction(((const AudioStreamBasicDescription *)inData)->mFormatID != kAudioFormatLinearPCM,
                           theAnswer = kAudioDeviceUnsupportedFormatError,
                           Done,
                           "SetStreamPropertyData: unsupported format ID for kAudioStreamPropertyPhysicalFormat");
            FailWithAction(((const AudioStreamBasicDescription *)inData)->mFormatFlags
                               != (kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked),
                           theAnswer = kAudioDeviceUnsupportedFormatError,
                           Done,
                           "SetStreamPropertyData: unsupported format flags for kAudioStreamPropertyPhysicalFormat");
            FailWithAction(
                ((const AudioStreamBasicDescription *)inData)->mBytesPerPacket
                    != (gDevice_BytesPerFrameInChannel * gDevice_ChannelsPerFrame),
                theAnswer = kAudioDeviceUnsupportedFormatError,
                Done,
                "SetStreamPropertyData: unsupported bytes per packet for kAudioStreamPropertyPhysicalFormat");
            FailWithAction(
                ((const AudioStreamBasicDescription *)inData)->mFramesPerPacket != 1,
                theAnswer = kAudioDeviceUnsupportedFormatError,
                Done,
                "SetStreamPropertyData: unsupported frames per packet for kAudioStreamPropertyPhysicalFormat");
            FailWithAction(((const AudioStreamBasicDescription *)inData)->mBytesPerFrame
                               != (gDevice_BytesPerFrameInChannel * gDevice_ChannelsPerFrame),
                           theAnswer = kAudioDeviceUnsupportedFormatError,
                           Done,
                           "SetStreamPropertyData: unsupported bytes per frame for kAudioStreamPropertyPhysicalFormat");
            FailWithAction(
                ((const AudioStreamBasicDescription *)inData)->mChannelsPerFrame != gDevice_ChannelsPerFrame,
                theAnswer = kAudioDeviceUnsupportedFormatError,
                Done,
                "SetStreamPropertyData: unsupported channels per frame for kAudioStreamPropertyPhysicalFormat");
            FailWithAction(
                ((const AudioStreamBasicDescription *)inData)->mBitsPerChannel != 32,
                theAnswer = kAudioDeviceUnsupportedFormatError,
                Done,
                "SetStreamPropertyData: unsupported bits per channel for kAudioStreamPropertyPhysicalFormat");
            FailWithAction(!isSupportedSampleRate(((const AudioStreamBasicDescription *)inData)->mSampleRate),
                           theAnswer = kAudioHardwareIllegalOperationError,
                           Done,
                           "SetStreamPropertyData: unsupported sample rate for kAudioStreamPropertyPhysicalFormat");

            //    If we made it this far, the requested format is something we support, so make sure the sample rate is
            //    actually different
            {
                StateLocker locker(stateMutex);
                theOldSampleRate = gDevice_SampleRate;
            }
            if (((const AudioStreamBasicDescription *)inData)->mSampleRate != theOldSampleRate) {
                //    we dispatch this so that the change can happen asynchronously
                theOldSampleRate = ((const AudioStreamBasicDescription *)inData)->mSampleRate;
                theNewSampleRate = (UInt64)theOldSampleRate;
                ExecuteInAudioOutputThread(^{
                    gPlugIn_Host->RequestDeviceConfigurationChange(
                        gPlugIn_Host, kObjectID_Device, theNewSampleRate, NULL);
                });
            }
            break;

        default:
            theAnswer = kAudioHardwareUnknownPropertyError;
            break;
    };

Done:
    return theAnswer;
}

#pragma mark Control Property Operations

Boolean ProxyAudioDevice::HasControlProperty(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inObjectID,
                                             pid_t inClientProcessID,
                                             const AudioObjectPropertyAddress *inAddress) {
    //    This method returns whether or not the given object has the given property.

#pragma unused(inClientProcessID)

    //    declare the local variables
    Boolean theAnswer = false;
    //    check the arguments
    FailIf(inDriver != gAudioServerPlugInDriverRef, Done, "HasControlProperty: bad driver reference");
    FailIf(inAddress == NULL, Done, "HasControlProperty: no address");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetControlPropertyData() method.
    switch (inObjectID) {
        case kObjectID_Volume_Output_R:
        case kObjectID_Volume_Output_L:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                case kAudioLevelControlPropertyDecibelRange:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    theAnswer = true;
                    break;
            };
            break;

        case kObjectID_Mute_Output_Master:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioBooleanControlPropertyValue:
                    theAnswer = true;
                    break;
            };
            break;

    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::IsControlPropertySettable(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inObjectID,
                                                     pid_t inClientProcessID,
                                                     const AudioObjectPropertyAddress *inAddress,
                                                     Boolean *outIsSettable) {
    //    This method returns whether or not the given property on the object can have its value
    //    changed.

#pragma unused(inClientProcessID)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "IsControlPropertySettable: bad driver reference");
    FailWithAction(inAddress == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "IsControlPropertySettable: no address");
    FailWithAction(outIsSettable == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "IsControlPropertySettable: no place to put the return value");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetControlPropertyData() method.
    switch (inObjectID) {
        case kObjectID_Volume_Output_L:
        case kObjectID_Volume_Output_R:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                case kAudioLevelControlPropertyDecibelRange:
                case kAudioLevelControlPropertyConvertScalarToDecibels:
                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    *outIsSettable = false;
                    break;

                case kAudioLevelControlPropertyScalarValue:
                case kAudioLevelControlPropertyDecibelValue:
                    *outIsSettable = true;
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        case kObjectID_Mute_Output_Master:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                case kAudioObjectPropertyClass:
                case kAudioObjectPropertyOwner:
                case kAudioObjectPropertyOwnedObjects:
                case kAudioControlPropertyScope:
                case kAudioControlPropertyElement:
                    *outIsSettable = false;
                    break;

                case kAudioBooleanControlPropertyValue:
                    *outIsSettable = true;
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetControlPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                      AudioObjectID inObjectID,
                                                      pid_t inClientProcessID,
                                                      const AudioObjectPropertyAddress *inAddress,
                                                      UInt32 inQualifierDataSize,
                                                      const void *inQualifierData,
                                                      UInt32 *outDataSize) {
    //    This method returns the byte size of the property's data.

#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetControlPropertyDataSize: bad driver reference");
    FailWithAction(inAddress == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetControlPropertyDataSize: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetControlPropertyDataSize: no place to put the return value");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetControlPropertyData() method.
    switch (inObjectID) {
        case kObjectID_Volume_Output_L:
        case kObjectID_Volume_Output_R:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID);
                    break;

                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0 * sizeof(AudioObjectID);
                    break;

                case kAudioControlPropertyScope:
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    break;

                case kAudioControlPropertyElement:
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    break;

                case kAudioLevelControlPropertyScalarValue:
                    *outDataSize = sizeof(Float32);
                    break;

                case kAudioLevelControlPropertyDecibelValue:
                    *outDataSize = sizeof(Float32);
                    break;

                case kAudioLevelControlPropertyDecibelRange:
                    *outDataSize = sizeof(AudioValueRange);
                    break;

                case kAudioLevelControlPropertyConvertScalarToDecibels:
                    *outDataSize = sizeof(Float32);
                    break;

                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    *outDataSize = sizeof(Float32);
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        case kObjectID_Mute_Output_Master:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyClass:
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyOwner:
                    *outDataSize = sizeof(AudioObjectID);
                    break;

                case kAudioObjectPropertyOwnedObjects:
                    *outDataSize = 0 * sizeof(AudioObjectID);
                    break;

                case kAudioControlPropertyScope:
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    break;

                case kAudioControlPropertyElement:
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    break;

                case kAudioBooleanControlPropertyValue:
                    *outDataSize = sizeof(UInt32);
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::GetControlPropertyData(AudioServerPlugInDriverRef inDriver,
                                                  AudioObjectID inObjectID,
                                                  pid_t inClientProcessID,
                                                  const AudioObjectPropertyAddress *inAddress,
                                                  UInt32 inQualifierDataSize,
                                                  const void *inQualifierData,
                                                  UInt32 inDataSize,
                                                  UInt32 *outDataSize,
                                                  void *outData) {
#pragma unused(inClientProcessID)
#pragma unused(inQualifierDataSize)
#pragma unused(inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "GetControlPropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "GetControlPropertyData: no address");
    FailWithAction(outDataSize == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetControlPropertyData: no place to put the return value size");
    FailWithAction(outData == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "GetControlPropertyData: no place to put the return value");

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required.
    //
    //    Also, since most of the data that will get returned is static, there are few instances where
    //    it is necessary to lock the state mutex.
    switch (inObjectID) {
        case kObjectID_Volume_Output_L:
        case kObjectID_Volume_Output_R:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    //    The base class for kAudioVolumeControlClassID is kAudioLevelControlClassID
                    FailWithAction(inDataSize < sizeof(AudioClassID),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioObjectPropertyBaseClass for the volume control");
                    *((AudioClassID *)outData) = kAudioLevelControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyClass:
                    //    Volume controls are of the class, kAudioVolumeControlClassID
                    FailWithAction(inDataSize < sizeof(AudioClassID),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioObjectPropertyClass for the volume control");
                    *((AudioClassID *)outData) = kAudioVolumeControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyOwner:
                    //    The control's owner is the device object
                    FailWithAction(inDataSize < sizeof(AudioObjectID),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioObjectPropertyOwner for the volume control");
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    break;

                case kAudioObjectPropertyOwnedObjects:
                    //    Controls do not own any objects
                    *outDataSize = 0 * sizeof(AudioObjectID);
                    break;

                case kAudioControlPropertyScope:
                    //    This property returns the scope that the control is attached to.
                    FailWithAction(inDataSize < sizeof(AudioObjectPropertyScope),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioControlPropertyScope for the volume control");
                    *((AudioObjectPropertyScope *)outData) = kAudioObjectPropertyScopeOutput;
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    break;

                case kAudioControlPropertyElement:
                    //    This property returns the element that the control is attached to.
                    FailWithAction(inDataSize < sizeof(AudioObjectPropertyElement),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioControlPropertyElement for the volume control");
                    *((AudioObjectPropertyElement *)outData) = (inObjectID == kObjectID_Volume_Output_L) ? 1 : 2;
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    break;

                case kAudioLevelControlPropertyScalarValue:
                    //    This returns the value of the control in the normalized range of 0 to 1.
                    //    Note that we need to take the state lock to examine the value.
                    FailWithAction(inDataSize < sizeof(Float32),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioLevelControlPropertyScalarValue for the volume control");
                    {
                        StateLocker locker(stateMutex);
                        if (inObjectID == kObjectID_Volume_Output_L) {
                            *((Float32 *)outData) = gVolume_Output_L_Value;
                        } else {
                            *((Float32 *)outData) = gVolume_Output_R_Value;
                        }
                    }
                    *outDataSize = sizeof(Float32);
                    break;

                case kAudioLevelControlPropertyDecibelValue:
                    //    This returns the dB value of the control.
                    //    Note that we need to take the state lock to examine the value.
                    FailWithAction(inDataSize < sizeof(Float32),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioLevelControlPropertyDecibelValue for the volume control");
                    {
                        StateLocker locker(stateMutex);
                        if (inObjectID == kObjectID_Volume_Output_L) {
                            *((Float32 *)outData) = gVolume_Output_L_Value;
                        } else {
                            *((Float32 *)outData) = gVolume_Output_R_Value;
                        }
                    }

                    *((Float32 *)outData) = volumeScalarToDecibels(*((Float32 *)outData));

                    //    report how much we wrote
                    *outDataSize = sizeof(Float32);
                    break;

                case kAudioLevelControlPropertyDecibelRange:
                    //    This returns the dB range of the control.
                    FailWithAction(inDataSize < sizeof(AudioValueRange),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioLevelControlPropertyDecibelRange for the volume control");
                    ((AudioValueRange *)outData)->mMinimum = kVolume_MinDB;
                    ((AudioValueRange *)outData)->mMaximum = kVolume_MaxDB;
                    *outDataSize = sizeof(AudioValueRange);
                    break;

                case kAudioLevelControlPropertyConvertScalarToDecibels:
                    //    This takes the scalar value in outData and converts it to dB.
                    FailWithAction(inDataSize < sizeof(Float32),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioLevelControlPropertyDecibelValue for the volume control");

                    *((Float32 *)outData) = volumeScalarToDecibels(*((Float32 *)outData));

                    //    report how much we wrote
                    *outDataSize = sizeof(Float32);
                    break;

                case kAudioLevelControlPropertyConvertDecibelsToScalar:
                    //    This takes the dB value in outData and converts it to scalar.
                    FailWithAction(inDataSize < sizeof(Float32),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioLevelControlPropertyDecibelValue for the volume control");

                    *((Float32 *)outData) = volumeDecibelsToScalar(*((Float32 *)outData));

                    //    report how much we wrote
                    *outDataSize = sizeof(Float32);
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        case kObjectID_Mute_Output_Master:
            switch (inAddress->mSelector) {
                case kAudioObjectPropertyBaseClass:
                    //    The base class for kAudioMuteControlClassID is kAudioBooleanControlClassID
                    FailWithAction(inDataSize < sizeof(AudioClassID),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioObjectPropertyBaseClass for the mute control");
                    *((AudioClassID *)outData) = kAudioBooleanControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyClass:
                    //    Mute controls are of the class, kAudioMuteControlClassID
                    FailWithAction(inDataSize < sizeof(AudioClassID),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioObjectPropertyClass for the mute control");
                    *((AudioClassID *)outData) = kAudioMuteControlClassID;
                    *outDataSize = sizeof(AudioClassID);
                    break;

                case kAudioObjectPropertyOwner:
                    //    The control's owner is the device object
                    FailWithAction(inDataSize < sizeof(AudioObjectID),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioObjectPropertyOwner for the mute control");
                    *((AudioObjectID *)outData) = kObjectID_Device;
                    *outDataSize = sizeof(AudioObjectID);
                    break;

                case kAudioObjectPropertyOwnedObjects:
                    //    Controls do not own any objects
                    *outDataSize = 0 * sizeof(AudioObjectID);
                    break;

                case kAudioControlPropertyScope:
                    //    This property returns the scope that the control is attached to.
                    FailWithAction(inDataSize < sizeof(AudioObjectPropertyScope),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioControlPropertyScope for the mute control");
                    *((AudioObjectPropertyScope *)outData) = kAudioObjectPropertyScopeOutput;
                    *outDataSize = sizeof(AudioObjectPropertyScope);
                    break;

                case kAudioControlPropertyElement:
                    //    This property returns the element that the control is attached to.
                    FailWithAction(inDataSize < sizeof(AudioObjectPropertyElement),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioControlPropertyElement for the mute control");
                    *((AudioObjectPropertyElement *)outData) = kAudioObjectPropertyElementMain;
                    *outDataSize = sizeof(AudioObjectPropertyElement);
                    break;

                case kAudioBooleanControlPropertyValue:
                    //    This returns the value of the mute control where 0 means that mute is off
                    //    and audio can be heard and 1 means that mute is on and audio cannot be heard.
                    //    Note that we need to take the state lock to examine this value.
                    FailWithAction(inDataSize < sizeof(UInt32),
                                   theAnswer = kAudioHardwareBadPropertySizeError,
                                   Done,
                                   "GetControlPropertyData: not enough space for the return value of "
                                   "kAudioBooleanControlPropertyValue for the mute control");
                    {
                        StateLocker locker(stateMutex);
                        *((UInt32 *)outData) = gMute_Output_Mute ? 1 : 0;
                    }
                    *outDataSize = sizeof(UInt32);
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

OSStatus ProxyAudioDevice::SetControlPropertyData(AudioServerPlugInDriverRef inDriver,
                                                  AudioObjectID inObjectID,
                                                  pid_t inClientProcessID,
                                                  const AudioObjectPropertyAddress *inAddress,
                                                  UInt32 inQualifierDataSize,
                                                  const void *inQualifierData,
                                                  UInt32 inDataSize,
                                                  const void *inData,
                                                  UInt32 *outNumberPropertiesChanged,
                                                  AudioObjectPropertyAddress outChangedAddresses[2]) {
#pragma unused(inClientProcessID, inQualifierDataSize, inQualifierData)

    //    declare the local variables
    OSStatus theAnswer = 0;
    Float32 theNewVolume;

    //    check the arguments
    FailWithAction(inDriver != gAudioServerPlugInDriverRef,
                   theAnswer = kAudioHardwareBadObjectError,
                   Done,
                   "SetControlPropertyData: bad driver reference");
    FailWithAction(
        inAddress == NULL, theAnswer = kAudioHardwareIllegalOperationError, Done, "SetControlPropertyData: no address");
    FailWithAction(outNumberPropertiesChanged == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "SetControlPropertyData: no place to return the number of properties that changed");
    FailWithAction(outChangedAddresses == NULL,
                   theAnswer = kAudioHardwareIllegalOperationError,
                   Done,
                   "SetControlPropertyData: no place to return the properties that changed");

    //    initialize the returned number of changed properties
    *outNumberPropertiesChanged = 0;

    //    Note that for each object, this driver implements all the required properties plus a few
    //    extras that are useful but not required. There is more detailed commentary about each
    //    property in the GetControlPropertyData() method.
    switch (inObjectID) {
        case kObjectID_Volume_Output_L:
        case kObjectID_Volume_Output_R:
            switch (inAddress->mSelector) {
                case kAudioLevelControlPropertyScalarValue:
                    //    For the scalar volume, we clamp the new value to [0, 1]. Note that if this
                    //    value changes, it implies that the dB value changed too.
                    FailWithAction(
                        inDataSize != sizeof(Float32),
                        theAnswer = kAudioHardwareBadPropertySizeError,
                        Done,
                        "SetControlPropertyData: wrong size for the data for kAudioLevelControlPropertyScalarValue");
                    theNewVolume = *((const Float32 *)inData);
                    if (theNewVolume < 0.0) {
                        theNewVolume = 0.0;
                    } else if (theNewVolume > 1.0) {
                        theNewVolume = 1.0;
                    }
                    {
                        StateLocker locker(stateMutex);
                        if (inObjectID == kObjectID_Volume_Output_L) {
                            if (gVolume_Output_L_Value != theNewVolume) {
                                gVolume_Output_L_Value = theNewVolume;
                                *outNumberPropertiesChanged = 2;
                                outChangedAddresses[0].mSelector = kAudioLevelControlPropertyScalarValue;
                                outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                                outChangedAddresses[0].mElement = 1;
                                outChangedAddresses[1].mSelector = kAudioLevelControlPropertyDecibelValue;
                                outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
                                outChangedAddresses[1].mElement = 1;
                            }
                        } else {
                            if (gVolume_Output_R_Value != theNewVolume) {
                                gVolume_Output_R_Value = theNewVolume;
                                *outNumberPropertiesChanged = 2;
                                outChangedAddresses[0].mSelector = kAudioLevelControlPropertyScalarValue;
                                outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                                outChangedAddresses[0].mElement = 2;
                                outChangedAddresses[1].mSelector = kAudioLevelControlPropertyDecibelValue;
                                outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
                                outChangedAddresses[1].mElement = 2;
                            }
                        }
                    }
                    break;

                case kAudioLevelControlPropertyDecibelValue:
                    //    For the dB value, we first convert it to a scalar value since that is how
                    //    the value is tracked. Note that if this value changes, it implies that the
                    //    scalar value changes as well.
                    FailWithAction(
                        inDataSize != sizeof(Float32),
                        theAnswer = kAudioHardwareBadPropertySizeError,
                        Done,
                        "SetControlPropertyData: wrong size for the data for kAudioLevelControlPropertyScalarValue");
                    theNewVolume = *((const Float32 *)inData);
                    theNewVolume = volumeDecibelsToScalar(theNewVolume);
                    {
                        StateLocker locker(stateMutex);
                        if (inObjectID == kObjectID_Volume_Output_L) {
                            if (gVolume_Output_L_Value != theNewVolume) {
                                gVolume_Output_L_Value = theNewVolume;
                                *outNumberPropertiesChanged = 2;
                                outChangedAddresses[0].mSelector = kAudioLevelControlPropertyScalarValue;
                                outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                                outChangedAddresses[0].mElement = 1;
                                outChangedAddresses[1].mSelector = kAudioLevelControlPropertyDecibelValue;
                                outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
                                outChangedAddresses[1].mElement = 1;
                            }
                        } else {
                            if (gVolume_Output_R_Value != theNewVolume) {
                                gVolume_Output_R_Value = theNewVolume;
                                *outNumberPropertiesChanged = 2;
                                outChangedAddresses[0].mSelector = kAudioLevelControlPropertyScalarValue;
                                outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                                outChangedAddresses[0].mElement = 2;
                                outChangedAddresses[1].mSelector = kAudioLevelControlPropertyDecibelValue;
                                outChangedAddresses[1].mScope = kAudioObjectPropertyScopeGlobal;
                                outChangedAddresses[1].mElement = 2;
                            }
                        }
                    }
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        case kObjectID_Mute_Output_Master:
            switch (inAddress->mSelector) {
                case kAudioBooleanControlPropertyValue:
                    FailWithAction(
                        inDataSize != sizeof(UInt32),
                        theAnswer = kAudioHardwareBadPropertySizeError,
                        Done,
                        "SetControlPropertyData: wrong size for the data for kAudioBooleanControlPropertyValue");
                    {
                        StateLocker locker(stateMutex);
                        if (gMute_Output_Mute != (*((const UInt32 *)inData) != 0)) {
                            gMute_Output_Mute = *((const UInt32 *)inData) != 0;
                            *outNumberPropertiesChanged = 1;
                            outChangedAddresses[0].mSelector = kAudioBooleanControlPropertyValue;
                            outChangedAddresses[0].mScope = kAudioObjectPropertyScopeGlobal;
                            outChangedAddresses[0].mElement = kAudioObjectPropertyElementMain;
                        }
                    }
                    break;

                default:
                    theAnswer = kAudioHardwareUnknownPropertyError;
                    break;
            };
            break;

        default:
            theAnswer = kAudioHardwareBadObjectError;
            break;
    };

Done:
    return theAnswer;
}

#pragma mark Output Device Operations

// Everything in this section runs on the driver's queue unless noted. Core
// Audio listener callbacks only queue work; they never call back into Core
// Audio themselves.

static const AudioObjectPropertySelector kOutputDeviceListenedSelectors[] = {
    kAudioDevicePropertyDeviceIsAlive,
    kAudioDevicePropertyNominalSampleRate,
    kAudioDevicePropertyAvailableNominalSampleRates,
    kAudioDevicePropertyLatency,
    kAudioDevicePropertyBufferFrameSize,
    kAudioAggregateDevicePropertyActiveSubDeviceList,
    kAudioAggregateDevicePropertyFullSubDeviceList,
};

static bool isAggregateOnlySelector(AudioObjectPropertySelector selector) {
    return selector == kAudioAggregateDevicePropertyActiveSubDeviceList ||
           selector == kAudioAggregateDevicePropertyFullSubDeviceList;
}

static AudioObjectPropertyScope scopeForListenedSelector(AudioObjectPropertySelector selector) {
    switch (selector) {
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyBufferFrameSize:
            return kAudioObjectPropertyScopeOutput;
        default:
            return kAudioObjectPropertyScopeGlobal;
    }
}

static AudioObjectID audioObjectForUID(const std::string &uid) {
    if (uid.empty()) {
        return kAudioObjectUnknown;
    }
    CFStringSmartRef uidString(nearfield::createCFString(uid));
    if (!uidString) {
        return kAudioObjectUnknown;
    }
    return AudioDevice::audioDeviceIDForDeviceUID(uidString);
}

static bool deviceIsAlive(AudioObjectID device) {
    if (device == kAudioObjectUnknown) {
        return false;
    }
    UInt32 alive = 0;
    UInt32 size = sizeof(alive);
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    nearfield::countHALRequest();
    return AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &alive) == noErr && alive != 0;
}

AudioDevice ProxyAudioDevice::findTargetOutputAudioDevice() {
    std::string uid;
    {
        StateLocker locker(stateMutex);
        uid = settings.targetDevices.size() >= 2 ? std::string(kDriverTargetAggregate_UID) : settings.outputDeviceUID;
    }
    if (uid.empty()) {
        // Before Nearfield configured any displays: follow the Mac's output.
        CFStringSmartRef defaultUID(copyDefaultProxyOutputDeviceUID());
        uid = nearfield::stringFromCF(defaultUID);
    }
    const AudioObjectID device = audioObjectForUID(uid);
    if (device == kAudioObjectUnknown) {
        return AudioDevice();
    }
    return AudioDevice(device);
}

OSStatus ProxyAudioDevice::outputDeviceListenerStatic(AudioObjectID inObjectID,
                                                      UInt32 inNumberAddresses,
                                                      const AudioObjectPropertyAddress *inAddresses,
                                                      void *inClientData) {
    ProxyAudioDevice *device = static_cast<ProxyAudioDevice *>(inClientData);
    if (!device || !inAddresses) {
        return noErr;
    }
    for (UInt32 index = 0; index < inNumberAddresses; ++index) {
        const AudioObjectPropertySelector selector = inAddresses[index].mSelector;
        device->ExecuteInAudioOutputThread(^{
            if (device->outputDevice.isValid() && device->outputDevice.id == inObjectID) {
                device->handleOutputDeviceChange(selector);
            }
        });
    }
    return noErr;
}

OSStatus ProxyAudioDevice::devicesListenerProcStatic(AudioObjectID inObjectID,
                                                     UInt32 inNumberAddresses,
                                                     const AudioObjectPropertyAddress *inAddresses,
                                                     void *inClientData) {
#pragma unused(inObjectID, inNumberAddresses, inAddresses)
    ProxyAudioDevice *device = static_cast<ProxyAudioDevice *>(inClientData);
    if (device) {
        // Re-entering the HAL from this callback (for example to build the
        // aggregate) can deadlock the driver service.
        device->ExecuteInAudioOutputThread(^{ device->handleDeviceListChange(); });
    }
    return noErr;
}

void ProxyAudioDevice::handleDeviceListChange() {
    rebuildDriverOwnedTargetAggregate(false);
    setupTargetOutputDevice();
    refreshTargetOutputReadiness();
}

void ProxyAudioDevice::handleOutputDeviceChange(AudioObjectPropertySelector selector) {
    switch (selector) {
        case kAudioDevicePropertyDeviceIsAlive:
            if (!deviceIsAlive(outputDevice.id)) {
                syslog(LOG_NOTICE, "NearfieldAudioDevice: output device %u is gone", outputDevice.id);
                deinitializeOutputDevice();
                refreshTargetOutputReadiness();
            }
            break;
        case kAudioDevicePropertyNominalSampleRate:
            matchOutputDeviceSampleRate();
            break;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            refreshAvailableSampleRates();
            break;
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyBufferFrameSize:
            outputDevice.updateStreamInfo();
            publishOutputFormatToEngine();
            notifyLatencyChanged();
            break;
        case kAudioAggregateDevicePropertyActiveSubDeviceList:
        case kAudioAggregateDevicePropertyFullSubDeviceList:
            refreshTargetOutputReadiness();
            break;
        default:
            break;
    }
}

void ProxyAudioDevice::publishOutputFormatToEngine() {
    engine.setOutputFormat(outputDevice.sampleRate, outputDevice.bufferFrameSize, outputDevice.latencyFrames);
}

void ProxyAudioDevice::setupTargetOutputDevice() {
    if (!manageOutputDevice) {
        return;
    }
    AudioDevice newOutputDevice = findTargetOutputAudioDevice();
    UInt32 bufferFrameSize = nearfield::kDefaultOutputBufferFrameSize;
    {
        StateLocker locker(stateMutex);
        bufferFrameSize = settings.outputBufferFrameSize;
    }

    if (outputDevice.isValid() && outputDevice.id == newOutputDevice.id && outputDevice.bufferFrameSize == bufferFrameSize) {
        return;
    }

    deinitializeOutputDevice();
    if (!newOutputDevice.isValid()) {
        syslog(LOG_WARNING, "NearfieldAudioDevice: no output device is available yet");
        return;
    }

    outputDevice = newOutputDevice;
    UInt32 classID = 0;
    outputIsAggregate = outputDevice.getIntegerPropertyData(classID, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal,
                                                            kAudioObjectPropertyElementMain) == noErr &&
                        classID == kAudioAggregateDeviceClassID;
    outputDevice.setBufferFrameSize(bufferFrameSize);
    outputDevice.updateStreamInfo();
    outputDevice.setupIOProc(outputDeviceIOProcStatic, this);
    for (AudioObjectPropertySelector selector : kOutputDeviceListenedSelectors) {
        if (outputIsAggregate || !isAggregateOnlySelector(selector)) {
            outputDevice.addPropertyListener(selector, scopeForListenedSelector(selector), kAudioObjectPropertyElementMain,
                                             outputDeviceListenerStatic, this);
        }
    }
    engine.resetClockEstimate();
    publishOutputFormatToEngine();
    syslog(LOG_NOTICE,
           "NearfieldAudioDevice: output device %u at %.0f Hz, buffer %u, latency %u",
           outputDevice.id,
           outputDevice.sampleRate,
           outputDevice.bufferFrameSize,
           outputDevice.latencyFrames);

    refreshAvailableSampleRates();
    // Nearfield's own rate is remembered across restarts; ask the displays
    // for it before following theirs.
    applyRequestedSampleRateToOutput(gDevice_SampleRate.load());
    matchOutputDeviceSampleRate();
    notifyLatencyChanged();
}

void ProxyAudioDevice::initializeOutputDevice() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC), AudioOutputDispatchQueue(), ^() {
        // Calls into Core Audio must not happen during Initialize.
        UInt64 revision;
        {
            StateLocker stateLocker(stateMutex);
            revision = targetConfigurationRevision;
        }
        rebuildDriverOwnedTargetAggregate(false);
        setupTargetOutputDevice();
        appliedTargetConfigurationRevision.store(revision);
        setupAudioDevicesListener();
        refreshTargetOutputReadiness();
    });
}

void ProxyAudioDevice::deinitializeOutputDevice() {
    readyTargetConfigurationRevision.store(0);
    if (outputDevice.isValid()) {
        outputDevice.stop();
        outputRunning.store(false);
        for (AudioObjectPropertySelector selector : kOutputDeviceListenedSelectors) {
            if (outputIsAggregate || !isAggregateOnlySelector(selector)) {
                outputDevice.removePropertyListener(selector, scopeForListenedSelector(selector),
                                                    kAudioObjectPropertyElementMain, outputDeviceListenerStatic, this);
            }
        }
        outputDevice.destroyIOProc();
        outputDevice.invalidate();
        notifyStatusChanged();
    }
    outputDeviceReady = false;
    requestedOutputSampleRate = 0;
}

void ProxyAudioDevice::setupAudioDevicesListener() {
    if (devicesListenerInstalled || !manageOutputDevice) {
        return;
    }
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    nearfield::countHALRequest();
    OSStatus status = AudioObjectAddPropertyListener(kAudioObjectSystemObject, &address, &devicesListenerProcStatic, this);
    if (status != noErr) {
        syslog(LOG_WARNING, "NearfieldAudioDevice: failed to observe the device list (%d)", (int)status);
        return;
    }
    devicesListenerInstalled = true;
}

// Starts the displays when a client plays and stops them once everything
// buffered was played and they have been idle for the keep-alive period.
void ProxyAudioDevice::updateOutputDeviceStartedState() {
    if (!outputDevice.isValid()) {
        return;
    }
    int activeCondition = 0;
    {
        StateLocker locker(stateMutex);
        activeCondition = settings.activeCondition;
    }
    const bool clients = engine.hasActiveClients();
    const bool wanted = activeCondition == 2 || clients || !engine.isDrained();
    if (outputDeviceReady && wanted) {
        ++outputStopToken;
        if (!outputDevice.isStarted) {
            engine.noteOutputStarting();
            diagnostics.record(nearfield::kDiagnosticOutputStartRequested);
            outputDevice.start();
            outputRunning.store(outputDevice.isStarted);
            notifyStatusChanged();
        }
        return;
    }
    if (outputDevice.isStarted) {
        scheduleOutputStop(outputDeviceReady ? kOutputKeepAliveSeconds : 0);
    }
}

void ProxyAudioDevice::scheduleOutputStop(double seconds) {
    const UInt64 token = ++outputStopToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), AudioOutputDispatchQueue(), ^{
        if (token != outputStopToken || !outputDevice.isValid() || !outputDevice.isStarted) {
            return;
        }
        if (outputDeviceReady && (engine.hasActiveClients() || !engine.isDrained())) {
            return;
        }
        outputDevice.stop();
        outputRunning.store(false);
        diagnostics.record(nearfield::kDiagnosticOutputStopped);
        notifyStatusChanged();
    });
}

bool ProxyAudioDevice::isSupportedSampleRate(Float64 sampleRate) {
    for (Float64 rate : currentAvailableSampleRates()) {
        if (fabs(rate - sampleRate) < 0.5) {
            return true;
        }
    }
    return false;
}

std::vector<Float64> ProxyAudioDevice::currentAvailableSampleRates() {
    StateLocker locker(stateMutex);
    if (settings.availableSampleRates.empty()) {
        // Before the displays are known: the rates Studio Displays support.
        return {44100.0, 48000.0, 88200.0, 96000.0};
    }
    return settings.availableSampleRates;
}

// Offers only the rates the displays support.
void ProxyAudioDevice::refreshAvailableSampleRates() {
    if (!outputDevice.isValid()) {
        return;
    }
    AudioObjectPropertyAddress address = {kAudioDevicePropertyAvailableNominalSampleRates,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    nearfield::countHALRequest();
    if (AudioObjectGetPropertyDataSize(outputDevice.id, &address, 0, NULL, &size) != noErr || size == 0) {
        return;
    }
    std::vector<AudioValueRange> ranges(size / sizeof(AudioValueRange));
    nearfield::countHALRequest();
    if (AudioObjectGetPropertyData(outputDevice.id, &address, 0, NULL, &size, ranges.data()) != noErr) {
        return;
    }
    ranges.resize(size / sizeof(AudioValueRange));
    static const Float64 kStandardRates[] = {44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0};
    std::vector<Float64> rates;
    for (Float64 rate : kStandardRates) {
        for (const AudioValueRange &range : ranges) {
            if (rate >= range.mMinimum - 0.5 && rate <= range.mMaximum + 0.5) {
                rates.push_back(rate);
                break;
            }
        }
    }
    if (rates.empty()) {
        return;
    }
    bool changed = false;
    {
        StateLocker locker(stateMutex);
        if (settings.availableSampleRates != rates) {
            settings.availableSampleRates = rates;
            persistSettingsIfChangedNoLock();
            changed = true;
        }
    }
    if (changed) {
        AudioObjectPropertyAddress deviceAddress = {kAudioDevicePropertyAvailableNominalSampleRates,
                                                    kAudioObjectPropertyScopeGlobal,
                                                    kAudioObjectPropertyElementMain};
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &deviceAddress);
        AudioObjectPropertyAddress streamAddresses[2] = {
            {kAudioStreamPropertyAvailableVirtualFormats, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}};
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Stream_Output, 2, streamAddresses);
        notifyStatusChanged();
    }
}

void ProxyAudioDevice::applyRequestedSampleRateToOutput(Float64 sampleRate) {
    if (!outputDevice.isValid() || sampleRate <= 0) {
        return;
    }
    Float64 current = 0;
    if (outputDevice.getDoublePropertyData(current, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain) == noErr &&
        fabs(current - sampleRate) < 0.5) {
        requestedOutputSampleRate = 0;
        return;
    }
    if (!isSupportedSampleRate(sampleRate)) {
        return;
    }
    requestedOutputSampleRate = sampleRate;
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    nearfield::countHALRequest();
    const OSStatus status = AudioObjectSetPropertyData(outputDevice.id, &address, 0, NULL, sizeof(sampleRate), &sampleRate);
    if (status != noErr) {
        syslog(LOG_WARNING, "NearfieldAudioDevice: the displays did not accept %.0f Hz (%d)", sampleRate, (int)status);
        requestedOutputSampleRate = 0;
        return;
    }
    syslog(LOG_NOTICE, "NearfieldAudioDevice: asked the displays for %.0f Hz", sampleRate);
    // The rate listener normally reports the change; check again if it does not.
    scheduleSampleRateRetry();
}

// Follows the displays' rate, or waits for a change Nearfield requested.
void ProxyAudioDevice::matchOutputDeviceSampleRate() {
    if (!outputDevice.isValid()) {
        return;
    }
    Float64 outputRate = 0;
    if (outputDevice.getDoublePropertyData(outputRate, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain) != noErr) {
        scheduleSampleRateRetry();
        return;
    }
    outputDevice.sampleRate = outputRate;
    outputDevice.updateStreamInfo();
    publishOutputFormatToEngine();
    const Float64 deviceRate = gDevice_SampleRate.load();
    diagnostics.record(nearfield::kDiagnosticSampleRate, 1, 0, 0, deviceRate, outputRate);

    if (fabs(outputRate - deviceRate) < 0.5) {
        requestedOutputSampleRate = 0;
        sampleRateRetryCount = 0;
        ++sampleRateRetryToken;
        if (!outputDeviceReady) {
            outputDeviceReady = true;
            notifyStatusChanged();
        }
        updateOutputDeviceStartedState();
        refreshTargetOutputReadiness();
        return;
    }

    // Until the rates agree the output plays silence.
    if (outputDeviceReady) {
        outputDeviceReady = false;
        readyTargetConfigurationRevision.store(0);
        notifyStatusChanged();
    }
    if (requestedOutputSampleRate > 0 && fabs(requestedOutputSampleRate - outputRate) >= 0.5) {
        // Nearfield's own request to the displays is still being applied.
        scheduleSampleRateRetry();
        return;
    }
    if (outputRate > 0 && isSupportedSampleRate(outputRate)) {
        // The displays' rate changed elsewhere (for example in Audio MIDI
        // Setup): Nearfield follows.
        syslog(LOG_NOTICE, "NearfieldAudioDevice: following the displays to %.0f Hz", outputRate);
        gPlugIn_Host->RequestDeviceConfigurationChange(gPlugIn_Host, kObjectID_Device, (UInt64)outputRate, NULL);
        return;
    }
    // The displays report a rate Nearfield cannot use (seen at boot): ask
    // for Nearfield's rate and check again shortly.
    syslog(LOG_WARNING, "NearfieldAudioDevice: the displays report an unusable rate %.0f Hz; retrying", outputRate);
    applyRequestedSampleRateToOutput(deviceRate);
    scheduleSampleRateRetry();
}

void ProxyAudioDevice::scheduleSampleRateRetry() {
    if (sampleRateRetryCount >= 12) {
        requestedOutputSampleRate = 0;
        return;
    }
    const double delay = std::min(4.0, 0.25 * (double)(1u << std::min(sampleRateRetryCount, 4)));
    ++sampleRateRetryCount;
    const UInt64 token = ++sampleRateRetryToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), AudioOutputDispatchQueue(), ^{
        if (token != sampleRateRetryToken) {
            return;
        }
        if (sampleRateRetryCount >= 4) {
            // Stop waiting for a request the displays never applied.
            requestedOutputSampleRate = 0;
        }
        matchOutputDeviceSampleRate();
    });
}

// Recomputed only when the displays, their aggregate or the configuration
// change; never on a timer.
void ProxyAudioDevice::refreshTargetOutputReadiness() {
    std::vector<std::string> expected;
    UInt64 revision;
    {
        StateLocker stateLocker(stateMutex);
        expected = settings.targetDevices;
        revision = targetConfigurationRevision;
    }

    int present = 0;
    for (const std::string &uid : expected) {
        if (deviceIsAlive(audioObjectForUID(uid))) {
            ++present;
        }
    }
    updateDisplayPresence(expected.size() >= 2 ? present : -1);

    UInt64 ready = 0;
    if (expected.size() >= 2 && expected.size() <= 3 && present == (int)expected.size() && outputDeviceReady &&
        outputDevice.isValid() && outputDevice.procId && outputDevice.id == targetAggregateID &&
        appliedTargetConfigurationRevision.load() == revision && deviceIsAlive(targetAggregateID)) {
        bool matches = true;
        AudioObjectPropertyAddress address = {kAudioAggregateDevicePropertyFullSubDeviceList,
                                              kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        CFArrayRef fullList = nullptr;
        UInt32 size = sizeof(fullList);
        nearfield::countHALRequest();
        if (AudioObjectGetPropertyData(targetAggregateID, &address, 0, nullptr, &size, &fullList) != noErr || !fullList) {
            matches = false;
        }
        CFArraySmartRef fullListRef(fullList);
        if (matches && CFArrayGetCount(fullList) != (CFIndex)expected.size()) {
            matches = false;
        }
        for (size_t index = 0; matches && index < expected.size(); ++index) {
            CFStringRef uid = static_cast<CFStringRef>(CFArrayGetValueAtIndex(fullList, (CFIndex)index));
            if (!uid || CFGetTypeID(uid) != CFStringGetTypeID() || nearfield::stringFromCF(uid) != expected[index]) {
                matches = false;
            }
        }
        if (matches) {
            address.mSelector = kAudioAggregateDevicePropertyActiveSubDeviceList;
            size = 0;
            nearfield::countHALRequest();
            if (AudioObjectGetPropertyDataSize(targetAggregateID, &address, 0, nullptr, &size) != noErr ||
                size != expected.size() * sizeof(AudioObjectID)) {
                matches = false;
            }
        }
        if (matches) {
            std::vector<AudioObjectID> active(expected.size());
            nearfield::countHALRequest();
            if (AudioObjectGetPropertyData(targetAggregateID, &address, 0, nullptr, &size, active.data()) != noErr ||
                size != expected.size() * sizeof(AudioObjectID)) {
                matches = false;
            }
            for (size_t index = 0; matches && index < active.size(); ++index) {
                CFStringSmartRef uid(AudioDevice::copyDeviceUID(active[index]));
                if (!uid || std::find(expected.begin(), expected.end(), nearfield::stringFromCF(uid)) == expected.end()) {
                    matches = false;
                }
            }
        }
        if (matches) {
            StateLocker stateLocker(stateMutex);
            if (revision == targetConfigurationRevision) {
                ready = revision;
            }
        }
    }
    if (readyTargetConfigurationRevision.exchange(ready) != ready) {
        syslog(LOG_NOTICE, "NearfieldAudioDevice: display route %s", ready ? "ready" : "not ready");
        notifyStatusChanged();
    }
}

// Hides Nearfield once fewer than two displays have been active for about a
// second, and shows it again as soon as they are back.
void ProxyAudioDevice::updateDisplayPresence(int presentDisplays) {
    presentTargetDisplays.store(presentDisplays);
    if (presentDisplays < 0 || presentDisplays >= 2) {
        ++hideToken;
        if (displaysHidden.load()) {
            setDisplaysHidden(false);
        }
        return;
    }
    if (displaysHidden.load()) {
        return;
    }
    const double sinceStart = nearfield::hostTicksToMilliseconds(mach_absolute_time() - initializedHostTime) / 1000.0;
    const double delay = std::max(kDisplayLossHideSeconds, kDisplayLossStartupGraceSeconds - sinceStart);
    const UInt64 token = ++hideToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), AudioOutputDispatchQueue(), ^{
        if (token != hideToken || displaysHidden.load()) {
            return;
        }
        std::vector<std::string> expected;
        {
            StateLocker locker(stateMutex);
            expected = settings.targetDevices;
        }
        int present = 0;
        for (const std::string &uid : expected) {
            if (deviceIsAlive(audioObjectForUID(uid))) {
                ++present;
            }
        }
        presentTargetDisplays.store(expected.size() >= 2 ? present : -1);
        if (expected.size() >= 2 && present < 2) {
            setDisplaysHidden(true);
        }
    });
}

void ProxyAudioDevice::setDisplaysHidden(bool hidden) {
    if (displaysHidden.exchange(hidden) == hidden) {
        return;
    }
    syslog(LOG_NOTICE, "NearfieldAudioDevice: %s Nearfield (%s)", hidden ? "hiding" : "showing",
           hidden ? "fewer than two displays" : "displays are back");
    notifyDeviceListChanged();
    notifyStatusChanged();
}

bool ProxyAudioDevice::deviceIsPublished() {
    StateLocker locker(stateMutex);
    return gBox_Acquired && !displaysHidden.load();
}

void ProxyAudioDevice::destroyDriverOwnedTargetAggregate() {
    if (targetAggregateID == kAudioObjectUnknown) {
        targetAggregateID = audioObjectForUID(kDriverTargetAggregate_UID);
    }
    if (targetAggregateID == kAudioObjectUnknown) {
        return;
    }
    if (outputDevice.isValid() && outputDevice.id == targetAggregateID) {
        deinitializeOutputDevice();
    }
    nearfield::countHALRequest();
    OSStatus status = AudioHardwareDestroyAggregateDevice(targetAggregateID);
    if (status != noErr) {
        syslog(LOG_WARNING,
               "NearfieldAudioDevice: failed to destroy private target aggregate %u with status %d",
               targetAggregateID,
               (int)status);
    }
    targetAggregateID = kAudioObjectUnknown;
}

void ProxyAudioDevice::rebuildDriverOwnedTargetAggregate(bool forceRebuild) {
    if (!manageOutputDevice) {
        return;
    }
    std::vector<std::string> deviceUIDs;
    bool stereo = true;
    {
        StateLocker locker(stateMutex);
        deviceUIDs = settings.targetDevices;
        stereo = settings.stereo;
    }
    if (deviceUIDs.size() < 2) {
        return;
    }

    if (!forceRebuild) {
        if (targetAggregateID == kAudioObjectUnknown) {
            targetAggregateID = audioObjectForUID(kDriverTargetAggregate_UID);
        }
        if (targetAggregateID != kAudioObjectUnknown) {
            return;
        }
    }

    destroyDriverOwnedTargetAggregate();

    CFMutableArrayRef subdevices = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (!subdevices) {
        syslog(LOG_WARNING, "NearfieldAudioDevice: failed to allocate private target subdevice list");
        return;
    }
    CFArraySmartRef subdevicesRef(subdevices);

    for (size_t index = 0; index < deviceUIDs.size() && index < 3; ++index) {
        CFStringSmartRef subdeviceUID(nearfield::createCFString(deviceUIDs[index]));
        if (!subdeviceUID) {
            continue;
        }

        UInt32 outputChannels = 1;
        UInt32 driftCompensation = index == 0 ? 0 : 1;
        UInt32 driftQuality = kAudioAggregateDriftCompensationHighQuality;
        CFNumberSmartRef outputChannelsRef(CFNumberCreate(NULL, kCFNumberSInt32Type, &outputChannels));
        CFNumberSmartRef driftCompensationRef(CFNumberCreate(NULL, kCFNumberSInt32Type, &driftCompensation));
        CFNumberSmartRef driftQualityRef(CFNumberCreate(NULL, kCFNumberSInt32Type, &driftQuality));
        CFStringSmartRef subdeviceUIDKey(CFStringCreateWithCString(NULL, kAudioSubDeviceUIDKey, kCFStringEncodingUTF8));
        CFStringSmartRef outputChannelsKey(CFStringCreateWithCString(NULL, kAudioSubDeviceOutputChannelsKey, kCFStringEncodingUTF8));
        CFStringSmartRef driftCompensationKey(CFStringCreateWithCString(NULL, kAudioSubDeviceDriftCompensationKey, kCFStringEncodingUTF8));
        CFStringSmartRef driftQualityKey(CFStringCreateWithCString(NULL, kAudioSubDeviceDriftCompensationQualityKey, kCFStringEncodingUTF8));

        if (!outputChannelsRef || !driftCompensationRef || !driftQualityRef ||
            !subdeviceUIDKey || !outputChannelsKey || !driftCompensationKey || !driftQualityKey) {
            syslog(LOG_WARNING, "NearfieldAudioDevice: failed to allocate private target subdevice description");
            continue;
        }

        const void *keys[] = {subdeviceUIDKey.ref(), outputChannelsKey.ref(), driftCompensationKey.ref(), driftQualityKey.ref()};
        const void *values[] = {subdeviceUID.ref(), outputChannelsRef.ref(), driftCompensationRef.ref(), driftQualityRef.ref()};
        CFDictionarySmartRef subdevice(CFDictionaryCreate(NULL, keys, values, sizeof(keys) / sizeof(keys[0]),
                                                          &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
        if (subdevice) {
            CFArrayAppendValue(subdevices, subdevice.ref());
        }
    }

    if (CFArrayGetCount(subdevices) < 2) {
        syslog(LOG_WARNING, "NearfieldAudioDevice: private target aggregate has fewer than two valid subdevices");
        return;
    }

    UInt32 isPrivate = 1;
    UInt32 isStacked = stereo ? 1 : 0;
    CFStringSmartRef aggregateUID(CFStringCreateCopy(NULL, CFSTR(kDriverTargetAggregate_UID)));
    CFStringSmartRef aggregateName(CFStringCreateCopy(NULL, CFSTR(kDriverTargetAggregate_Name)));
    CFStringSmartRef mainSubdeviceUID(nearfield::createCFString(deviceUIDs[0]));
    CFNumberSmartRef isPrivateRef(CFNumberCreate(NULL, kCFNumberSInt32Type, &isPrivate));
    CFNumberSmartRef isStackedRef(CFNumberCreate(NULL, kCFNumberSInt32Type, &isStacked));
    CFStringSmartRef aggregateUIDKey(CFStringCreateWithCString(NULL, kAudioAggregateDeviceUIDKey, kCFStringEncodingUTF8));
    CFStringSmartRef aggregateNameKey(CFStringCreateWithCString(NULL, kAudioAggregateDeviceNameKey, kCFStringEncodingUTF8));
    CFStringSmartRef subdeviceListKey(CFStringCreateWithCString(NULL, kAudioAggregateDeviceSubDeviceListKey, kCFStringEncodingUTF8));
    CFStringSmartRef mainSubdeviceKey(CFStringCreateWithCString(NULL, kAudioAggregateDeviceMainSubDeviceKey, kCFStringEncodingUTF8));
    CFStringSmartRef isPrivateKey(CFStringCreateWithCString(NULL, kAudioAggregateDeviceIsPrivateKey, kCFStringEncodingUTF8));
    CFStringSmartRef isStackedKey(CFStringCreateWithCString(NULL, kAudioAggregateDeviceIsStackedKey, kCFStringEncodingUTF8));

    if (!aggregateUID || !aggregateName || !mainSubdeviceUID || !isPrivateRef || !isStackedRef || !aggregateUIDKey ||
        !aggregateNameKey || !subdeviceListKey || !mainSubdeviceKey || !isPrivateKey || !isStackedKey) {
        syslog(LOG_WARNING, "NearfieldAudioDevice: failed to allocate private target aggregate description");
        return;
    }

    const void *keys[] = {aggregateUIDKey.ref(), aggregateNameKey.ref(), subdeviceListKey.ref(),
                          mainSubdeviceKey.ref(), isPrivateKey.ref(), isStackedKey.ref()};
    const void *values[] = {aggregateUID.ref(), aggregateName.ref(), subdevicesRef.ref(),
                            mainSubdeviceUID.ref(), isPrivateRef.ref(), isStackedRef.ref()};
    CFDictionarySmartRef description(CFDictionaryCreate(NULL, keys, values, sizeof(keys) / sizeof(keys[0]),
                                                        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));

    AudioObjectID newAggregateID = kAudioObjectUnknown;
    nearfield::countHALRequest();
    OSStatus status = AudioHardwareCreateAggregateDevice(description, &newAggregateID);
    if (status != noErr) {
        syslog(LOG_WARNING, "NearfieldAudioDevice: failed to create private target aggregate with status %d", (int)status);
        return;
    }
    targetAggregateID = newAggregateID;
    syslog(LOG_NOTICE, "NearfieldAudioDevice: private target aggregate ready");
}

#pragma mark IO Operations

OSStatus ProxyAudioDevice::StartIO(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID) {
    //    When this returns, the device's clock is running. Several clients can
    //    run IO at once; the first one starts a new session.
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    bool firstClient = false;
    UInt64 clients = 0;
    {
        StateLocker locker(stateMutex);
        if (gDevice_IOIsRunning == UINT64_MAX) {
            return kAudioHardwareIllegalOperationError;
        }
        firstClient = gDevice_IOIsRunning == 0;
        clients = ++gDevice_IOIsRunning;
        if (firstClient) {
            deviceClock.requestReset();
            engine.beginClientSession();
        }
    }
    diagnostics.record(nearfield::kDiagnosticStartIO, (int32_t)clients, inClientID);
    if (firstClient) {
        ExecuteInAudioOutputThread(^() { updateOutputDeviceStartedState(); });
    }
    return 0;
}

OSStatus ProxyAudioDevice::StopIO(AudioServerPlugInDriverRef inDriver,
                                  AudioObjectID inDeviceObjectID,
                                  UInt32 inClientID) {
    //    The displays keep playing what is buffered; they stop after it was
    //    played and the keep-alive period passed.
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    bool lastClient = false;
    UInt64 clients = 0;
    {
        StateLocker locker(stateMutex);
        if (gDevice_IOIsRunning == 0) {
            return kAudioHardwareIllegalOperationError;
        }
        clients = --gDevice_IOIsRunning;
        lastClient = clients == 0;
        if (lastClient) {
            engine.endClientSession();
        }
    }
    diagnostics.record(nearfield::kDiagnosticStopIO, (int32_t)clients, inClientID);
    if (lastClient) {
        ExecuteInAudioOutputThread(^() { updateOutputDeviceStartedState(); });
    }
    return 0;
}

OSStatus ProxyAudioDevice::GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID,
                                            Float64 *outSampleTime,
                                            UInt64 *outHostTime,
                                            UInt64 *outSeed) {
    //    The device's clock follows the displays' clock through the playback
    //    engine's rate estimate (and steering, when enabled). Real-time: no
    //    locks.
#pragma unused(inClientID)
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    deviceClock.get(kDevice_ZeroTimeStampPeriod, engine.clockRatio(), mach_absolute_time(), *outSampleTime, *outHostTime);
    *outSeed = 1;
    return 0;
}

OSStatus ProxyAudioDevice::WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inDeviceObjectID,
                                             UInt32 inClientID,
                                             UInt32 inOperationID,
                                             Boolean *outWillDo,
                                             Boolean *outWillDoInPlace) {
    //    Each client's audio is routed in ProcessOutput, whether or not App
    //    Audio Routing is on, so turning routing on or off also affects audio
    //    that is already playing. The HAL then mixes the clients and the
    //    device takes the mix in WriteMix.
#pragma unused(inClientID)
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }

    bool willDo = false;
    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
        case kAudioServerPlugInIOOperationProcessOutput:
        case kAudioServerPlugInIOOperationWriteMix:
            willDo = true;
            break;
    };

    if (outWillDo != NULL) {
        *outWillDo = willDo;
    }
    if (outWillDoInPlace != NULL) {
        *outWillDoInPlace = true;
    }
    return 0;
}

OSStatus ProxyAudioDevice::BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt32 inClientID,
                                            UInt32 inOperationID,
                                            UInt32 inIOBufferFrameSize,
                                            const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
#pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return 0;
}

OSStatus ProxyAudioDevice::DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         AudioObjectID inStreamObjectID,
                                         UInt32 inClientID,
                                         UInt32 inOperationID,
                                         UInt32 inIOBufferFrameSize,
                                         const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                         void *ioMainBuffer,
                                         void *ioSecondaryBuffer) {
    //    Real-time: no locks, allocation or logging.
#pragma unused(ioSecondaryBuffer)
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    if (inStreamObjectID != kObjectID_Stream_Output || ioMainBuffer == NULL) {
        return kAudioHardwareBadObjectError;
    }

    switch (inOperationID) {
        case kAudioServerPlugInIOOperationReadInput:
            memset(ioMainBuffer, 0, inIOBufferFrameSize * gDevice_BytesPerFrameInChannel * gDevice_ChannelsPerFrame);
            break;

        case kAudioServerPlugInIOOperationProcessOutput:
            routeMixer.process(routeTable, inClientID, (Float32 *)ioMainBuffer, inIOBufferFrameSize, engine.crossfadeFrames());
            break;

        case kAudioServerPlugInIOOperationWriteMix: {
            const AudioTimeStamp &outputTime = inIOCycleInfo->mOutputTime;
            const Float64 rateScalar = (outputTime.mFlags & kAudioTimeStampRateScalarValid) && outputTime.mRateScalar > 0
                                           ? outputTime.mRateScalar
                                           : 1.0;
            const UInt64 hostTime = (outputTime.mFlags & kAudioTimeStampHostTimeValid) ? outputTime.mHostTime : 0;
            const UInt64 now = mach_absolute_time();
            const UInt64 cycleStart = inIOCycleInfo->mCurrentTime.mHostTime;
            engine.write((const Float32 *)ioMainBuffer,
                         inIOBufferFrameSize,
                         outputTime.mSampleTime,
                         hostTime,
                         deviceClock.hostTicksPerFrame() * rateScalar,
                         now > cycleStart ? now - cycleStart : 0);
        } break;

        default:
            break;
    }
    return 0;
}

OSStatus ProxyAudioDevice::EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inDeviceObjectID,
                                          UInt32 inClientID,
                                          UInt32 inOperationID,
                                          UInt32 inIOBufferFrameSize,
                                          const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
#pragma unused(inClientID, inOperationID, inIOBufferFrameSize, inIOCycleInfo)
    if (inDriver != gAudioServerPlugInDriverRef || inDeviceObjectID != kObjectID_Device) {
        return kAudioHardwareBadObjectError;
    }
    return 0;
}

OSStatus ProxyAudioDevice::outputDeviceIOProcStatic(AudioDeviceID inDevice,
                                                    const AudioTimeStamp *inNow,
                                                    const AudioBufferList *inInputData,
                                                    const AudioTimeStamp *inInputTime,
                                                    AudioBufferList *outOutputData,
                                                    const AudioTimeStamp *inOutputTime,
                                                    void *inClientData) {
    if (!inClientData) {
        return noErr;
    }
    return ((ProxyAudioDevice *)inClientData)
        ->outputDeviceIOProc(inDevice, inNow, inInputData, inInputTime, outOutputData, inOutputTime);
}

OSStatus ProxyAudioDevice::outputDeviceIOProc(AudioDeviceID inDevice,
                                              const AudioTimeStamp *inNow,
                                              const AudioBufferList *inInputData,
                                              const AudioTimeStamp *inInputTime,
                                              AudioBufferList *outOutputData,
                                              const AudioTimeStamp *inOutputTime) {
    //    The displays' IO thread. Real-time: no locks, allocation or logging.
#pragma unused(inDevice, inInputData, inInputTime)
    if (!outOutputData || !renderBuffer) {
        return noErr;
    }

    UInt32 frames = 0;
    for (UInt32 index = 0; index < outOutputData->mNumberBuffers; ++index) {
        const AudioBuffer &buffer = outOutputData->mBuffers[index];
        if (buffer.mNumberChannels > 0 && buffer.mData) {
            frames = buffer.mDataByteSize / (buffer.mNumberChannels * sizeof(Float32));
            break;
        }
    }
    if (frames == 0) {
        return noErr;
    }

    const UInt64 now = mach_absolute_time();
    const UInt64 lateness = (inNow && now > inNow->mHostTime) ? now - inNow->mHostTime : 0;
    Float32 gainLeft = 1.0f;
    Float32 gainRight = 1.0f;
    calculateVolumeFactors(gVolume_Output_L_Value.load(std::memory_order_relaxed),
                           gVolume_Output_R_Value.load(std::memory_order_relaxed),
                           gMute_Output_Mute.load(std::memory_order_relaxed),
                           gainLeft,
                           gainRight);
    const bool hostTimeValid = inOutputTime && (inOutputTime->mFlags & kAudioTimeStampHostTimeValid);
    const Float64 rateScalar = (inOutputTime && (inOutputTime->mFlags & kAudioTimeStampRateScalarValid))
                                   ? inOutputTime->mRateScalar
                                   : 1.0;
    const Float64 ticksPerFrame = deviceClock.hostTicksPerFrame() * (rateScalar > 0 ? rateScalar : 1.0);
    // While the rates disagree (during a change) the displays play silence.
    const bool ratesMatch = fabs(engine.currentDeviceSampleRate() - engine.currentOutputSampleRate()) < 0.5;

    UInt32 offset = 0;
    while (offset < frames) {
        const UInt32 count = std::min<UInt32>(nearfield::kMaxRenderFrames, frames - offset);
        if (ratesMatch) {
            const UInt64 hostTime = hostTimeValid ? inOutputTime->mHostTime + (UInt64)(offset * ticksPerFrame) : 0;
            engine.read(renderBuffer, count, hostTime, rateScalar, gainLeft, gainRight, lateness);
        } else {
            memset(renderBuffer, 0, sizeof(Float32) * count * nearfield::kStreamChannels);
        }
        nearfield::renderToBufferList(renderBuffer, count, offset, outOutputData);
        offset += count;
    }
    return noErr;
}

Float32 ProxyAudioDevice::volumeScalarToDecibels(Float32 scalar) {
    if (scalar < 0.0) {
        scalar = 0.0;
    } else if (scalar > 1.0) {
        scalar = 1.0;
    }

    return kVolume_MinDB + (scalar * (kVolume_MaxDB - kVolume_MinDB));
}

Float32 ProxyAudioDevice::volumeDecibelsToScalar(Float32 db) {
    if (db < kVolume_MinDB) {
        db = kVolume_MinDB;
    } else if (db > kVolume_MaxDB) {
        db = kVolume_MaxDB;
    }

    return (db - kVolume_MinDB) / (kVolume_MaxDB - kVolume_MinDB);
}

Float32 ProxyAudioDevice::volumeScalarToGain(Float32 scalar) {
    if (scalar <= 0.0) {
        return 0.0;
    }
    if (scalar >= 1.0) {
        return 1.0;
    }

    Float32 volumeDB = volumeScalarToDecibels(scalar);
    return powf(10.0, volumeDB / 20.0);
}

void ProxyAudioDevice::calculateVolumeFactors(Float32 volumeL,
                                              Float32 volumeR,
                                              bool mute,
                                              Float32 &volumeFactorL,
                                              Float32 &volumeFactorR) {
    volumeFactorL = mute ? 0.0 : volumeScalarToGain(volumeL);
    volumeFactorR = mute ? 0.0 : volumeScalarToGain(volumeR);
}

#pragma mark Settings and Status

// Settings may only be changed by Nearfield itself. A Developer ID signed
// driver requires writers signed by the same team; a development (ad hoc)
// driver accepts any writer. When the check cannot run (for example because
// the driver service's sandbox blocks it), writes are allowed and the status
// reports it.
static CFStringRef copyOwnTeamIdentifier() {
    SecCodeRef selfCode = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &selfCode) != errSecSuccess || !selfCode) {
        return NULL;
    }
    SecStaticCodeRef staticCode = NULL;
    OSStatus status = SecCodeCopyStaticCode(selfCode, kSecCSDefaultFlags, &staticCode);
    CFRelease(selfCode);
    if (status != errSecSuccess || !staticCode) {
        return NULL;
    }
    CFDictionaryRef information = NULL;
    status = SecCodeCopySigningInformation(staticCode, kSecCSSigningInformation, &information);
    CFRelease(staticCode);
    if (status != errSecSuccess || !information) {
        return NULL;
    }
    CFTypeRef team = CFDictionaryGetValue(information, kSecCodeInfoTeamIdentifier);
    CFStringRef result = (team && CFGetTypeID(team) == CFStringGetTypeID()) ? (CFStringRef)CFRetain(team) : NULL;
    CFRelease(information);
    return result;
}

void ProxyAudioDevice::loadOwnTeamIdentifier() {
    std::call_once(teamIdentifierOnce, [this] { ownTeamIdentifier = copyOwnTeamIdentifier(); });
}

bool ProxyAudioDevice::writerIsAuthorized(pid_t processID) {
    loadOwnTeamIdentifier();
    CFStringRef teamIdentifier = ownTeamIdentifier;
    if (!teamIdentifier) {
        StateLocker locker(stateMutex);
        writerVerification = "unsigned driver";
        return true;
    }
    if (processID <= 0) {
        return false;
    }

    struct proc_bsdinfo info;
    UInt64 startTime = 0;
    if (proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == (int)sizeof(info)) {
        startTime = ((UInt64)info.pbi_start_tvsec * 1000000ull) + info.pbi_start_tvusec;
    }
    {
        StateLocker locker(stateMutex);
        auto cached = verifiedWriters.find(processID);
        if (startTime != 0 && cached != verifiedWriters.end() && cached->second.first == startTime) {
            return cached->second.second;
        }
    }

    bool allowed = true;
    std::string verification = "enforced";
    CFNumberSmartRef pidNumber(CFNumberCreate(NULL, kCFNumberIntType, &processID));
    const void *keys[] = {kSecGuestAttributePid};
    const void *values[] = {pidNumber.ref()};
    CFDictionarySmartRef attributes(
        CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    SecCodeRef code = NULL;
    OSStatus status = SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code);
    if (status == errSecSuccess && code) {
        CFStringSmartRef requirementText(CFStringCreateWithFormat(
            NULL, NULL,
            CFSTR("anchor apple generic and certificate leaf[subject.OU] = \"%@\" and identifier \"com.kemuri.Nearfield\""),
            teamIdentifier));
        SecRequirementRef requirement = NULL;
        status = SecRequirementCreateWithString(requirementText, kSecCSDefaultFlags, &requirement);
        if (status == errSecSuccess && requirement) {
            status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
            CFRelease(requirement);
            if (status == errSecCSReqFailed) {
                allowed = false;
            } else if (status != errSecSuccess) {
                verification = "unavailable";
            }
        } else {
            verification = "unavailable";
        }
        CFRelease(code);
    } else {
        verification = "unavailable";
    }

    {
        StateLocker locker(stateMutex);
        writerVerification = verification;
        if (startTime != 0) {
            verifiedWriters[processID] = std::make_pair(startTime, allowed);
        }
    }
    if (!allowed) {
        syslog(LOG_WARNING, "NearfieldAudioDevice: ignoring settings from pid %d, which is not Nearfield", processID);
    } else if (verification == "unavailable") {
        syslog(LOG_NOTICE, "NearfieldAudioDevice: could not verify the settings writer (pid %d, status %d)", processID, (int)status);
    }
    return allowed;
}

OSStatus ProxyAudioDevice::applySettings(const nearfield::SettingsUpdate &update, pid_t writer) {
    if (update.isEmpty()) {
        return noErr;
    }
    if (!writerIsAuthorized(writer)) {
        return kAudioHardwareIllegalOperationError;
    }
    uint32_t changes = 0;
    {
        StateLocker locker(stateMutex);
        nearfield::SettingsUpdate effective = update;
        if (effective.outputDeviceUID && *effective.outputDeviceUID == kDriverTargetAggregate_UID) {
            // Older Nearfield versions name the driver's own aggregate here.
            effective.outputDeviceUID.reset();
        }
        changes = nearfield::applySettingsUpdate(settings, processRoutes, effective);
        if (changes & nearfield::kChangedTargets) {
            ++targetConfigurationRevision;
            readyTargetConfigurationRevision.store(0);
        }
        if (changes & nearfield::kChangedRouting) {
            bundleRoutes = nearfield::parseRouteRules(settings.routeRules).bundleRoutes;
        }
        if (changes & (nearfield::kChangedRouting | nearfield::kChangedProcessRoutes)) {
            // The fast path: route changes reach the IO thread through atomics
            // and are never written to storage.
            updateClientRoutesNoLock();
        }
        if (changes & (nearfield::kChangedPlayback | nearfield::kChangedDiagnostics)) {
            applyPlaybackSettingsNoLock();
        }
        persistSettingsIfChangedNoLock();
    }
    applySettingsEffects(changes);
    return noErr;
}

void ProxyAudioDevice::applySettingsEffects(uint32_t changes) {
    if (changes == 0) {
        return;
    }
    if (changes & nearfield::kChangedDeviceName) {
        ExecuteInAudioOutputThread(^() {
            AudioObjectPropertyAddress address = {
                kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &address);
        });
    }
    if (changes & (nearfield::kChangedTargets | nearfield::kChangedOutputDevice | nearfield::kChangedOutputBuffer)) {
        const bool forceRebuild = (changes & nearfield::kChangedTargets) != 0;
        UInt64 revision;
        {
            StateLocker locker(stateMutex);
            revision = targetConfigurationRevision;
        }
        ExecuteInAudioOutputThread(^{
            rebuildDriverOwnedTargetAggregate(forceRebuild);
            setupTargetOutputDevice();
            appliedTargetConfigurationRevision.store(revision);
            refreshTargetOutputReadiness();
        });
    }
    if (changes & nearfield::kChangedRouting) {
        StateLocker locker(stateMutex);
        syslog(LOG_NOTICE, "NearfieldAudioDevice: routing %s, rules '%s'",
               settings.routingEnabled ? "enabled" : "disabled", settings.routeRules.c_str());
    }
    if (changes & nearfield::kChangedDiagnostics) {
        syslog(LOG_NOTICE, "NearfieldAudioDevice: diagnostics %s", diagnostics.isEnabled() ? "on" : "off");
    }
    notifyStatusChanged();
}

UInt32 ProxyAudioDevice::currentLatencyFrames() {
    const Float64 measured = engine.measuredLatencyFrames();
    if (measured > 0) {
        return (UInt32)llround(measured);
    }
    // Before anything played: the buffering target plus the displays' own latency.
    return (UInt32)llround(engine.estimatedLatencyFrames());
}

void ProxyAudioDevice::notifyLatencyChanged() {
    const UInt32 latency = currentLatencyFrames();
    if (reportedLatencyFrames.exchange(latency) == latency) {
        return;
    }
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &address);
    notifyStatusChanged();
}

void ProxyAudioDevice::notifyDeviceListChanged() {
    ExecuteInAudioOutputThread(^() {
        AudioObjectPropertyAddress plugInAddresses[2] = {
            {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}};
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_PlugIn, 2, plugInAddresses);
        AudioObjectPropertyAddress boxAddress = {
            kAudioBoxPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Box, 1, &boxAddress);
    });
}

void ProxyAudioDevice::notifyStatusChanged() {
    statusGeneration.fetch_add(1);
    if (statusNotificationScheduled.exchange(true)) {
        return;
    }
    // Coalesce bursts (for example several underruns) into one notification.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), AudioOutputDispatchQueue(), ^{
        statusNotificationScheduled.store(false);
        if (!gPlugIn_Host) {
            return;
        }
        AudioObjectPropertyAddress address = {
            kNearfieldPropertyStatus, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Box, 1, &address);
    });
}

void ProxyAudioDevice::handleEngineSignals(uintptr_t signals) {
    if (signals & nearfield::kSignalOutputStarted) {
        const UInt64 requested = engine.outputStartRequestTime();
        const UInt64 started = engine.firstOutputCallbackTime();
        if (requested != 0 && started > requested) {
            const double milliseconds = nearfield::hostTicksToMilliseconds(started - requested);
            lastColdStartMilliseconds.store(milliseconds);
            diagnostics.record(nearfield::kDiagnosticOutputFirstCallback, 0, 0, 0, milliseconds);
        }
    }
    if (signals & nearfield::kSignalLatency) {
        notifyLatencyChanged();
    }
    if (signals & nearfield::kSignalDrained) {
        updateOutputDeviceStartedState();
    }
    if (signals & (nearfield::kSignalCounters | nearfield::kSignalOutputStarted)) {
        notifyStatusChanged();
    }
    if (signals & nearfield::kSignalDiagnostics) {
        drainDiagnostics();
    }
}

void ProxyAudioDevice::drainDiagnostics() {
    nearfield::DiagnosticRecord entry;
    int drained = 0;
    while (drained < 512 && diagnostics.pop(entry)) {
        ++drained;
        syslog(LOG_NOTICE,
               "NearfieldDiag: kind=%s host=%llu i0=%d i1=%lld i2=%lld d0=%.3f d1=%.3f d2=%.3f",
               nearfield::diagnosticKindName(entry.kind),
               entry.hostTime,
               entry.i0,
               entry.i1,
               entry.i2,
               entry.d0,
               entry.d1,
               entry.d2);
    }
    const uint64_t dropped = diagnostics.dropped();
    if (dropped != reportedDroppedDiagnostics) {
        syslog(LOG_NOTICE, "NearfieldDiag: kind=dropped total=%llu", dropped);
        reportedDroppedDiagnostics = dropped;
    }
}

CFDictionaryRef ProxyAudioDevice::copyStatusDictionary() {
    using namespace nearfield;
    CFMutableDictionaryRef status =
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!status) {
        return NULL;
    }

    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR(kPlugIn_BundleID));
    CFTypeRef version = bundle ? CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CFBundleShortVersionString")) : NULL;
    if (version && CFGetTypeID(version) == CFStringGetTypeID()) {
        CFDictionarySetValue(status, CFSTR("driverVersion"), version);
    }
    setDictionaryInteger(status, CFSTR("protocolVersion"), kNearfieldProtocolVersion);
    // Changes whenever the driver restarts (settings sent only to a previous
    // instance, such as process routes, must be sent again).
    setDictionaryInteger(status, CFSTR("instance"), (int64_t)(initializedHostTime & 0x7fffffffffffffffULL));
    setDictionaryStrings(status, CFSTR("capabilities"),
                         {"driverOwnedTargetAggregate", "threeDisplayTargetAggregate", "targetOutputReadiness",
                          "settingsDictionary", "statusNotifications", "processRoutes", "latencyReporting"});

    const std::vector<Float64> rates = currentAvailableSampleRates();
    {
        StateLocker locker(stateMutex);
        const UInt64 revision = targetConfigurationRevision;
        const bool ready = settings.targetDevices.size() >= 2 &&
                           readyTargetConfigurationRevision.load() == revision &&
                           appliedTargetConfigurationRevision.load() == revision;
        CFDictionarySetValue(status, CFSTR("ready"), ready ? kCFBooleanTrue : kCFBooleanFalse);
        setDictionaryInteger(status, CFSTR("configurationRevision"), (int64_t)revision);
        setDictionaryStrings(status, CFSTR("targetDevices"), settings.targetDevices);
        setDictionaryString(status, CFSTR("targetMode"), settings.stereo ? "stereo" : "mono");
        setDictionaryString(status, CFSTR("underrunStrategy"), underrunStrategyName(settings.underrunStrategy));
        CFDictionarySetValue(status, CFSTR("published"), gBox_Acquired ? kCFBooleanTrue : kCFBooleanFalse);
        setDictionaryInteger(status, CFSTR("ioClients"), (int64_t)gDevice_IOIsRunning);
        setDictionaryString(status, CFSTR("writerVerification"), writerVerification);
    }
    setDictionaryInteger(status, CFSTR("displaysPresent"), presentTargetDisplays.load());
    CFDictionarySetValue(status, CFSTR("hidden"), displaysHidden.load() ? kCFBooleanTrue : kCFBooleanFalse);
    CFDictionarySetValue(status, CFSTR("outputRunning"), outputRunning.load() ? kCFBooleanTrue : kCFBooleanFalse);
    CFDictionarySetValue(status, CFSTR("diagnostics"), diagnostics.isEnabled() ? kCFBooleanTrue : kCFBooleanFalse);

    const Float64 sampleRate = gDevice_SampleRate.load();
    setDictionaryNumber(status, CFSTR("sampleRate"), sampleRate);
    setDictionaryNumber(status, CFSTR("outputSampleRate"), engine.currentOutputSampleRate());
    setDictionaryNumbers(status, CFSTR("availableSampleRates"), rates);
    const UInt32 latency = reportedLatencyFrames.load();
    setDictionaryInteger(status, CFSTR("latencyFrames"), latency);
    setDictionaryNumber(status, CFSTR("latencyMilliseconds"), latency * 1000.0 / sampleRate);
    setDictionaryNumber(status, CFSTR("bufferedMilliseconds"), engine.lastBufferedMilliseconds());
    setDictionaryNumber(status, CFSTR("safetyGapMilliseconds"), engine.currentSafetyGapMilliseconds());
    setDictionaryNumber(status, CFSTR("rateScalar"), engine.rateScalarEstimate());
    setDictionaryNumber(status, CFSTR("clockCorrectionPPM"), engine.steeringPPM());

    const PlaybackCounters &counters = engine.counters();
    CFMutableDictionaryRef counts =
        CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (counts) {
        setDictionaryInteger(counts, CFSTR("underruns"), (int64_t)counters.underruns.load());
        setDictionaryInteger(counts, CFSTR("overruns"), (int64_t)counters.overruns.load());
        setDictionaryInteger(counts, CFSTR("coldStarts"), (int64_t)counters.coldStarts.load());
        setDictionaryNumber(counts, CFSTR("lastColdStartMilliseconds"), lastColdStartMilliseconds.load());
        setDictionaryNumber(counts, CFSTR("lastColdStartBufferedMilliseconds"),
                            counters.lastColdStartBufferedFrames.load() * 1000.0 / sampleRate);
        setDictionaryNumber(counts, CFSTR("trimmedMilliseconds"), counters.trimmedFrames.load() * 1000.0 / sampleRate);
        setDictionaryInteger(counts, CFSTR("writerGaps"), (int64_t)counters.writerGaps.load());
        setDictionaryInteger(counts, CFSTR("halRequests"), (int64_t)halRequestCount().load());
        setDictionaryInteger(counts, CFSTR("readerCallbacks"), (int64_t)counters.readerCallbacks.load());
        setDictionaryInteger(counts, CFSTR("writerCallbacks"), (int64_t)counters.writerCallbacks.load());
        setDictionaryInteger(counts, CFSTR("droppedDiagnostics"), (int64_t)diagnostics.dropped());
        CFDictionarySetValue(status, CFSTR("counters"), counts);
        CFRelease(counts);
    }
    return status;
}

#pragma mark Legacy Configuration Channel

void ProxyAudioDevice::parseConfigurationString(CFStringRef configString, ConfigType &action, CFStringRef &value) {
    CFRange splitter = CFStringFind(configString, CFSTR("="), 0);
    if (splitter.location == kCFNotFound) {
        return;
    }

    CFStringSmartRef actionString(CFStringCreateWithSubstring(NULL, configString, CFRangeMake(0, splitter.location)));
    static const std::pair<CFStringRef, ConfigType> kActions[] = {
        {CFSTR("outputDevice"), ConfigType::outputDevice},
        {CFSTR("outputDeviceBufferFrameSize"), ConfigType::outputDeviceBufferFrameSize},
        {CFSTR("deviceName"), ConfigType::deviceName},
        {CFSTR("outputDeviceActiveCondition"), ConfigType::deviceActiveCondition},
        {CFSTR("routingEnabled"), ConfigType::routingEnabled},
        {CFSTR("routeRules"), ConfigType::routeRules},
        {CFSTR("targetAggregateDevices"), ConfigType::targetAggregateDevices},
        {CFSTR("targetAggregateMode"), ConfigType::targetAggregateMode},
    };
    for (const auto &candidate : kActions) {
        if (CFStringCompare(actionString, candidate.first, 0) == kCFCompareEqualTo) {
            action = candidate.second;
            value = CFStringCreateWithSubstring(
                NULL, configString,
                CFRangeMake(splitter.location + splitter.length,
                            CFStringGetLength(configString) - splitter.location - splitter.length));
            return;
        }
    }
}

// Maps one legacy "setting=value" write onto a settings update.
void ProxyAudioDevice::setConfigurationValue(ConfigType type, CFStringRef value, pid_t writer) {
    CFStringRef keys[1] = {NULL};
    switch (type) {
        case ConfigType::outputDevice: keys[0] = nearfield::kSettingsOutputDeviceKey; break;
        case ConfigType::outputDeviceBufferFrameSize: keys[0] = nearfield::kSettingsOutputBufferFrameSizeKey; break;
        case ConfigType::deviceName: keys[0] = nearfield::kSettingsDeviceNameKey; break;
        case ConfigType::deviceActiveCondition: keys[0] = nearfield::kSettingsActiveConditionKey; break;
        case ConfigType::routingEnabled: keys[0] = nearfield::kSettingsRoutingEnabledKey; break;
        case ConfigType::routeRules: keys[0] = nearfield::kSettingsRouteRulesKey; break;
        case ConfigType::targetAggregateDevices: keys[0] = nearfield::kSettingsTargetDevicesKey; break;
        case ConfigType::targetAggregateMode: keys[0] = nearfield::kSettingsTargetModeKey; break;
        default: return;
    }
    const void *values[1] = {value};
    CFDictionarySmartRef dictionary(CFDictionaryCreate(NULL, (const void **)keys, values, 1,
                                                       &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    nearfield::SettingsUpdate update;
    if (!dictionary || !nearfield::parseSettingsUpdate(dictionary, update)) {
        return;
    }
    if (type == ConfigType::routeRules && !update.processRoutes) {
        // Older Nearfield versions send the full rules each time; no process
        // rules means none apply any more.
        update.processRoutes = std::map<pid_t, nearfield::Route>();
    }
    applySettings(update, writer);
}

CFStringRef ProxyAudioDevice::copyConfigurationValue(ConfigType type) {
    StateLocker locker(stateMutex);
    switch (type) {
        case ConfigType::outputDevice:
            return settings.targetDevices.size() >= 2 ? CFStringCreateCopy(NULL, CFSTR(kDriverTargetAggregate_UID))
                                                      : nearfield::createCFString(settings.outputDeviceUID);
        case ConfigType::outputDeviceBufferFrameSize:
            return CFStringCreateWithFormat(NULL, NULL, CFSTR("%u"), settings.outputBufferFrameSize);
        case ConfigType::deviceName:
            return nearfield::createCFString(settings.deviceName);
        case ConfigType::deviceActiveCondition:
            return CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), settings.activeCondition);
        case ConfigType::routingEnabled:
            return CFStringCreateWithFormat(NULL, NULL, CFSTR("%d"), settings.routingEnabled ? 1 : 0);
        case ConfigType::routeRules: {
            std::string rules = settings.routeRules;
            for (const auto &entry : processRoutes) {
                if (!rules.empty()) rules += "; ";
                rules += "pid:" + std::to_string(entry.first) + "=" + nearfield::routeName(entry.second);
            }
            return nearfield::createCFString(rules);
        }
        case ConfigType::driverCapabilities:
            return CFStringCreateCopy(
                NULL, CFSTR("driverOwnedTargetAggregate,threeDisplayTargetAggregate,targetOutputReadiness,settingsDictionary"));
        case ConfigType::targetOutputReadiness: {
            const UInt64 revision = targetConfigurationRevision;
            if (readyTargetConfigurationRevision.load() != revision || appliedTargetConfigurationRevision.load() != revision ||
                settings.targetDevices.size() < 2) {
                return CFStringCreateCopy(NULL, CFSTR("pending"));
            }
            std::string status = std::string("ready\n") + (settings.stereo ? "stereo" : "mono");
            for (const std::string &uid : settings.targetDevices) {
                status += "\n" + uid;
            }
            return nearfield::createCFString(status);
        }
        case ConfigType::targetAggregateDevices: {
            std::string devices;
            for (const std::string &uid : settings.targetDevices) {
                if (!devices.empty()) devices += "\n";
                devices += uid;
            }
            return nearfield::createCFString(devices);
        }
        case ConfigType::targetAggregateMode:
            return CFStringCreateCopy(NULL, settings.stereo ? CFSTR("stereo") : CFSTR("mono"));
        default:
            return nullptr;
    }
}

CFStringRef ProxyAudioDevice::copyDeviceName() {
    StateLocker locker(stateMutex);
    return nearfield::createCFString(settings.deviceName);
}

CFStringRef ProxyAudioDevice::copyDefaultProxyOutputDeviceUID() {
    // The Mac's output, unless that is Nearfield itself; otherwise the first
    // stereo output.
    AudioObjectID defaultDevice = AudioDevice::defaultOutputDevice();
    if (defaultDevice != kAudioObjectUnknown) {
        CFStringRef uid = AudioDevice::copyDeviceUID(defaultDevice);
        if (uid && CFStringCompare(uid, CFSTR(kDevice_UID), 0) != kCFCompareEqualTo) {
            return uid;
        }
        if (uid) {
            CFRelease(uid);
        }
    }
    std::vector<AudioObjectID> outputDevices = AudioDevice::devicesWithOutputCapabilitiesThatAreNotProxyAudioDevice();
    if (!outputDevices.empty()) {
        return AudioDevice::copyDeviceUID(outputDevices[0]);
    }
    return nullptr;
}

dispatch_queue_t ProxyAudioDevice::AudioOutputDispatchQueue() {
    return audioOutputQueue;
}

void ProxyAudioDevice::ExecuteInAudioOutputThread(void (^block)()) {
    dispatch_async(AudioOutputDispatchQueue(), block);
}
