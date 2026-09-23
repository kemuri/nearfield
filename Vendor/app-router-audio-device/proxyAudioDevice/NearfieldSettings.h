#ifndef NearfieldSettings_h
#define NearfieldSettings_h

// The driver's configuration, exchanged with Nearfield as a CFDictionary on
// the box's settings property and persisted in the plug-in's storage.
//
// Keys (all optional in an update; an update applies in one step):
//   deviceName              string
//   targetDevices           array of device UIDs (2 or 3, left to right)
//   targetMode              "stereo" | "mono"
//   routingEnabled          boolean
//   routeRules              "bundle.id=left; other.id=right" (saved)
//   processRoutes           { "<pid>": "left" | "right" | "pair" | "muted" } (never saved)
//   outputBufferFrameSize   number
//   underrunStrategy        "both" | "steer" | "gap"
//   safetyGapMilliseconds   number
//   diagnostics             boolean

#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <map>
#include <optional>
#include <string>
#include <sys/types.h>
#include <vector>

#include "NearfieldRouteTable.h"

namespace nearfield {

inline const CFStringRef kSettingsVersionKey = CFSTR("version");
inline const CFStringRef kSettingsDeviceNameKey = CFSTR("deviceName");
inline const CFStringRef kSettingsTargetDevicesKey = CFSTR("targetDevices");
inline const CFStringRef kSettingsTargetModeKey = CFSTR("targetMode");
inline const CFStringRef kSettingsRoutingEnabledKey = CFSTR("routingEnabled");
inline const CFStringRef kSettingsRouteRulesKey = CFSTR("routeRules");
inline const CFStringRef kSettingsProcessRoutesKey = CFSTR("processRoutes");
inline const CFStringRef kSettingsOutputBufferFrameSizeKey = CFSTR("outputBufferFrameSize");
inline const CFStringRef kSettingsUnderrunStrategyKey = CFSTR("underrunStrategy");
inline const CFStringRef kSettingsSafetyGapKey = CFSTR("safetyGapMilliseconds");
inline const CFStringRef kSettingsDiagnosticsKey = CFSTR("diagnostics");
inline const CFStringRef kSettingsSampleRateKey = CFSTR("sampleRate");
inline const CFStringRef kSettingsAvailableSampleRatesKey = CFSTR("availableSampleRates");
inline const CFStringRef kSettingsOutputDeviceKey = CFSTR("outputDevice");
inline const CFStringRef kSettingsActiveConditionKey = CFSTR("activeCondition");

constexpr int kSettingsVersion = 1;
constexpr uint32_t kDefaultOutputBufferFrameSize = 512;
constexpr uint32_t kMinimumOutputBufferFrameSize = 32;
constexpr uint32_t kMaximumOutputBufferFrameSize = 4096;

enum class UnderrunStrategy { both, steer, gap };

inline const char *underrunStrategyName(UnderrunStrategy strategy) {
    switch (strategy) {
        case UnderrunStrategy::steer: return "steer";
        case UnderrunStrategy::gap: return "gap";
        case UnderrunStrategy::both:
        default: return "both";
    }
}

inline std::string trimmed(std::string value) {
    auto isSpace = [](unsigned char c) { return std::isspace(c) != 0; };
    value.erase(value.begin(), std::find_if(value.begin(), value.end(), [&](unsigned char c) { return !isSpace(c); }));
    value.erase(std::find_if(value.rbegin(), value.rend(), [&](unsigned char c) { return !isSpace(c); }).base(), value.end());
    return value;
}

inline std::string lowercased(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

inline std::string stringFromCF(CFStringRef value) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return std::string();
    }
    const char *fast = CFStringGetCStringPtr(value, kCFStringEncodingUTF8);
    if (fast) {
        return std::string(fast);
    }
    const CFIndex length = CFStringGetMaximumSizeForEncoding(CFStringGetLength(value), kCFStringEncodingUTF8) + 1;
    std::string buffer(static_cast<size_t>(length), '\0');
    if (!CFStringGetCString(value, &buffer[0], length, kCFStringEncodingUTF8)) {
        return std::string();
    }
    buffer.resize(std::strlen(buffer.c_str()));
    return buffer;
}

