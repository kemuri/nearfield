#ifndef NearfieldPlayback_h
#define NearfieldPlayback_h

// The audio path between the Nearfield device (written by the HAL's IO thread)
// and the Studio Displays' output device (read by its IOProc).
//
// Threads:
// - Writer: the HAL IO thread of the Nearfield device (WriteMix).
// - Reader: the output device's IOProc.
// - Control: the driver's queue and HAL property threads.
//
// The writer and reader never lock, allocate or log. They share a
// single-producer/single-consumer ring addressed by a monotonic stream
// position, so audio from consecutive client sessions is appended without
// gaps. Storage is replaced only by the control thread, which retires the old
// storage after both audio threads have left it (hazard pointers).

#include <CoreAudio/CoreAudioTypes.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <mach/mach_time.h>
#include <sched.h>
#include <unistd.h>

#include "NearfieldDiagnostics.h"

namespace nearfield {

constexpr uint32_t kStreamChannels = 2;
// Buffering held for cold starts: the displays' output device can take a
// while to start, and the start of a sound is played once it runs.
constexpr double kRingSeconds = 2.0;
constexpr uint32_t kMaxRenderFrames = 8192;
constexpr double kFadeMilliseconds = 2.5;
constexpr double kGainRampMilliseconds = 5.0;
constexpr double kRouteCrossfadeMilliseconds = 10.0;
constexpr double kDefaultSafetyGapMilliseconds = 3.0;
constexpr double kSafetyGapStepMilliseconds = 4.0;
constexpr double kMaxExtraSafetyGapMilliseconds = 40.0;
constexpr double kSafetyGapDecaySeconds = 60.0;
constexpr double kMinimumTrimMilliseconds = 5.0;
// About -90 dBFS: treat as silence when trimming excess delay.
constexpr float kSilenceThreshold = 3.2e-5f;
constexpr double kRateEstimateSeconds = 4.0;
constexpr double kFillAverageSeconds = 2.0;
constexpr double kSteeringSettleSeconds = 1.0;
constexpr double kMaxSteeringPPM = 300.0;
constexpr double kLatencyAverageSeconds = 1.0;

static_assert(std::atomic<double>::is_always_lock_free, "The audio threads require lock-free doubles");
static_assert(std::atomic<int64_t>::is_always_lock_free, "The audio threads require lock-free positions");

inline uint32_t ringCapacityForSampleRate(double sampleRate) {
    const double frames = std::max(1.0, sampleRate) * kRingSeconds;
    uint32_t capacity = 1u << 12;
    while (capacity < frames && capacity < (1u << 22)) {
        capacity <<= 1;
    }
    return capacity;
}

enum PlaybackSignal : uintptr_t {
    kSignalLatency = 1u << 0,
    kSignalCounters = 1u << 1,
    kSignalDrained = 1u << 2,
    kSignalOutputStarted = 1u << 3,
    kSignalDiagnostics = 1u << 4,
};

using PlaybackSignalFunction = void (*)(void *context, uintptr_t signals);

struct RingStorage {
    explicit RingStorage(uint32_t capacityFrames)
        : samples(new float[static_cast<size_t>(capacityFrames) * kStreamChannels]()),
          capacity(capacityFrames),
          mask(capacityFrames - 1) {}
    ~RingStorage() { delete[] samples; }
    RingStorage(const RingStorage &) = delete;
    RingStorage &operator=(const RingStorage &) = delete;

    float *const samples;
    const uint32_t capacity;
    const uint32_t mask;

    // One past the last frame the writer published.
    std::atomic<int64_t> writeEnd{0};

    // The writer's timeline at writeEnd, published under a sequence lock so the
    // reader gets a consistent pair.
    std::atomic<uint32_t> stampSequence{0};
    std::atomic<int64_t> stampEnd{0};
    std::atomic<uint64_t> stampEndHostTime{0};
    std::atomic<int64_t> stampSessionBase{0};
    std::atomic<double> stampTicksPerFrame{0};
};

struct PlaybackCounters {
    std::atomic<uint64_t> underruns{0};
    // Reads that left less than a fade buffered and faded out early.
    std::atomic<uint64_t> nearUnderruns{0};
    std::atomic<uint64_t> overruns{0};
    std::atomic<uint64_t> coldStarts{0};
    std::atomic<uint64_t> trimmedFrames{0};
    std::atomic<uint64_t> writerGaps{0};
    std::atomic<uint64_t> lastColdStartBufferedFrames{0};
    std::atomic<uint64_t> readerCallbacks{0};
    std::atomic<uint64_t> writerCallbacks{0};
};

class PlaybackEngine {
  public:
    PlaybackEngine() = default;
    ~PlaybackEngine() { delete storage.load(); }
    PlaybackEngine(const PlaybackEngine &) = delete;
    PlaybackEngine &operator=(const PlaybackEngine &) = delete;

    // MARK: Control (non-real-time)

    void setSignalHandler(PlaybackSignalFunction function, void *context) {
        signalFunction = function;
        signalContext = context;
    }

    void setDiagnostics(Diagnostics *value) { diagnostics = value; }

    // Replaces the ring with an empty one sized for |sampleRate|. Audio
    // threads keep running; they switch to the new storage on their next
    // callback. Buffered audio at the previous rate is discarded.
    void configure(double sampleRate) {
        const uint32_t capacity = ringCapacityForSampleRate(sampleRate);
        deviceSampleRate.store(sampleRate, std::memory_order_relaxed);
        RingStorage *replacement = new RingStorage(capacity);
        RingStorage *previous = storage.exchange(replacement, std::memory_order_seq_cst);
        // Positions restart at zero in the new storage.
        readerPublishedPosition.store(0, std::memory_order_release);
        retire(previous);
    }

