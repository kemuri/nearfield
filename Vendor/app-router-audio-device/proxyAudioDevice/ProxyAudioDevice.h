#ifndef ProxyAudioDevice_h
#define ProxyAudioDevice_h

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <map>
#include <mutex>
#include <string>
#include <vector>

#include "AudioDevice.h"
#include "NearfieldDiagnostics.h"
#include "NearfieldPlayback.h"
#include "NearfieldRouteTable.h"
#include "NearfieldSettings.h"

// Builds made with build_router_driver.sh --diagnostics log diagnostics from
// the start; other builds do when Nearfield turns them on in the settings.
#ifndef NEARFIELD_DRIVER_DIAGNOSTICS
#define NEARFIELD_DRIVER_DIAGNOSTICS 0
#endif

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Box = 2,
    kObjectID_Device = 3,
    kObjectID_Stream_Output = 4,
    kObjectID_Volume_Output_L = 5,
    kObjectID_Volume_Output_R = 6,
    kObjectID_Mute_Output_Master = 7
};

#define kPlugIn_BundleID "com.kemuri.Nearfield.AudioDevice"
#define kBox_UID "NearfieldAudioBox_UID"
#define kDevice_UID "NearfieldAudioDevice_UID"
#define kDevice_ModelUID "NearfieldAudioDevice_ModelUID"
#define kDriverTargetAggregate_UID "com.kemuri.Nearfield.DriverTargetAggregate"
#define kDriverTargetAggregate_Name "Nearfield Driver Target"

// Custom box properties shared with Nearfield (see NearfieldSettings.h).
// Settings: a CFDictionary Nearfield writes. Status: a CFDictionary it reads
// and observes; the driver notifies listeners whenever it changes.
constexpr AudioObjectPropertySelector kNearfieldPropertySettings = 'nfst';
constexpr AudioObjectPropertySelector kNearfieldPropertyStatus = 'nfss';
constexpr int kNearfieldProtocolVersion = 1;

// Keep the displays running this long after the last sound. Starting them
// again takes about 440 ms, and the audio written meanwhile is skipped to
// keep the latency (and video) in step, so the start of the next sound would
// be cut. The driver's output costs about 0.3-0.5% CPU while it runs.
constexpr double kOutputKeepAliveSeconds = 120.0;
// Hide Nearfield once fewer than two displays have been active this long.
constexpr double kDisplayLossHideSeconds = 1.0;
// Core Audio enumerates USB displays some seconds after boot; do not hide
// Nearfield before they had a chance to appear.
constexpr double kDisplayLossStartupGraceSeconds = 10.0;

using StateLocker = std::lock_guard<std::recursive_mutex>;

class ProxyAudioDevice {
  public:
    // Legacy configuration channel (box Identify + name), kept for one
    // release so older Nearfield versions can still configure this driver.
    enum class ConfigType {
        none,
        outputDevice,
        outputDeviceBufferFrameSize,
        deviceName,
        deviceActiveCondition,
        routingEnabled,
        routeRules,
        driverCapabilities,
        targetAggregateDevices,
        targetAggregateMode,
        targetOutputReadiness
    };

    struct ClientInfo {
        UInt32 clientID = 0;
        pid_t processID = 0;
        std::string bundleID;
        nearfield::Route route = nearfield::Route::pair;
    };

    ProxyAudioDevice();

    // MARK: Output device (all on the driver's queue)
    AudioDevice findTargetOutputAudioDevice();
    static OSStatus outputDeviceListenerStatic(AudioObjectID inObjectID,
                                               UInt32 inNumberAddresses,
                                               const AudioObjectPropertyAddress *inAddresses,
                                               void *inClientData);
    static OSStatus devicesListenerProcStatic(AudioObjectID inObjectID,
                                              UInt32 inNumberAddresses,
                                              const AudioObjectPropertyAddress *inAddresses,
                                              void *inClientData);
    void handleOutputDeviceChange(AudioObjectPropertySelector selector);
    void handleDeviceListChange();
    void setupAudioDevicesListener();
    void setupTargetOutputDevice();
    void initializeOutputDevice();
    void deinitializeOutputDevice();
    void updateOutputDeviceStartedState();
    void scheduleOutputStop(double seconds);
    void matchOutputDeviceSampleRate();
    void scheduleSampleRateRetry();
    void scheduleOutputSetupRetry();
    void applyRequestedSampleRateToOutput(Float64 sampleRate);
    void refreshAvailableSampleRates();
    void refreshTargetOutputReadiness();
    void updateDisplayPresence(int presentDisplays);
    void setDisplaysHidden(bool hidden);
    void rebuildDriverOwnedTargetAggregate(bool forceRebuild);
    void destroyDriverOwnedTargetAggregate();
    void publishOutputFormatToEngine();
    static OSStatus outputDeviceIOProcStatic(AudioDeviceID inDevice,
                                             const AudioTimeStamp *inNow,
                                             const AudioBufferList *inInputData,
                                             const AudioTimeStamp *inInputTime,
                                             AudioBufferList *outOutputData,
                                             const AudioTimeStamp *inOutputTime,
                                             void *inClientData);
    OSStatus outputDeviceIOProc(AudioDeviceID inDevice,
                                const AudioTimeStamp *inNow,
                                const AudioBufferList *inInputData,
                                const AudioTimeStamp *inInputTime,
                                AudioBufferList *outOutputData,
                                const AudioTimeStamp *inOutputTime);