inline CFStringRef createCFString(const std::string &value) {
    return CFStringCreateWithCString(kCFAllocatorDefault, value.c_str(), kCFStringEncodingUTF8);
}

inline bool routeFromString(const std::string &value, Route &route) {
    const std::string normalized = lowercased(trimmed(value));
    if (normalized == "pair" || normalized == "default") {
        route = Route::pair;
        return true;
    }
    if (normalized == "left" || normalized == "left-display") {
        route = Route::left;
        return true;
    }
    if (normalized == "right" || normalized == "right-display") {
        route = Route::right;
        return true;
    }
    if (normalized == "muted" || normalized == "mute" || normalized == "none") {
        route = Route::muted;
        return true;
    }
    return false;
}

struct ParsedRouteRules {
    std::map<std::string, Route> bundleRoutes;
    std::map<pid_t, Route> processRoutes;
    // The bundle rules alone, normalized, for saving.
    std::string persistentRules;
};

// Accepts "bundle.id=left; pid:123=right" separated by ';' or newlines.
inline ParsedRouteRules parseRouteRules(const std::string &rules) {
    ParsedRouteRules parsed;
    size_t offset = 0;
    while (offset < rules.size()) {
        const size_t separator = rules.find_first_of(";\n", offset);
        const std::string rule = rules.substr(offset, separator == std::string::npos ? std::string::npos : separator - offset);
        offset = separator == std::string::npos ? rules.size() : separator + 1;

        const size_t equals = rule.find('=');
        if (equals == std::string::npos) {
            continue;
        }
        const std::string key = trimmed(rule.substr(0, equals));
        Route route = Route::pair;
        if (key.empty() || !routeFromString(rule.substr(equals + 1), route)) {
            continue;
        }
        const std::string normalizedKey = lowercased(key);
        if (normalizedKey.rfind("pid:", 0) == 0) {
            char *end = nullptr;
            const long processID = std::strtol(normalizedKey.c_str() + 4, &end, 10);
            if (end && *end == '\0' && processID > 0) {
                parsed.processRoutes[static_cast<pid_t>(processID)] = route;
            }
            continue;
        }
        parsed.bundleRoutes[key] = route;
        if (!parsed.persistentRules.empty()) {
            parsed.persistentRules += "; ";
        }
        parsed.persistentRules += key + "=" + routeName(route);
    }
    return parsed;
}

struct DriverSettings {
    std::string deviceName = "Nearfield";
    std::vector<std::string> targetDevices;
    bool stereo = true;
    bool routingEnabled = false;
    std::string routeRules;
    uint32_t outputBufferFrameSize = kDefaultOutputBufferFrameSize;
    UnderrunStrategy underrunStrategy = UnderrunStrategy::both;
    double safetyGapMilliseconds = 3.0;
    bool diagnostics = false;
    double sampleRate = 0;
    std::vector<double> availableSampleRates;
    // Legacy: an explicit output device used before targets are configured.
    std::string outputDeviceUID;
    int activeCondition = 0;
};

struct SettingsUpdate {
    std::optional<std::string> deviceName;
    std::optional<std::vector<std::string>> targetDevices;
    std::optional<bool> stereo;
    std::optional<bool> routingEnabled;
    std::optional<std::string> routeRules;
    std::optional<std::map<pid_t, Route>> processRoutes;
    std::optional<uint32_t> outputBufferFrameSize;
    std::optional<UnderrunStrategy> underrunStrategy;
    std::optional<double> safetyGapMilliseconds;
    std::optional<bool> diagnostics;
    std::optional<std::string> outputDeviceUID;
    std::optional<int> activeCondition;