    void setDeviceSampleRate(double sampleRate) { deviceSampleRate.store(sampleRate, std::memory_order_relaxed); }
    double currentDeviceSampleRate() const { return deviceSampleRate.load(std::memory_order_relaxed); }

    void setOutputFormat(double sampleRate, uint32_t bufferFrames, uint32_t latencyFrames) {
        outputSampleRate.store(sampleRate, std::memory_order_relaxed);
        outputBufferFrames.store(bufferFrames, std::memory_order_relaxed);
        outputLatencyFrames.store(latencyFrames, std::memory_order_relaxed);
    }

    void setStrategy(bool steerClock, bool adaptiveSafetyGap) {
        steeringEnabled.store(steerClock, std::memory_order_relaxed);
        adaptiveGapEnabled.store(adaptiveSafetyGap, std::memory_order_relaxed);
    }

    void setBaseSafetyGapMilliseconds(double milliseconds) {
        baseSafetyGapMilliseconds.store(std::max(0.0, milliseconds), std::memory_order_relaxed);
    }

    // The first client started IO: its audio starts a new session that is
    // appended after anything still waiting to play.
    void beginClientSession() {
        sessionRequests.fetch_add(1, std::memory_order_acq_rel);
        clientsActive.store(true, std::memory_order_release);
    }

    // The last client stopped IO. The reader drains what is buffered.
    void endClientSession() { clientsActive.store(false, std::memory_order_release); }

    bool hasActiveClients() const { return clientsActive.load(std::memory_order_acquire); }

    // Called before the output device starts, so the reader skips audio from
    // sessions that ended while it was stopped.
    void noteOutputStarting() {
        outputStartRequestHostTime.store(mach_absolute_time(), std::memory_order_relaxed);
        outputStarting.store(true, std::memory_order_release);
    }

    // True when nothing is waiting to be played and no client is running.
    bool isDrained() const {
        if (hasActiveClients()) {
            return false;
        }
        RingStorage *ring = storage.load(std::memory_order_acquire);
        if (!ring) {
            return true;
        }
        return readerPublishedPosition.load(std::memory_order_acquire) >= ring->writeEnd.load(std::memory_order_acquire);
    }

    double clockRatio() const { return clockRatioValue.load(std::memory_order_relaxed); }
    int64_t readerPosition() const { return readerPublishedPosition.load(std::memory_order_acquire); }
    int64_t writtenEnd() const {
        RingStorage *ring = storage.load(std::memory_order_acquire);
        return ring ? ring->writeEnd.load(std::memory_order_acquire) : 0;
    }
    double rateScalarEstimate() const { return rateScalarValue.load(std::memory_order_relaxed); }
    double steeringPPM() const { return steeringPPMValue.load(std::memory_order_relaxed); }
    double measuredLatencyFrames() const { return measuredLatency.load(std::memory_order_relaxed); }
    double currentSafetyGapMilliseconds() const {
        return baseSafetyGapMilliseconds.load(std::memory_order_relaxed) +
               extraSafetyGapPublished.load(std::memory_order_relaxed);
    }
    double lastBufferedMilliseconds() const { return bufferedMilliseconds.load(std::memory_order_relaxed); }
    double currentOutputSampleRate() const { return outputSampleRate.load(std::memory_order_relaxed); }
    // What the latency will be before it can be measured: the buffering
    // target plus the output device's own latency.
    double estimatedLatencyFrames() const {
        const double rate = deviceSampleRate.load(std::memory_order_relaxed);
        return lastWriterFrames.load(std::memory_order_relaxed) + outputBufferFrames.load(std::memory_order_relaxed) +
               (currentSafetyGapMilliseconds() * rate / 1000.0) + outputLatencyFrames.load(std::memory_order_relaxed);
    }
    uint64_t outputStartRequestTime() const { return outputStartRequestHostTime.load(std::memory_order_relaxed); }
    uint64_t firstOutputCallbackTime() const { return firstOutputCallbackHostTime.load(std::memory_order_relaxed); }
    const PlaybackCounters &counters() const { return stats; }
    uint32_t crossfadeFrames() const {
        return static_cast<uint32_t>(kRouteCrossfadeMilliseconds * deviceSampleRate.load(std::memory_order_relaxed) / 1000.0);
    }

    // MARK: Writer (IO thread of the Nearfield device)