    // MARK: Volume
    void calculateVolumeFactors(Float32 volumeL, Float32 volumeR, bool mute, Float32 &volumeFactorL, Float32 &volumeFactorR);
    Float32 volumeScalarToDecibels(Float32 scalar);
    Float32 volumeDecibelsToScalar(Float32 db);
    Float32 volumeScalarToGain(Float32 scalar);

    // MARK: Settings and status
    OSStatus applySettings(const nearfield::SettingsUpdate &update, pid_t writer);
    void applySettingsEffects(uint32_t changes);
    void persistSettingsIfChangedNoLock();
    void loadSettingsFromStorage();
    void updateClientRoutesNoLock();
    nearfield::Route routeForClientNoLock(const std::string &bundleID, pid_t processID) const;
    void applyPlaybackSettingsNoLock();
    CFDictionaryRef copyStatusDictionary();
    void notifyStatusChanged();
    void notifyDeviceListChanged();
    void notifyLatencyChanged();
    bool writerIsAuthorized(pid_t processID);
    void loadOwnTeamIdentifier();
    void handleEngineSignals(uintptr_t signals);
    void drainDiagnostics();
    std::vector<Float64> currentAvailableSampleRates();
    bool isSupportedSampleRate(Float64 sampleRate);
    UInt32 currentLatencyFrames();
    bool deviceIsPublished();

    // MARK: Legacy configuration channel
    void parseConfigurationString(CFStringRef configString, ConfigType &action, CFStringRef &value);
    void setConfigurationValue(ConfigType action, CFStringRef value, pid_t writer);
    CFStringRef copyConfigurationValue(ConfigType action);
    CFStringRef copyDeviceName();
    CFStringRef copyDefaultProxyOutputDeviceUID();

    static ProxyAudioDevice *deviceForDriver(void *inDriver);