    bool isEmpty() const {
        return !deviceName && !targetDevices && !stereo && !routingEnabled && !routeRules && !processRoutes &&
               !outputBufferFrameSize && !underrunStrategy && !safetyGapMilliseconds && !diagnostics &&
               !outputDeviceUID && !activeCondition;
    }
};

inline bool booleanFromCF(CFTypeRef value, bool &result) {
    if (!value) {
        return false;
    }
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue(static_cast<CFBooleanRef>(value));
        return true;
    }
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 0;
        CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberIntType, &number);
        result = number != 0;
        return true;
    }
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        const std::string text = lowercased(trimmed(stringFromCF(static_cast<CFStringRef>(value))));
        result = text == "1" || text == "true" || text == "yes";
        return true;
    }
    return false;
}

inline bool doubleFromCF(CFTypeRef value, double &result) {
    if (!value) {
        return false;
    }
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        return CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberDoubleType, &result);
    }
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        const std::string text = trimmed(stringFromCF(static_cast<CFStringRef>(value)));
        char *end = nullptr;
        result = std::strtod(text.c_str(), &end);
        return !text.empty() && end && *end == '\0';
    }
    return false;
}

inline bool stringFromCFValue(CFTypeRef value, std::string &result) {
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return false;
    }
    result = stringFromCF(static_cast<CFStringRef>(value));
    return true;
}

inline std::vector<std::string> splitDeviceUIDs(const std::string &raw) {
    std::vector<std::string> result;
    size_t offset = 0;
    while (offset < raw.size()) {
        const size_t separator = raw.find_first_of("\n|", offset);
        const std::string item = trimmed(raw.substr(offset, separator == std::string::npos ? std::string::npos : separator - offset));
        offset = separator == std::string::npos ? raw.size() : separator + 1;
        if (!item.empty()) {
            result.push_back(item);
        }
    }
    return result;
}