    void write(const float *interleaved, uint32_t frames, double sampleTime, uint64_t hostTime,
               double hostTicksPerFrame, uint64_t callbackLatenessTicks = 0) noexcept {
        RingStorage *ring = acquire(writerHazard);
        if (!ring || frames == 0) {
            writerHazard.store(nullptr, std::memory_order_release);
            return;
        }
        stats.writerCallbacks.fetch_add(1, std::memory_order_relaxed);
        noteWriterWindow(frames, callbackLatenessTicks);
        if (ring != writerRing) {
            writerRing = ring;
            writerEnd = ring->writeEnd.load(std::memory_order_relaxed);
            writerHasSession = false;
        }
        frames = std::min(frames, ring->capacity / 2);
        const int64_t frame = static_cast<int64_t>(std::llround(sampleTime));
        const uint64_t request = sessionRequests.load(std::memory_order_acquire);
        bool newSession = !writerHasSession || request != writerSessionRequest || frame < writerNextFrame;
        if (!newSession && frame > writerNextFrame) {
            const int64_t missing = frame - writerNextFrame;
            if (missing >= static_cast<int64_t>(ring->capacity / 2)) {
                newSession = true;
            } else {
                // Keep the timeline: frames the HAL skipped play as silence.
                zero(ring, writerEnd, static_cast<uint32_t>(missing));
                writerEnd += missing;
                stats.writerGaps.fetch_add(1, std::memory_order_relaxed);
            }
        }
        if (newSession) {
            writerHasSession = true;
            writerSessionRequest = request;
            writerSessionBase = writerEnd;
        }
        copyIn(ring, writerEnd, interleaved, frames);
        writerEnd += frames;
        writerNextFrame = frame + frames;
        lastWriterFrames.store(frames, std::memory_order_relaxed);

        const uint32_t sequence = ring->stampSequence.load(std::memory_order_relaxed);
        ring->stampSequence.store(sequence + 1, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);
        ring->stampEnd.store(writerEnd, std::memory_order_relaxed);
        ring->stampEndHostTime.store(hostTime + static_cast<uint64_t>(frames * hostTicksPerFrame), std::memory_order_relaxed);
        ring->stampSessionBase.store(writerSessionBase, std::memory_order_relaxed);
        ring->stampTicksPerFrame.store(hostTicksPerFrame, std::memory_order_relaxed);
        ring->stampSequence.store(sequence + 2, std::memory_order_release);

        ring->writeEnd.store(writerEnd, std::memory_order_release);
        writerHazard.store(nullptr, std::memory_order_release);
    }

    // MARK: Reader (output device IOProc)

    // Renders |frames| interleaved stereo frames into |out|, applying the
    // smoothed output gains. |outputHostTime| is when the first frame reaches
    // the output device; |outputRateScalar| is the output clock's rate scalar.
    void read(float *out, uint32_t frames, uint64_t outputHostTime, double outputRateScalar, float targetGainLeft,
              float targetGainRight, uint64_t callbackLatenessTicks = 0) noexcept {
        frames = std::min(frames, kMaxRenderFrames);
        RingStorage *ring = acquire(readerHazard);
        if (!ring) {
            std::memset(out, 0, sizeof(float) * frames * kStreamChannels);
            readerHazard.store(nullptr, std::memory_order_release);
            return;
        }
        stats.readerCallbacks.fetch_add(1, std::memory_order_relaxed);
        const double rate = std::max(1.0, deviceSampleRate.load(std::memory_order_relaxed));
        if (ring != readerRing) {
            // New storage starts empty; everything written to it is unplayed.
            readerRing = ring;
            resetReader(0);
        }
        updateRateEstimate(outputRateScalar, frames, rate);

        const int64_t end = ring->writeEnd.load(std::memory_order_acquire);
        Stamp stamp;
        const bool stampValid = loadStamp(ring, stamp);

        if (outputStarting.exchange(false, std::memory_order_acq_rel)) {
            firstOutputCallbackHostTime.store(mach_absolute_time(), std::memory_order_relaxed);
            // The output only stops once everything was played, so audio from
            // sessions before the latest one is left over from a lost device.
            if (stampValid && readPosition < stamp.sessionBase) {
                readPosition = stamp.sessionBase;
            }
            if (end > readPosition) {
                // Audio was written before the displays ran: play it from its
                // first sample; the extra delay is trimmed during silence.
                stats.coldStarts.fetch_add(1, std::memory_order_relaxed);
                stats.lastColdStartBufferedFrames.store(static_cast<uint64_t>(end - readPosition), std::memory_order_relaxed);
            }
            raise(kSignalOutputStarted | kSignalCounters);
        }

        int64_t available = end - readPosition;
        if (available < 0) {
            readPosition = end;
            available = 0;
        }
        const int64_t gap = targetGapFrames(rate);
        if (available > static_cast<int64_t>(ring->capacity) - static_cast<int64_t>(frames)) {
            // The reader fell a whole ring behind; those frames are gone.
            const int64_t resumeAt = std::max<int64_t>(end - gap - frames, end - ring->capacity + frames);
            recordDiagnostic(kDiagnosticOverrun, static_cast<int32_t>(resumeAt - readPosition), readPosition, end);
            readPosition = resumeAt;
            available = end - readPosition;
            fadeInRemaining = fadeFrames(rate);
            stats.overruns.fetch_add(1, std::memory_order_relaxed);
            raise(kSignalCounters);
        }

        uint32_t produced = 0;
        if (state == State::idle && available > 0) {
            state = State::prefill;
            drainedSignalled = false;
        }
        if (state == State::prefill) {
            const bool streamEnded = !hasActiveClients();
            if (available >= gap + frames || (streamEnded && available > 0)) {
                state = State::playing;
                fadeInRemaining = std::max(fadeInRemaining, fadeFrames(rate));
                playingSinceFrames = 0;
                steeringReferenceValid = false;
            }
        }
        if (state == State::playing) {
            const uint32_t count = static_cast<uint32_t>(std::min<int64_t>(available, frames));
            copyOut(ring, readPosition, out, count);
            if (ring->writeEnd.load(std::memory_order_acquire) - static_cast<int64_t>(ring->capacity) > readPosition) {
                // The writer lapped the reader during the copy (the reader
                // stalled for most of the ring): the frames are not valid.
                std::memset(out, 0, sizeof(float) * count * kStreamChannels);
            }
            if (stampValid) {
                measureLatency(stamp, outputHostTime, frames, rate);
            }
            readPosition += count;
            produced = count;
            playingSinceFrames += count;
            if (fadeInRemaining > 0 && produced > 0) {
                applyFadeIn(out, produced, fadeFrames(rate));
            }
            if (count < frames) {
                applyFadeOut(out, count, fadeFrames(rate));
                if (hasActiveClients()) {
                    noteUnderrun(frames - count, available, gap, rate, callbackLatenessTicks);
                    state = State::prefill;
                } else {
                    state = State::idle;
                }
            } else if (hasActiveClients() && end - readPosition < fadeFrames(rate)) {
                // Less than a fade is left while the client still plays: the
                // writer is far behind. Fade out now rather than stop with a
                // click on the next callback; fade back in if it catches up.
                applyFadeOut(out, count, fadeFrames(rate));
                fadeInRemaining = fadeFrames(rate);
                stats.nearUnderruns.fetch_add(1, std::memory_order_relaxed);
            }
        }
        if (produced < frames) {
            std::memset(out + (produced * kStreamChannels), 0, sizeof(float) * (frames - produced) * kStreamChannels);
        }

        const int64_t remaining = end - readPosition;
        bufferedMilliseconds.store(remaining * 1000.0 / rate, std::memory_order_relaxed);
        if (state == State::playing && produced == frames) {
            trimExcessDelay(ring, out, frames, end, gap, rate);
            updateSteering(end - readPosition, frames, rate);
            decaySafetyGap();
        } else {
            relaxSteering();
        }
        readerPublishedPosition.store(readPosition, std::memory_order_release);
        if (state != State::playing && !hasActiveClients() && readPosition >= end && !drainedSignalled) {
            drainedSignalled = true;
            raise(kSignalDrained);
        }
        applyGains(out, frames, targetGainLeft, targetGainRight, rate);
        noteReaderWindow(end - readPosition, callbackLatenessTicks);
        readerHazard.store(nullptr, std::memory_order_release);
    }

