#ifndef NearfieldDiagnostics_h
#define NearfieldDiagnostics_h

// Real-time-safe diagnostics shared by the driver's audio paths.
//
// Audio callbacks only write fixed-size records into a preallocated lock-free
// queue and update plain counters. A non-real-time thread drains the queue and
// writes the records to the unified log. Nothing here allocates, blocks, or
// logs on the calling thread.

#include <atomic>
#include <cmath>
#include <cstdint>
#include <mach/mach_time.h>

namespace nearfield {

enum DiagnosticKind : uint32_t {
    // Summary of one audio thread over about one second.
    // i0 callbacks, i1 max wake-up lateness (us), i2 max lock wait (us),
    // d0 min buffered frames, d1 max buffered frames, d2 max callback interval (ms)
    kDiagnosticWriterWindow = 1,
    kDiagnosticReaderWindow = 2,
    // i0 missing frames, i1 read position, i2 write end, d0 buffered frames before the read,
    // d1 safety gap (frames), d2 callback lateness (us)
    kDiagnosticUnderrun = 3,
    // i0 frames lost, i1 read position, i2 write end
    kDiagnosticOverrun = 4,
    kDiagnosticResync = 5,
    // i0 client count after the change, i1 client ID
    kDiagnosticStartIO = 6,
    kDiagnosticStopIO = 7,
    kDiagnosticOutputStartRequested = 8,
    // d0 milliseconds between the start request and the first output callback
    kDiagnosticOutputFirstCallback = 9,
    kDiagnosticOutputStopped = 10,
    // d0 device sample rate, d1 output sample rate
    kDiagnosticSampleRate = 11,
    // i0 frames skipped, d0 excess delay before trimming (frames)
    kDiagnosticTrim = 12,
    // d0 new safety gap (ms)
    kDiagnosticSafetyGap = 13,
    // d0 measured latency (frames), d1 reported latency (frames)
    kDiagnosticLatency = 14,
    // i0 new client buffer frames, i1 output buffer frames
    kDiagnosticBufferSizes = 15,
    // d0 rate correction (ppm), d1 output rate scalar
    kDiagnosticClock = 16,
};

struct DiagnosticRecord {
    uint64_t hostTime = 0;
    uint32_t kind = 0;
    int32_t i0 = 0;
    int64_t i1 = 0;
    int64_t i2 = 0;
    double d0 = 0;
    double d1 = 0;
    double d2 = 0;
};

inline const char *diagnosticKindName(uint32_t kind) {
    switch (kind) {
        case kDiagnosticWriterWindow: return "writer";
        case kDiagnosticReaderWindow: return "reader";
        case kDiagnosticUnderrun: return "underrun";
        case kDiagnosticOverrun: return "overrun";
        case kDiagnosticResync: return "resync";
        case kDiagnosticStartIO: return "start-io";
        case kDiagnosticStopIO: return "stop-io";
        case kDiagnosticOutputStartRequested: return "output-start";
        case kDiagnosticOutputFirstCallback: return "output-first-callback";
        case kDiagnosticOutputStopped: return "output-stop";
        case kDiagnosticSampleRate: return "sample-rate";
        case kDiagnosticTrim: return "trim";
        case kDiagnosticSafetyGap: return "safety-gap";
        case kDiagnosticLatency: return "latency";
        case kDiagnosticBufferSizes: return "buffer-sizes";
        case kDiagnosticClock: return "clock";
        default: return "unknown";
    }
}

inline double hostTicksPerMicrosecond() {
    static const double ticks = [] {
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        return (1000.0 * info.denom) / info.numer;
    }();
    return ticks;
}

inline double hostTicksToMicroseconds(uint64_t ticks) {
    return ticks / hostTicksPerMicrosecond();
}

inline double hostTicksToMilliseconds(uint64_t ticks) {
    return hostTicksToMicroseconds(ticks) / 1000.0;
}

// Bounded multi-producer, single-consumer queue (Vyukov). Producers never
// wait for the consumer; a full queue drops the record and counts it.
template <uint32_t Capacity>
class DiagnosticQueue {
    static_assert(Capacity > 1 && (Capacity & (Capacity - 1)) == 0, "Capacity must be a power of two");

    struct Cell {
        std::atomic<uint64_t> sequence{0};
        DiagnosticRecord record;
    };

  public:
    DiagnosticQueue() {
        for (uint32_t index = 0; index < Capacity; ++index) {
            cells[index].sequence.store(index, std::memory_order_relaxed);
        }
    }

    bool push(const DiagnosticRecord &record) noexcept {
        uint64_t position = enqueuePosition.load(std::memory_order_relaxed);
        for (;;) {
            Cell &cell = cells[position & (Capacity - 1)];
            const uint64_t sequence = cell.sequence.load(std::memory_order_acquire);
            const int64_t difference = static_cast<int64_t>(sequence) - static_cast<int64_t>(position);
            if (difference == 0) {
                if (enqueuePosition.compare_exchange_weak(position, position + 1, std::memory_order_relaxed)) {
                    cell.record = record;
                    cell.sequence.store(position + 1, std::memory_order_release);
                    return true;
                }
            } else if (difference < 0) {
                droppedRecords.fetch_add(1, std::memory_order_relaxed);
                return false;
            } else {
                position = enqueuePosition.load(std::memory_order_relaxed);
            }
        }
    }