// Parses an update from Nearfield. Unknown keys are ignored; invalid values
// make the whole update invalid so nothing is half-applied.
inline bool parseSettingsUpdate(CFDictionaryRef dictionary, SettingsUpdate &update) {
    if (!dictionary || CFGetTypeID(dictionary) != CFDictionaryGetTypeID()) {
        return false;
    }
    CFTypeRef value = nullptr;
    std::string text;
    if ((value = CFDictionaryGetValue(dictionary, kSettingsDeviceNameKey))) {
        if (!stringFromCFValue(value, text) || trimmed(text).empty()) return false;
        update.deviceName = text;
    }
    if ((value = CFDictionaryGetValue(dictionary, kSettingsTargetDevicesKey))) {
        std::vector<std::string> devices;
        if (CFGetTypeID(value) == CFArrayGetTypeID()) {
            CFArrayRef array = static_cast<CFArrayRef>(value);
            for (CFIndex index = 0; index < CFArrayGetCount(array); ++index) {
                if (!stringFromCFValue(CFArrayGetValueAtIndex(array, index), text)) return false;
                if (!trimmed(text).empty()) devices.push_back(trimmed(text));
            }
        } else if (stringFromCFValue(value, text)) {
            devices = splitDeviceUIDs(text);
        } else {
            return false;
        }
        if (devices.size() > 3) devices.resize(3);
        update.targetDevices = devices;
    }
    if ((value = CFDictionaryGetValue(dictionary, kSettingsTargetModeKey))) {
        if (!stringFromCFValue(value, text)) return false;
        update.stereo = lowercased(trimmed(text)) != "mono";
    }
    if ((value = CFDictionaryGetValue(dictionary, kSettingsRoutingEnabledKey))) {
        bool enabled = false;
        if (!booleanFromCF(value, enabled)) return false;
        update.routingEnabled = enabled;
    }
    if ((value = CFDictionaryGetValue(dictionary, kSettingsRouteRulesKey))) {
        if (!stringFromCFValue(value, text)) return false;
        const ParsedRouteRules parsed = parseRouteRules(text);
        update.routeRules = parsed.persistentRules;
        // Process rules in the rules string are the legacy way to send them.
        if (!parsed.processRoutes.empty()) {
            update.processRoutes = parsed.processRoutes;
        }
    }
    if ((value = CFDictionaryGetValue(dictionary, kSettingsProcessRoutesKey))) {
        if (CFGetTypeID(value) != CFDictionaryGetTypeID()) return false;
        CFDictionaryRef routes = static_cast<CFDictionaryRef>(value);
        const CFIndex count = CFDictionaryGetCount(routes);
        std::vector<const void *> keys(static_cast<size_t>(count));
        std::vector<const void *> values(static_cast<size_t>(count));
        if (count > 0) CFDictionaryGetKeysAndValues(routes, keys.data(), values.data());
        std::map<pid_t, Route> processRoutes;
        for (CFIndex index = 0; index < count; ++index) {
            double processID = 0;
            Route route = Route::pair;
            std::string destination;
            if (!doubleFromCF(static_cast<CFTypeRef>(keys[static_cast<size_t>(index)]), processID) || processID <= 0 ||
                !stringFromCFValue(static_cast<CFTypeRef>(values[static_cast<size_t>(index)]), destination) ||
                !routeFromString(destination, route)) {
                return false;
            }
            processRoutes[static_cast<pid_t>(processID)] = route;
        }
        update.processRoutes = processRoutes;
    }
    if ((value = CFDictionaryGetValue(dictionary, kSettingsOutputBufferFrameSizeKey))) {
        double frames = 0;
        if (!doubleFromCF(value, frames)) return false;
        update.outputBufferFrameSize = static_cast<uint32_t>(std::clamp(frames, double(kMinimumOutputBufferFrameSize),
                                                                        double(kMaximumOutputBufferFrameSize)));
    }
    if ((value = CFDictionaryGetValue(dictionary, kSettingsUnderrunStrategyKey))) {
        if (!stringFromCFValue(value, text)) return false;
        const std::string strategy = lowercased(trimmed(text));
        if (strategy == "steer") update.underrunStrategy = UnderrunStrategy::steer;
        else if (strategy == "gap") update.underrunStrategy = UnderrunStrategy::gap;
        else if (strategy == "both") update.underrunStrategy = UnderrunStrategy::both;
        else return false;
    }
    if ((value = CFDictionaryGetValue(dictionary, kSettingsSafetyGapKey))) {
        double milliseconds = 0;
        if (!doubleFromCF(value, milliseconds) || milliseconds < 0 || milliseconds > 100) return false;
        update.safetyGapMilliseconds = milliseconds;
    }
    if ((value = CFDictionaryGetValue(dictionary, kSettingsDiagnosticsKey))) {
        bool enabled = false;
        if (!booleanFromCF(value, enabled)) return false;
        update.diagnostics = enabled;
    }
    if ((value = CFDictionaryGetValue(dictionary, kSettingsOutputDeviceKey))) {
        if (!stringFromCFValue(value, text)) return false;
        update.outputDeviceUID = trimmed(text);
    }
    if ((value = CFDictionaryGetValue(dictionary, kSettingsActiveConditionKey))) {
        double condition = 0;
        if (!doubleFromCF(value, condition)) return false;
        update.activeCondition = static_cast<int>(condition);
    }
    return true;
}

enum SettingsChange : uint32_t {
    kChangedDeviceName = 1u << 0,
    kChangedTargets = 1u << 1,
    kChangedRouting = 1u << 2,
    kChangedProcessRoutes = 1u << 3,
    kChangedOutputBuffer = 1u << 4,
    kChangedPlayback = 1u << 5,
    kChangedDiagnostics = 1u << 6,
    kChangedOutputDevice = 1u << 7,
};