    // Starts the output clock estimate over; called when the output device
    // changes.
    void resetClockEstimate() {
        rateScalarValue.store(1.0, std::memory_order_relaxed);
        steeringPPMValue.store(0.0, std::memory_order_relaxed);
        clockRatioValue.store(1.0, std::memory_order_relaxed);
        rateEstimateReset.store(true, std::memory_order_release);
    }

  private:
    enum class State { idle, prefill, playing };

    struct Stamp {
        int64_t end = 0;
        uint64_t endHostTime = 0;
        int64_t sessionBase = 0;
        double ticksPerFrame = 0;
    };

    RingStorage *acquire(std::atomic<RingStorage *> &hazard) noexcept {
        RingStorage *ring = storage.load(std::memory_order_seq_cst);
        for (;;) {
            hazard.store(ring, std::memory_order_seq_cst);
            RingStorage *confirmed = storage.load(std::memory_order_seq_cst);
            if (confirmed == ring) {
                return ring;
            }
            ring = confirmed;
        }
    }

    void retire(RingStorage *previous) {
        if (!previous) {
            return;
        }
        // Wait (off the audio threads) until neither audio thread can still
        // be using the old storage. Each holds it for one callback at most.
        for (int attempt = 0; attempt < 2000; ++attempt) {
            if (writerHazard.load(std::memory_order_seq_cst) != previous &&
                readerHazard.load(std::memory_order_seq_cst) != previous) {
                delete previous;
                return;
            }
            usleep(100);
        }
        // An audio thread stalled inside a callback for 200 ms; leaking one
        // buffer is safer than freeing memory it may still read.
    }

    static bool loadStamp(RingStorage *ring, Stamp &stamp) noexcept {
        for (int attempt = 0; attempt < 4; ++attempt) {
            const uint32_t before = ring->stampSequence.load(std::memory_order_acquire);
            if (before & 1u) {
                continue;
            }
            stamp.end = ring->stampEnd.load(std::memory_order_relaxed);
            stamp.endHostTime = ring->stampEndHostTime.load(std::memory_order_relaxed);
            stamp.sessionBase = ring->stampSessionBase.load(std::memory_order_relaxed);
            stamp.ticksPerFrame = ring->stampTicksPerFrame.load(std::memory_order_relaxed);
            std::atomic_thread_fence(std::memory_order_acquire);
            if (ring->stampSequence.load(std::memory_order_relaxed) == before && before != 0) {
                return stamp.ticksPerFrame > 0;
            }
        }
        return false;
    }

    static void zero(RingStorage *ring, int64_t position, uint32_t frames) noexcept {
        while (frames > 0) {
            const uint32_t slot = static_cast<uint32_t>(position) & ring->mask;
            const uint32_t count = std::min(frames, ring->capacity - slot);
            std::memset(ring->samples + (static_cast<size_t>(slot) * kStreamChannels), 0,
                        sizeof(float) * count * kStreamChannels);
            frames -= count;
            position += count;
        }
    }

    static void copyIn(RingStorage *ring, int64_t position, const float *source, uint32_t frames) noexcept {
        while (frames > 0) {
            const uint32_t slot = static_cast<uint32_t>(position) & ring->mask;
            const uint32_t count = std::min(frames, ring->capacity - slot);
            std::memcpy(ring->samples + (static_cast<size_t>(slot) * kStreamChannels), source,
                        sizeof(float) * count * kStreamChannels);
            source += count * kStreamChannels;
            frames -= count;
            position += count;
        }
    }

    static void copyOut(RingStorage *ring, int64_t position, float *destination, uint32_t frames) noexcept {
        while (frames > 0) {
            const uint32_t slot = static_cast<uint32_t>(position) & ring->mask;
            const uint32_t count = std::min(frames, ring->capacity - slot);
            std::memcpy(destination, ring->samples + (static_cast<size_t>(slot) * kStreamChannels),
                        sizeof(float) * count * kStreamChannels);
            destination += count * kStreamChannels;
            frames -= count;
            position += count;
        }
    }