    // Single consumer only.
    bool pop(DiagnosticRecord &record) noexcept {
        const uint64_t position = dequeuePosition.load(std::memory_order_relaxed);
        Cell &cell = cells[position & (Capacity - 1)];
        const uint64_t sequence = cell.sequence.load(std::memory_order_acquire);
        if (static_cast<int64_t>(sequence) - static_cast<int64_t>(position + 1) < 0) {
            return false;
        }
        record = cell.record;
        cell.sequence.store(position + Capacity, std::memory_order_release);
        dequeuePosition.store(position + 1, std::memory_order_relaxed);
        return true;
    }

    uint64_t dropped() const noexcept { return droppedRecords.load(std::memory_order_relaxed); }

  private:
    Cell cells[Capacity];
    alignas(64) std::atomic<uint64_t> enqueuePosition{0};
    alignas(64) std::atomic<uint64_t> dequeuePosition{0};
    std::atomic<uint64_t> droppedRecords{0};
};

// Per-thread statistics for one audio callback path. Owned by exactly one
// real-time thread; it publishes a summary record about once per second.
struct CallbackWindow {
    uint64_t windowStart = 0;
    uint64_t lastCallback = 0;
    uint32_t callbacks = 0;
    uint64_t maxLatenessTicks = 0;
    uint64_t maxLockWaitTicks = 0;
    uint64_t maxIntervalTicks = 0;
    double minFill = INFINITY;
    double maxFill = -INFINITY;

    void noteCallback(uint64_t now, uint64_t latenessTicks) noexcept {
        if (lastCallback != 0 && now > lastCallback && now - lastCallback > maxIntervalTicks) {
            maxIntervalTicks = now - lastCallback;
        }
        lastCallback = now;
        ++callbacks;
        if (latenessTicks > maxLatenessTicks) {
            maxLatenessTicks = latenessTicks;
        }
    }

    void noteLockWait(uint64_t ticks) noexcept {
        if (ticks > maxLockWaitTicks) {
            maxLockWaitTicks = ticks;
        }
    }

    void noteFill(double frames) noexcept {
        if (frames < minFill) minFill = frames;
        if (frames > maxFill) maxFill = frames;
    }

    // Returns true and fills |record| when the window is complete.
    bool finish(uint64_t now, uint32_t kind, DiagnosticRecord &record) noexcept {
        if (windowStart == 0) {
            windowStart = now;
            return false;
        }
        if (hostTicksToMilliseconds(now - windowStart) < 1000.0) {
            return false;
        }
        record.hostTime = now;
        record.kind = kind;
        record.i0 = static_cast<int32_t>(callbacks);
        record.i1 = static_cast<int64_t>(hostTicksToMicroseconds(maxLatenessTicks));
        record.i2 = static_cast<int64_t>(hostTicksToMicroseconds(maxLockWaitTicks));
        record.d0 = std::isfinite(minFill) ? minFill : 0;
        record.d1 = std::isfinite(maxFill) ? maxFill : 0;
        record.d2 = hostTicksToMilliseconds(maxIntervalTicks);
        windowStart = now;
        callbacks = 0;
        maxLatenessTicks = 0;
        maxLockWaitTicks = 0;
        maxIntervalTicks = 0;
        minFill = INFINITY;
        maxFill = -INFINITY;
        return true;
    }
};

class Diagnostics {
  public:
    std::atomic<bool> enabled{false};

    bool isEnabled() const noexcept { return enabled.load(std::memory_order_relaxed); }

    void record(uint32_t kind,
                int32_t i0 = 0,
                int64_t i1 = 0,
                int64_t i2 = 0,
                double d0 = 0,
                double d1 = 0,
                double d2 = 0) noexcept {
        if (!isEnabled()) {
            return;
        }
        DiagnosticRecord entry;
        entry.hostTime = mach_absolute_time();
        entry.kind = kind;
        entry.i0 = i0;
        entry.i1 = i1;
        entry.i2 = i2;
        entry.d0 = d0;
        entry.d1 = d1;
        entry.d2 = d2;
        queue.push(entry);
    }

    void push(const DiagnosticRecord &entry) noexcept {
        if (isEnabled()) {
            queue.push(entry);
        }
    }

    bool pop(DiagnosticRecord &entry) noexcept { return queue.pop(entry); }
    uint64_t dropped() const noexcept { return queue.dropped(); }

  private:
    DiagnosticQueue<1024> queue;
};

// Counts requests the driver makes to Core Audio as a HAL client, reported in
// the status so idle activity can be measured.
inline std::atomic<uint64_t> &halRequestCount() {
    static std::atomic<uint64_t> count{0};
    return count;
}

inline void countHALRequest() { halRequestCount().fetch_add(1, std::memory_order_relaxed); }

} // namespace nearfield

#endif /* NearfieldDiagnostics_h */