// Applies |update| to |settings| and returns what changed.
inline uint32_t applySettingsUpdate(DriverSettings &settings, std::map<pid_t, Route> &processRoutes,
                                    const SettingsUpdate &update) {
    uint32_t changes = 0;
    if (update.deviceName && *update.deviceName != settings.deviceName) {
        settings.deviceName = *update.deviceName;
        changes |= kChangedDeviceName;
    }
    if (update.targetDevices && *update.targetDevices != settings.targetDevices) {
        settings.targetDevices = *update.targetDevices;
        changes |= kChangedTargets;
    }
    if (update.stereo && *update.stereo != settings.stereo) {
        settings.stereo = *update.stereo;
        changes |= kChangedTargets;
    }
    if (update.routingEnabled && *update.routingEnabled != settings.routingEnabled) {
        settings.routingEnabled = *update.routingEnabled;
        changes |= kChangedRouting;
    }
    if (update.routeRules && *update.routeRules != settings.routeRules) {
        settings.routeRules = *update.routeRules;
        changes |= kChangedRouting;
    }
    if (update.processRoutes && *update.processRoutes != processRoutes) {
        processRoutes = *update.processRoutes;
        changes |= kChangedProcessRoutes;
    }
    if (update.outputBufferFrameSize && *update.outputBufferFrameSize != settings.outputBufferFrameSize) {
        settings.outputBufferFrameSize = *update.outputBufferFrameSize;
        changes |= kChangedOutputBuffer;
    }
    if (update.underrunStrategy && *update.underrunStrategy != settings.underrunStrategy) {
        settings.underrunStrategy = *update.underrunStrategy;
        changes |= kChangedPlayback;
    }
    if (update.safetyGapMilliseconds && *update.safetyGapMilliseconds != settings.safetyGapMilliseconds) {
        settings.safetyGapMilliseconds = *update.safetyGapMilliseconds;
        changes |= kChangedPlayback;
    }
    if (update.diagnostics && *update.diagnostics != settings.diagnostics) {
        settings.diagnostics = *update.diagnostics;
        changes |= kChangedDiagnostics;
    }
    if (update.outputDeviceUID && *update.outputDeviceUID != settings.outputDeviceUID) {
        settings.outputDeviceUID = *update.outputDeviceUID;
        changes |= kChangedOutputDevice;
    }
    if (update.activeCondition && *update.activeCondition != settings.activeCondition) {
        settings.activeCondition = *update.activeCondition;
    }
    return changes;
}

inline void setDictionaryString(CFMutableDictionaryRef dictionary, CFStringRef key, const std::string &value) {
    CFStringRef string = createCFString(value);
    if (string) {
        CFDictionarySetValue(dictionary, key, string);
        CFRelease(string);
    }
}

inline void setDictionaryNumber(CFMutableDictionaryRef dictionary, CFStringRef key, double value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
    if (number) {
        CFDictionarySetValue(dictionary, key, number);
        CFRelease(number);
    }
}

inline void setDictionaryInteger(CFMutableDictionaryRef dictionary, CFStringRef key, int64_t value) {
    CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &value);
    if (number) {
        CFDictionarySetValue(dictionary, key, number);
        CFRelease(number);
    }
}

inline void setDictionaryStrings(CFMutableDictionaryRef dictionary, CFStringRef key, const std::vector<std::string> &values) {
    CFMutableArrayRef array = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (!array) return;
    for (const std::string &value : values) {
        CFStringRef string = createCFString(value);
        if (string) {
            CFArrayAppendValue(array, string);
            CFRelease(string);
        }
    }
    CFDictionarySetValue(dictionary, key, array);
    CFRelease(array);
}

inline void setDictionaryNumbers(CFMutableDictionaryRef dictionary, CFStringRef key, const std::vector<double> &values) {
    CFMutableArrayRef array = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    if (!array) return;
    for (double value : values) {
        CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
        if (number) {
            CFArrayAppendValue(array, number);
            CFRelease(number);
        }
    }
    CFDictionarySetValue(dictionary, key, array);
    CFRelease(array);
}