    // Number of consecutive silent frames at |position|, up to |limit|.
    static uint32_t silentFrames(RingStorage *ring, int64_t position, uint32_t limit) noexcept {
        uint32_t checked = 0;
        while (checked < limit) {
            const uint32_t slot = static_cast<uint32_t>(position + checked) & ring->mask;
            const uint32_t count = std::min(limit - checked, ring->capacity - slot);
            const float *samples = ring->samples + (static_cast<size_t>(slot) * kStreamChannels);
            for (uint32_t frame = 0; frame < count; ++frame) {
                if (std::fabs(samples[frame * 2]) > kSilenceThreshold ||
                    std::fabs(samples[(frame * 2) + 1]) > kSilenceThreshold) {
                    return checked + frame;
                }
            }
            checked += count;
        }
        return checked;
    }

    static bool isSilent(const float *samples, uint32_t frames) noexcept {
        for (uint32_t index = 0; index < frames * kStreamChannels; ++index) {
            if (std::fabs(samples[index]) > kSilenceThreshold) {
                return false;
            }
        }
        return true;
    }

    static uint32_t fadeFrames(double rate) noexcept {
        return std::max<uint32_t>(1, static_cast<uint32_t>(kFadeMilliseconds * rate / 1000.0));
    }

    void resetReader(int64_t position) noexcept {
        readPosition = position;
        state = State::idle;
        fadeInRemaining = 0;
        drainedSignalled = false;
        steeringReferenceValid = false;
        latencyAverageValid = false;
    }

    int64_t targetGapFrames(double rate) const noexcept {
        const double milliseconds = baseSafetyGapMilliseconds.load(std::memory_order_relaxed) +
                                    (adaptiveGapEnabled.load(std::memory_order_relaxed) ? extraSafetyGapMilliseconds : 0.0);
        return static_cast<int64_t>(lastWriterFrames.load(std::memory_order_relaxed)) +
               static_cast<int64_t>(outputBufferFrames.load(std::memory_order_relaxed)) +
               static_cast<int64_t>(milliseconds * rate / 1000.0);
    }

    void applyFadeIn(float *out, uint32_t frames, uint32_t length) noexcept {
        const uint32_t count = std::min(frames, fadeInRemaining);
        for (uint32_t frame = 0; frame < count; ++frame) {
            const float gain = static_cast<float>(length - fadeInRemaining + frame + 1) / static_cast<float>(length + 1);
            out[frame * 2] *= gain;
            out[(frame * 2) + 1] *= gain;
        }
        fadeInRemaining -= count;
    }

    static void applyFadeOut(float *out, uint32_t frames, uint32_t length) noexcept {
        const uint32_t count = std::min(frames, length);
        const uint32_t start = frames - count;
        for (uint32_t frame = 0; frame < count; ++frame) {
            const float gain = static_cast<float>(count - frame) / static_cast<float>(count + 1);
            out[(start + frame) * 2] *= gain;
            out[((start + frame) * 2) + 1] *= gain;
        }
    }

    void noteUnderrun(uint32_t missing, int64_t available, int64_t gap, double rate, uint64_t latenessTicks) noexcept {
        stats.underruns.fetch_add(1, std::memory_order_relaxed);
        fadeInRemaining = fadeFrames(rate);
        steeringReferenceValid = false;
        if (adaptiveGapEnabled.load(std::memory_order_relaxed)) {
            extraSafetyGapMilliseconds =
                std::min(kMaxExtraSafetyGapMilliseconds, extraSafetyGapMilliseconds + kSafetyGapStepMilliseconds);
            extraSafetyGapPublished.store(extraSafetyGapMilliseconds, std::memory_order_relaxed);
            recordDiagnostic(kDiagnosticSafetyGap, 0, 0, 0, currentSafetyGapMilliseconds());
        }
        lastUnderrunHostTime = mach_absolute_time();
        recordDiagnostic(kDiagnosticUnderrun, static_cast<int32_t>(missing), readPosition, readPosition + available,
                         static_cast<double>(available), static_cast<double>(gap), hostTicksToMicroseconds(latenessTicks));
        raise(kSignalCounters);
    }

    void decaySafetyGap() noexcept {
        if (extraSafetyGapMilliseconds <= 0) {
            return;
        }
        const uint64_t now = mach_absolute_time();
        if (lastUnderrunHostTime == 0) {
            lastUnderrunHostTime = now;
            return;
        }
        if (hostTicksToMilliseconds(now - lastUnderrunHostTime) < kSafetyGapDecaySeconds * 1000.0) {
            return;
        }
        extraSafetyGapMilliseconds = std::max(0.0, extraSafetyGapMilliseconds - kSafetyGapStepMilliseconds);
        extraSafetyGapPublished.store(extraSafetyGapMilliseconds, std::memory_order_relaxed);
        lastUnderrunHostTime = now;
        recordDiagnostic(kDiagnosticSafetyGap, 0, 0, 0, currentSafetyGapMilliseconds());
    }