    //    Entry points for the COM methods
    static HRESULT ProxyAudio_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
    static ULONG ProxyAudio_AddRef(void *inDriver);
    static ULONG ProxyAudio_Release(void *inDriver);
    static OSStatus ProxyAudio_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
    static OSStatus ProxyAudio_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                            CFDictionaryRef inDescription,
                                            const AudioServerPlugInClientInfo *inClientInfo,
                                            AudioObjectID *outDeviceObjectID);
    static OSStatus ProxyAudio_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
    static OSStatus ProxyAudio_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inDeviceObjectID,
                                               const AudioServerPlugInClientInfo *inClientInfo);
    static OSStatus ProxyAudio_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                                  AudioObjectID inDeviceObjectID,
                                                  const AudioServerPlugInClientInfo *inClientInfo);
    static OSStatus ProxyAudio_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                                AudioObjectID inDeviceObjectID,
                                                                UInt64 inChangeAction,
                                                                void *inChangeInfo);
    static OSStatus ProxyAudio_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                              AudioObjectID inDeviceObjectID,
                                                              UInt64 inChangeAction,
                                                              void *inChangeInfo);
    static Boolean ProxyAudio_HasProperty(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inObjectID,
                                          pid_t inClientProcessID,
                                          const AudioObjectPropertyAddress *inAddress);
    static OSStatus ProxyAudio_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                                  AudioObjectID inObjectID,
                                                  pid_t inClientProcessID,
                                                  const AudioObjectPropertyAddress *inAddress,
                                                  Boolean *outIsSettable);
    static OSStatus ProxyAudio_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inObjectID,
                                                   pid_t inClientProcessID,
                                                   const AudioObjectPropertyAddress *inAddress,
                                                   UInt32 inQualifierDataSize,
                                                   const void *inQualifierData,
                                                   UInt32 *outDataSize);
    static OSStatus ProxyAudio_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t inClientProcessID,
                                               const AudioObjectPropertyAddress *inAddress,
                                               UInt32 inQualifierDataSize,
                                               const void *inQualifierData,
                                               UInt32 inDataSize,
                                               UInt32 *outDataSize,
                                               void *outData);
    static OSStatus ProxyAudio_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                               AudioObjectID inObjectID,
                                               pid_t inClientProcessID,
                                               const AudioObjectPropertyAddress *inAddress,
                                               UInt32 inQualifierDataSize,
                                               const void *inQualifierData,
                                               UInt32 inDataSize,
                                               const void *inData);
    static OSStatus ProxyAudio_StartIO(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       UInt32 inClientID);
    static OSStatus ProxyAudio_StopIO(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID);
    static OSStatus ProxyAudio_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                                AudioObjectID inDeviceObjectID,
                                                UInt32 inClientID,
                                                Float64 *outSampleTime,
                                                UInt64 *outHostTime,
                                                UInt64 *outSeed);
    static OSStatus ProxyAudio_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                                 AudioObjectID inDeviceObjectID,
                                                 UInt32 inClientID,
                                                 UInt32 inOperationID,
                                                 Boolean *outWillDo,
                                                 Boolean *outWillDoInPlace);
    static OSStatus ProxyAudio_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                                AudioObjectID inDeviceObjectID,
                                                UInt32 inClientID,
                                                UInt32 inOperationID,
                                                UInt32 inIOBufferFrameSize,
                                                const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
    static OSStatus ProxyAudio_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                             AudioObjectID inDeviceObjectID,
                                             AudioObjectID inStreamObjectID,
                                             UInt32 inClientID,
                                             UInt32 inOperationID,
                                             UInt32 inIOBufferFrameSize,
                                             const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                             void *ioMainBuffer,
                                             void *ioSecondaryBuffer);
    static OSStatus ProxyAudio_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inDeviceObjectID,
                                              UInt32 inClientID,
                                              UInt32 inOperationID,
                                              UInt32 inIOBufferFrameSize,
                                              const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

    //    Implementation
    HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
    ULONG AddRef(void *inDriver);
    ULONG Release(void *inDriver);
    OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
    OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver,
                          CFDictionaryRef inDescription,
                          const AudioServerPlugInClientInfo *inClientInfo,
                          AudioObjectID *outDeviceObjectID);
    OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
    OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                             AudioObjectID inDeviceObjectID,
                             const AudioServerPlugInClientInfo *inClientInfo);
    OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inDeviceObjectID,
                                const AudioServerPlugInClientInfo *inClientInfo);
    OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                              AudioObjectID inDeviceObjectID,
                                              UInt64 inChangeAction,
                                              void *inChangeInfo);
    OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                            AudioObjectID inDeviceObjectID,
                                            UInt64 inChangeAction,
                                            void *inChangeInfo);
    Boolean HasProperty(AudioServerPlugInDriverRef inDriver,
                        AudioObjectID inObjectID,
                        pid_t inClientProcessID,
                        const AudioObjectPropertyAddress *inAddress);
    OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inObjectID,
                                pid_t inClientProcessID,
                                const AudioObjectPropertyAddress *inAddress,
                                Boolean *outIsSettable);
    OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                 AudioObjectID inObjectID,
                                 pid_t inClientProcessID,
                                 const AudioObjectPropertyAddress *inAddress,
                                 UInt32 inQualifierDataSize,
                                 const void *inQualifierData,
                                 UInt32 *outDataSize);
    OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver,
                             AudioObjectID inObjectID,
                             pid_t inClientProcessID,
                             const AudioObjectPropertyAddress *inAddress,
                             UInt32 inQualifierDataSize,
                             const void *inQualifierData,
                             UInt32 inDataSize,
                             UInt32 *outDataSize,
                             void *outData);
    OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver,
                             AudioObjectID inObjectID,
                             pid_t inClientProcessID,
                             const AudioObjectPropertyAddress *inAddress,
                             UInt32 inQualifierDataSize,
                             const void *inQualifierData,
                             UInt32 inDataSize,
                             const void *inData);
    OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
    OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
    OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inDeviceObjectID,
                              UInt32 inClientID,
                              Float64 *outSampleTime,
                              UInt64 *outHostTime,
                              UInt64 *outSeed);
    OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                               AudioObjectID inDeviceObjectID,
                               UInt32 inClientID,
                               UInt32 inOperationID,
                               Boolean *outWillDo,
                               Boolean *outWillDoInPlace);
    OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inDeviceObjectID,
                              UInt32 inClientID,
                              UInt32 inOperationID,
                              UInt32 inIOBufferFrameSize,
                              const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
    OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver,
                           AudioObjectID inDeviceObjectID,
                           AudioObjectID inStreamObjectID,
                           UInt32 inClientID,
                           UInt32 inOperationID,
                           UInt32 inIOBufferFrameSize,
                           const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                           void *ioMainBuffer,
                           void *ioSecondaryBuffer);
    OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver,
                            AudioObjectID inDeviceObjectID,
                            UInt32 inClientID,
                            UInt32 inOperationID,
                            UInt32 inIOBufferFrameSize,
                            const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

    Boolean HasPlugInProperty(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inObjectID,
                              pid_t inClientProcessID,
                              const AudioObjectPropertyAddress *inAddress);
    OSStatus IsPlugInPropertySettable(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress,
                                      Boolean *outIsSettable);
    OSStatus GetPlugInPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void *inQualifierData,
                                       UInt32 *outDataSize);
    OSStatus GetPlugInPropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   UInt32 *outDataSize,
                                   void *outData);
    OSStatus SetPlugInPropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   const void *inData,
                                   UInt32 *outNumberPropertiesChanged,
                                   AudioObjectPropertyAddress outChangedAddresses[2]);
    Boolean HasBoxProperty(AudioServerPlugInDriverRef inDriver,
                           AudioObjectID inObjectID,
                           pid_t inClientProcessID,
                           const AudioObjectPropertyAddress *inAddress);
    OSStatus IsBoxPropertySettable(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   Boolean *outIsSettable);
    OSStatus GetBoxPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID,
                                    pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 *outDataSize);
    OSStatus GetBoxPropertyData(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inObjectID,
                                pid_t inClientProcessID,
                                const AudioObjectPropertyAddress *inAddress,
                                UInt32 inQualifierDataSize,
                                const void *inQualifierData,
                                UInt32 inDataSize,
                                UInt32 *outDataSize,
                                void *outData);
    OSStatus SetBoxPropertyData(AudioServerPlugInDriverRef inDriver,
                                AudioObjectID inObjectID,
                                pid_t inClientProcessID,
                                const AudioObjectPropertyAddress *inAddress,
                                UInt32 inQualifierDataSize,
                                const void *inQualifierData,
                                UInt32 inDataSize,
                                const void *inData,
                                UInt32 *outNumberPropertiesChanged,
                                AudioObjectPropertyAddress outChangedAddresses[2]);

    Boolean HasDeviceProperty(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inObjectID,
                              pid_t inClientProcessID,
                              const AudioObjectPropertyAddress *inAddress);
    OSStatus IsDevicePropertySettable(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress,
                                      Boolean *outIsSettable);
    OSStatus GetDevicePropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void *inQualifierData,
                                       UInt32 *outDataSize);
    OSStatus GetDevicePropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   UInt32 *outDataSize,
                                   void *outData);
    OSStatus SetDevicePropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   const void *inData,
                                   UInt32 *outNumberPropertiesChanged,
                                   AudioObjectPropertyAddress outChangedAddresses[2]);
    Boolean HasStreamProperty(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inObjectID,
                              pid_t inClientProcessID,
                              const AudioObjectPropertyAddress *inAddress);
    OSStatus IsStreamPropertySettable(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inObjectID,
                                      pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress,
                                      Boolean *outIsSettable);
    OSStatus GetStreamPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void *inQualifierData,
                                       UInt32 *outDataSize);
    OSStatus GetStreamPropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   UInt32 *outDataSize,
                                   void *outData);
    OSStatus SetStreamPropertyData(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress,
                                   UInt32 inQualifierDataSize,
                                   const void *inQualifierData,
                                   UInt32 inDataSize,
                                   const void *inData,
                                   UInt32 *outNumberPropertiesChanged,
                                   AudioObjectPropertyAddress outChangedAddresses[2]);
    Boolean HasControlProperty(AudioServerPlugInDriverRef inDriver,
                               AudioObjectID inObjectID,
                               pid_t inClientProcessID,
                               const AudioObjectPropertyAddress *inAddress);
    OSStatus IsControlPropertySettable(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress,
                                       Boolean *outIsSettable);
    OSStatus GetControlPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inObjectID,
                                        pid_t inClientProcessID,
                                        const AudioObjectPropertyAddress *inAddress,
                                        UInt32 inQualifierDataSize,
                                        const void *inQualifierData,
                                        UInt32 *outDataSize);
    OSStatus GetControlPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID,
                                    pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 inDataSize,
                                    UInt32 *outDataSize,
                                    void *outData);
    OSStatus SetControlPropertyData(AudioServerPlugInDriverRef inDriver,
                                    AudioObjectID inObjectID,
                                    pid_t inClientProcessID,
                                    const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize,
                                    const void *inQualifierData,
                                    UInt32 inDataSize,
                                    const void *inData,
                                    UInt32 *outNumberPropertiesChanged,
                                    AudioObjectPropertyAddress outChangedAddresses[2]);
    dispatch_queue_t AudioOutputDispatchQueue();
    void ExecuteInAudioOutputThread(void (^block)());

    // Configuration and client state. Never taken on an audio thread.
    std::recursive_mutex stateMutex;
    dispatch_queue_t audioOutputQueue = NULL;
    dispatch_source_t engineSignalSource = NULL;

    // Audio path (lock-free; see NearfieldPlayback.h).
    nearfield::PlaybackEngine engine;
    nearfield::DeviceClock deviceClock;
    nearfield::RouteTable routeTable;
    nearfield::ClientRouteMixer routeMixer;
    nearfield::Diagnostics diagnostics;
    Float32 *renderBuffer = NULL;

    // Settings and clients (stateMutex).
    nearfield::DriverSettings settings;
    std::map<pid_t, nearfield::Route> processRoutes;
    std::map<std::string, nearfield::Route> bundleRoutes;
    std::map<UInt32, ClientInfo> clientsByID;
    CFDictionaryRef lastPersistedSettings = NULL;
    CFStringRef boxName = NULL;
    pid_t configuratorPid = 0;
    std::atomic<int> nextConfigurationToRead{0};
    std::map<pid_t, std::pair<UInt64, bool>> verifiedWriters;
    std::string writerVerification = "unchecked";
    std::once_flag teamIdentifierOnce;
    CFStringRef ownTeamIdentifier = NULL;

    // Target output (driver queue). Audio threads never touch these.
    AudioDevice outputDevice;
    bool outputDeviceReady = false;
    AudioObjectID targetAggregateID = kAudioObjectUnknown;
    bool outputIsAggregate = false;
    UInt64 outputStopToken = 0;
    UInt64 hideToken = 0;
    int sampleRateRetryCount = 0;
    UInt64 sampleRateRetryToken = 0;
    int outputSetupRetryCount = 0;
    UInt64 outputSetupRetryToken = 0;
    AudioObjectID outputSetupRetryDeviceID = kAudioObjectUnknown;
    Float64 requestedOutputSampleRate = 0;
    bool devicesListenerInstalled = false;
    UInt64 initializedHostTime = 0;
    // Tests turn this off so the driver never builds aggregates, opens
    // devices or registers listeners through Core Audio.
    bool manageOutputDevice = true;

    // Readiness and presence, published for property reads.
    UInt64 targetConfigurationRevision = 1;  // stateMutex
    std::atomic<UInt64> appliedTargetConfigurationRevision{0};
    std::atomic<UInt64> readyTargetConfigurationRevision{0};
    std::atomic<int> presentTargetDisplays{-1};
    std::atomic<bool> displaysHidden{false};
    std::atomic<bool> outputRunning{false};
    std::atomic<UInt32> reportedLatencyFrames{0};
    std::atomic<UInt64> statusGeneration{0};
    std::atomic<bool> statusNotificationScheduled{false};
    std::atomic<double> lastColdStartMilliseconds{0};
    uint64_t reportedDroppedDiagnostics = 0;

    UInt32 gPlugIn_RefCount = 0;
    AudioServerPlugInHostRef gPlugIn_Host = NULL;
    Boolean gBox_Acquired = true;
    static_assert(__atomic_always_lock_free(sizeof(Float64), nullptr), "Sample rate must be lock-free");
    static_assert(__atomic_always_lock_free(sizeof(Float32), nullptr), "Volume must be lock-free");
    static_assert(__atomic_always_lock_free(sizeof(bool), nullptr), "Mute must be lock-free");
    std::atomic<Float64> gDevice_SampleRate{48000.0};
    UInt64 gDevice_IOIsRunning = 0;
    const UInt32 kDevice_ZeroTimeStampPeriod = 16384;
    bool gStream_Output_IsActive = true;
    const Float32 kVolume_MinDB = -63.5;
    const Float32 kVolume_MaxDB = 0.0;
    std::atomic<Float32> gVolume_Output_L_Value{1.0};
    std::atomic<Float32> gVolume_Output_R_Value{1.0};
    std::atomic<bool> gMute_Output_Mute{false};
    const UInt32 gDevice_BytesPerFrameInChannel = 4;
    const UInt32 gDevice_ChannelsPerFrame = 2;
    const UInt32 gDevice_SafetyOffset = 0;
};

extern "C" void *ProxyAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

#endif /* ProxyAudioDevice_h */