// The saved form. Process routes are deliberately left out: process IDs do
// not survive a restart.
inline CFDictionaryRef createPersistentSettings(const DriverSettings &settings) {
    CFMutableDictionaryRef dictionary =
        CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (!dictionary) return nullptr;
    setDictionaryInteger(dictionary, kSettingsVersionKey, kSettingsVersion);
    setDictionaryString(dictionary, kSettingsDeviceNameKey, settings.deviceName);
    setDictionaryStrings(dictionary, kSettingsTargetDevicesKey, settings.targetDevices);
    setDictionaryString(dictionary, kSettingsTargetModeKey, settings.stereo ? "stereo" : "mono");
    CFDictionarySetValue(dictionary, kSettingsRoutingEnabledKey, settings.routingEnabled ? kCFBooleanTrue : kCFBooleanFalse);
    setDictionaryString(dictionary, kSettingsRouteRulesKey, settings.routeRules);
    setDictionaryInteger(dictionary, kSettingsOutputBufferFrameSizeKey, settings.outputBufferFrameSize);
    setDictionaryString(dictionary, kSettingsUnderrunStrategyKey, underrunStrategyName(settings.underrunStrategy));
    setDictionaryNumber(dictionary, kSettingsSafetyGapKey, settings.safetyGapMilliseconds);
    CFDictionarySetValue(dictionary, kSettingsDiagnosticsKey, settings.diagnostics ? kCFBooleanTrue : kCFBooleanFalse);
    if (settings.sampleRate > 0) {
        setDictionaryNumber(dictionary, kSettingsSampleRateKey, settings.sampleRate);
    }
    if (!settings.availableSampleRates.empty()) {
        setDictionaryNumbers(dictionary, kSettingsAvailableSampleRatesKey, settings.availableSampleRates);
    }
    if (!settings.outputDeviceUID.empty()) {
        setDictionaryString(dictionary, kSettingsOutputDeviceKey, settings.outputDeviceUID);
    }
    setDictionaryInteger(dictionary, kSettingsActiveConditionKey, settings.activeCondition);
    return dictionary;
}

// Restores saved settings. Returns false when |dictionary| is not a settings
// dictionary, so the caller can migrate the legacy keys instead.
inline bool loadPersistentSettings(CFPropertyListRef propertyList, DriverSettings &settings) {
    if (!propertyList || CFGetTypeID(propertyList) != CFDictionaryGetTypeID()) {
        return false;
    }
    CFDictionaryRef dictionary = static_cast<CFDictionaryRef>(propertyList);
    SettingsUpdate update;
    CFMutableDictionaryRef filtered = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dictionary);
    if (!filtered) return false;
    // Saved settings never contain process routes.
    CFDictionaryRemoveValue(filtered, kSettingsProcessRoutesKey);
    const bool parsed = parseSettingsUpdate(filtered, update);
    CFRelease(filtered);
    if (!parsed) {
        return false;
    }
    std::map<pid_t, Route> ignoredProcessRoutes;
    applySettingsUpdate(settings, ignoredProcessRoutes, update);
    double rate = 0;
    if (doubleFromCF(CFDictionaryGetValue(dictionary, kSettingsSampleRateKey), rate) && rate > 0) {
        settings.sampleRate = rate;
    }
    CFTypeRef rates = CFDictionaryGetValue(dictionary, kSettingsAvailableSampleRatesKey);
    if (rates && CFGetTypeID(rates) == CFArrayGetTypeID()) {
        std::vector<double> values;
        for (CFIndex index = 0; index < CFArrayGetCount(static_cast<CFArrayRef>(rates)); ++index) {
            double value = 0;
            if (doubleFromCF(CFArrayGetValueAtIndex(static_cast<CFArrayRef>(rates), index), value) && value > 0) {
                values.push_back(value);
            }
        }
        settings.availableSampleRates = values;
    }
    return true;
}

} // namespace nearfield

#endif /* NearfieldSettings_h */