    // Drops extra delay (from a cold start or a widened gap that has since
    // shrunk) while the audio is silent, so nothing audible is skipped.
    void trimExcessDelay(RingStorage *ring, const float *rendered, uint32_t frames, int64_t end, int64_t gap,
                         double rate) noexcept {
        const int64_t excess = (end - readPosition) - gap;
        const int64_t minimum = std::max<int64_t>(outputBufferFrames.load(std::memory_order_relaxed),
                                                  static_cast<int64_t>(kMinimumTrimMilliseconds * rate / 1000.0));
        if (excess <= minimum || !isSilent(rendered, frames)) {
            return;
        }
        const uint32_t skippable = silentFrames(ring, readPosition, static_cast<uint32_t>(excess));
        if (skippable == 0) {
            return;
        }
        readPosition += skippable;
        stats.trimmedFrames.fetch_add(skippable, std::memory_order_relaxed);
        steeringReferenceValid = false;
        latencyAverageValid = false;
        recordDiagnostic(kDiagnosticTrim, static_cast<int32_t>(skippable), 0, 0, static_cast<double>(excess));
        raise(kSignalLatency | kSignalCounters);
    }

    void updateRateEstimate(double rateScalar, uint32_t frames, double rate) noexcept {
        if (rateEstimateReset.exchange(false, std::memory_order_acq_rel)) {
            rateEstimateValid = false;
        }
        if (!(rateScalar > 0.98 && rateScalar < 1.02)) {
            return;
        }
        if (!rateEstimateValid) {
            rateEstimate = rateScalar;
            rateEstimateValid = true;
        } else {
            const double alpha = std::min(1.0, frames / (rate * kRateEstimateSeconds));
            rateEstimate += alpha * (rateScalar - rateEstimate);
        }
        rateScalarValue.store(rateEstimate, std::memory_order_relaxed);
        publishClockRatio();
    }

    // Keeps the buffered amount steady by nudging the Nearfield device's
    // clock when the output clock drifts relative to it.
    void updateSteering(int64_t buffered, uint32_t frames, double rate) noexcept {
        if (!steeringEnabled.load(std::memory_order_relaxed)) {
            relaxSteering();
            return;
        }
        const double alpha = std::min(1.0, frames / (rate * kFillAverageSeconds));
        if (!fillAverageValid) {
            fillAverage = static_cast<double>(buffered);
            fillAverageValid = true;
        } else {
            fillAverage += alpha * (static_cast<double>(buffered) - fillAverage);
        }
        if (!steeringReferenceValid) {
            if (playingSinceFrames < static_cast<uint64_t>(kSteeringSettleSeconds * rate)) {
                return;
            }
            steeringReference = fillAverage;
            steeringIntegral = 0;
            steeringReferenceValid = true;
        }
        const double seconds = frames / rate;
        const double error = fillAverage - steeringReference;  // frames
        steeringIntegral = std::max(-2000.0, std::min(2000.0, steeringIntegral + (error * seconds)));
        // 100 frames of error -> 20 ppm now, and another 20 ppm after it has persisted for 10 s.
        double ppm = (0.2 * error) + (0.02 * steeringIntegral);
        ppm = std::max(-kMaxSteeringPPM, std::min(kMaxSteeringPPM, ppm));
        steeringPPMValue.store(ppm, std::memory_order_relaxed);
        publishClockRatio();
    }

    void relaxSteering() noexcept {
        fillAverageValid = false;
        steeringReferenceValid = false;
    }

    void publishClockRatio() noexcept {
        const double ppm = steeringEnabled.load(std::memory_order_relaxed) ? steeringPPMValue.load(std::memory_order_relaxed) : 0.0;
        // More buffered audio than the reference means the device clock runs
        // ahead of the output: slow it down with more host ticks per frame.
        clockRatioValue.store(rateScalarValue.load(std::memory_order_relaxed) * (1.0 + (ppm * 1e-6)),
                              std::memory_order_relaxed);
    }

    void measureLatency(const Stamp &stamp, uint64_t outputHostTime, uint32_t frames, double rate) noexcept {
        if (readPosition < stamp.sessionBase || stamp.ticksPerFrame <= 0 || outputHostTime == 0) {
            return;
        }
        // Host time the Nearfield clock assigned to the frame at readPosition.
        const double frameHostTime =
            static_cast<double>(stamp.endHostTime) - (static_cast<double>(stamp.end - readPosition) * stamp.ticksPerFrame);
        const double heardHostTime = static_cast<double>(outputHostTime) +
                                     (outputLatencyFrames.load(std::memory_order_relaxed) * stamp.ticksPerFrame);
        const double latency = (heardHostTime - frameHostTime) / stamp.ticksPerFrame;
        if (!std::isfinite(latency) || latency < 0 || latency > rate * 5) {
            return;
        }
        if (!latencyAverageValid) {
            latencyAverage = latency;
            latencyAverageValid = true;
        } else {
            const double alpha = std::min(1.0, frames / (rate * kLatencyAverageSeconds));
            latencyAverage += alpha * (latency - latencyAverage);
        }
        if (std::fabs(latencyAverage - lastSignalledLatency) > rate / 1000.0) {
            lastSignalledLatency = latencyAverage;
            measuredLatency.store(latencyAverage, std::memory_order_relaxed);
            recordDiagnostic(kDiagnosticLatency, 0, 0, 0, latencyAverage);
            raise(kSignalLatency);
        }
    }

    void applyGains(float *out, uint32_t frames, float targetLeft, float targetRight, double rate) noexcept {
        if (!gainsInitialized) {
            gainLeft = targetLeft;
            gainRight = targetRight;
            gainTargetLeft = targetLeft;
            gainTargetRight = targetRight;
            gainsInitialized = true;
        } else if (targetLeft != gainTargetLeft || targetRight != gainTargetRight) {
            gainTargetLeft = targetLeft;
            gainTargetRight = targetRight;
            gainRampRemaining = std::max<uint32_t>(1, static_cast<uint32_t>(kGainRampMilliseconds * rate / 1000.0));
            gainStepLeft = (targetLeft - gainLeft) / static_cast<float>(gainRampRemaining);
            gainStepRight = (targetRight - gainRight) / static_cast<float>(gainRampRemaining);
        }
        for (uint32_t frame = 0; frame < frames; ++frame) {
            if (gainRampRemaining > 0) {
                gainLeft += gainStepLeft;
                gainRight += gainStepRight;
                if (--gainRampRemaining == 0) {
                    gainLeft = gainTargetLeft;
                    gainRight = gainTargetRight;
                }
            }
            out[frame * 2] *= gainLeft;
            out[(frame * 2) + 1] *= gainRight;
        }
    }

    void noteWriterWindow(uint32_t frames, uint64_t latenessTicks) noexcept {
        if (!diagnostics || !diagnostics->isEnabled()) {
            return;
        }
        const uint64_t now = mach_absolute_time();
        writerWindow.noteCallback(now, latenessTicks);
        writerWindow.noteFill(static_cast<double>(frames));
        DiagnosticRecord record;
        if (writerWindow.finish(now, kDiagnosticWriterWindow, record)) {
            diagnostics->push(record);
            raise(kSignalDiagnostics);
        }
    }

    void noteReaderWindow(int64_t buffered, uint64_t latenessTicks) noexcept {
        if (!diagnostics || !diagnostics->isEnabled()) {
            return;
        }
        const uint64_t now = mach_absolute_time();
        readerWindow.noteCallback(now, latenessTicks);
        readerWindow.noteFill(static_cast<double>(buffered));
        DiagnosticRecord record;
        if (readerWindow.finish(now, kDiagnosticReaderWindow, record)) {
            diagnostics->push(record);
            recordDiagnostic(kDiagnosticClock, 0, 0, 0, steeringPPMValue.load(std::memory_order_relaxed),
                             rateScalarValue.load(std::memory_order_relaxed));
            raise(kSignalDiagnostics);
        }
    }

    void recordDiagnostic(uint32_t kind, int32_t i0 = 0, int64_t i1 = 0, int64_t i2 = 0, double d0 = 0,
                          double d1 = 0, double d2 = 0) noexcept {
        if (diagnostics && diagnostics->isEnabled()) {
            diagnostics->record(kind, i0, i1, i2, d0, d1, d2);
            raise(kSignalDiagnostics);
        }
    }

    void raise(uintptr_t signals) noexcept {
        if (signalFunction) {
            signalFunction(signalContext, signals);
        }
    }

    // Shared state.
    std::atomic<RingStorage *> storage{nullptr};
    std::atomic<RingStorage *> writerHazard{nullptr};
    std::atomic<RingStorage *> readerHazard{nullptr};
    std::atomic<uint64_t> sessionRequests{0};
    std::atomic<bool> clientsActive{false};
    std::atomic<bool> outputStarting{false};
    std::atomic<bool> rateEstimateReset{false};
    std::atomic<uint32_t> lastWriterFrames{512};
    std::atomic<uint32_t> outputBufferFrames{512};
    std::atomic<uint32_t> outputLatencyFrames{0};
    std::atomic<double> deviceSampleRate{48000.0};
    std::atomic<double> outputSampleRate{48000.0};
    std::atomic<double> baseSafetyGapMilliseconds{kDefaultSafetyGapMilliseconds};
    std::atomic<bool> steeringEnabled{true};
    std::atomic<bool> adaptiveGapEnabled{true};
    std::atomic<double> extraSafetyGapPublished{0};
    std::atomic<double> rateScalarValue{1.0};
    std::atomic<double> steeringPPMValue{0.0};
    std::atomic<double> clockRatioValue{1.0};
    std::atomic<double> measuredLatency{0.0};
    std::atomic<double> bufferedMilliseconds{0.0};
    std::atomic<int64_t> readerPublishedPosition{0};
    std::atomic<uint64_t> outputStartRequestHostTime{0};
    std::atomic<uint64_t> firstOutputCallbackHostTime{0};
    PlaybackCounters stats;
    PlaybackSignalFunction signalFunction = nullptr;
    void *signalContext = nullptr;
    Diagnostics *diagnostics = nullptr;

    // Writer-owned.
    RingStorage *writerRing = nullptr;
    int64_t writerEnd = 0;
    int64_t writerNextFrame = 0;
    int64_t writerSessionBase = 0;
    uint64_t writerSessionRequest = 0;
    bool writerHasSession = false;
    CallbackWindow writerWindow;

    // Reader-owned.
    RingStorage *readerRing = nullptr;
    State state = State::idle;
    int64_t readPosition = 0;
    uint32_t fadeInRemaining = 0;
    bool drainedSignalled = false;
    uint64_t playingSinceFrames = 0;
    double extraSafetyGapMilliseconds = 0;
    uint64_t lastUnderrunHostTime = 0;
    double rateEstimate = 1.0;
    bool rateEstimateValid = false;
    double fillAverage = 0;
    bool fillAverageValid = false;
    double steeringReference = 0;
    double steeringIntegral = 0;
    bool steeringReferenceValid = false;
    double latencyAverage = 0;
    bool latencyAverageValid = false;
    double lastSignalledLatency = -1e9;
    bool gainsInitialized = false;
    float gainLeft = 1;
    float gainRight = 1;
    float gainTargetLeft = 1;
    float gainTargetRight = 1;
    float gainStepLeft = 0;
    float gainStepRight = 0;
    uint32_t gainRampRemaining = 0;
    CallbackWindow readerWindow;
};

// Zero time stamps for the Nearfield device, derived from host time and the
// playback engine's clock ratio. Any thread may ask. One thread at a time
// advances the timeline; a thread that finds it busy gets the latest
// published stamp instead. Stamps are published as one 16-byte atomic value,
// so every caller gets a matching sample time and host time, never older than
// one it saw before.
class DeviceClock {
  public:
    struct Stamp {
        double sampleTime;
        uint64_t hostTime;
    };
    static_assert(std::atomic<Stamp>::is_always_lock_free, "zero time stamps must be published without locks");

    void setHostTicksPerFrame(double ticks) { nominalTicksPerFrame.store(ticks, std::memory_order_relaxed); }
    double hostTicksPerFrame() const { return nominalTicksPerFrame.load(std::memory_order_relaxed); }

    // Starts a new timeline at |now|, when IO starts or the sample rate
    // changes. Not for audio threads: it waits for a thread advancing the
    // clock, which takes well under a microsecond.
    void reset(uint64_t now) noexcept {
        while (busy.test_and_set(std::memory_order_acquire)) {
            sched_yield();
        }
        anchorHostTime = now;
        periods = 0;
        elapsedTicks = 0;
        published.store(Stamp{0, now}, std::memory_order_release);
        busy.clear(std::memory_order_release);
    }

    void get(uint32_t period, double ratio, uint64_t now, double &outSampleTime, uint64_t &outHostTime) noexcept {
        if (busy.test_and_set(std::memory_order_acquire)) {
            const Stamp stamp = published.load(std::memory_order_acquire);
            outSampleTime = stamp.sampleTime;
            outHostTime = stamp.hostTime;
            return;
        }
        if (anchorHostTime == 0) {
            anchorHostTime = now;
            periods = 0;
            elapsedTicks = 0;
        }
        const double periodTicks = nominalTicksPerFrame.load(std::memory_order_relaxed) * period *
                                   ((ratio > 0.97 && ratio < 1.03) ? ratio : 1.0);
        if (periodTicks > 0) {
            const double since = static_cast<double>(now) - (static_cast<double>(anchorHostTime) + elapsedTicks);
            if (since >= periodTicks) {
                const double steps = std::floor(since / periodTicks);
                elapsedTicks += steps * periodTicks;
                periods += static_cast<uint64_t>(steps);
            }
        }
        const Stamp stamp{static_cast<double>(periods) * period, anchorHostTime + static_cast<uint64_t>(elapsedTicks)};
        published.store(stamp, std::memory_order_release);
        busy.clear(std::memory_order_release);
        outSampleTime = stamp.sampleTime;
        outHostTime = stamp.hostTime;
    }

  private:
    std::atomic<double> nominalTicksPerFrame{0};
    std::atomic_flag busy = ATOMIC_FLAG_INIT;
    std::atomic<Stamp> published{Stamp{0, 0}};
    // Only touched by the thread holding |busy|.
    uint64_t anchorHostTime = 0;
    uint64_t periods = 0;
    double elapsedTicks = 0;
};

// Maps the engine's stereo output onto the output device's buffers, matching
// how the driver-owned aggregate exposes two or three displays.
inline void renderToBufferList(const float *stereo, uint32_t frames, uint32_t frameOffset, AudioBufferList *output) noexcept {
    const UInt32 bufferCount = output->mNumberBuffers;
    for (UInt32 bufferIndex = 0; bufferIndex < bufferCount; ++bufferIndex) {
        AudioBuffer &buffer = output->mBuffers[bufferIndex];
        const UInt32 channels = buffer.mNumberChannels;
        if (channels == 0 || buffer.mData == nullptr) {
            continue;
        }
        const UInt32 bufferFrames = buffer.mDataByteSize / (channels * sizeof(float));
        if (frameOffset >= bufferFrames) {
            continue;
        }
        const UInt32 count = std::min<UInt32>(frames, bufferFrames - frameOffset);
        float *data = static_cast<float *>(buffer.mData) + (static_cast<size_t>(frameOffset) * channels);
        std::memset(data, 0, sizeof(float) * count * channels);

        if (bufferCount > 1) {
            const UInt32 targetChannels = std::min<UInt32>(channels, kStreamChannels);
            const bool isThreeDisplayCenter = bufferCount >= 3 && bufferIndex == 1;
            const UInt32 inputChannel = bufferCount >= 3 ? (bufferIndex == 0 ? 0 : 1) : bufferIndex % kStreamChannels;
            for (UInt32 channel = 0; channel < targetChannels; ++channel) {
                float *out = data + channel;
                for (UInt32 frame = 0; frame < count; ++frame) {
                    const float *in = stereo + (frame * kStreamChannels);
                    *out = isThreeDisplayCenter ? (in[0] + in[1]) * 0.5f : in[inputChannel];
                    out += channels;
                }
            }
        } else if (channels >= 3) {
            for (UInt32 frame = 0; frame < count; ++frame) {
                const float *in = stereo + (frame * kStreamChannels);
                float *out = data + (frame * channels);
                out[0] = in[0];
                out[1] = (in[0] + in[1]) * 0.5f;
                out[2] = in[1];
            }
        } else if (channels == 1) {
            for (UInt32 frame = 0; frame < count; ++frame) {
                const float *in = stereo + (frame * kStreamChannels);
                data[frame] = (in[0] + in[1]) * 0.5f;
            }
        } else {
            for (UInt32 frame = 0; frame < count; ++frame) {
                const float *in = stereo + (frame * kStreamChannels);
                float *out = data + (frame * channels);
                out[0] = in[0];
                out[1] = in[1];
            }
        }
    }
}

} // namespace nearfield

#endif /* NearfieldPlayback_h */
