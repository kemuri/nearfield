#ifndef NearfieldRouteTable_h
#define NearfieldRouteTable_h

// Per-client routes shared with the IO thread.
//
// Configuration threads assign, update and release slots while holding the
// driver's state mutex. The IO thread only reads atomics: it finds a client's
// slot with a bounded scan and crossfades to the slot's route. Nothing here
// allocates or locks on the IO thread.

#include <atomic>
#include <cstdint>

namespace nearfield {

enum class Route : uint8_t { pair = 0, left = 1, right = 2, muted = 3 };

inline const char *routeName(Route route) {
    switch (route) {
        case Route::left: return "left";
        case Route::right: return "right";
        case Route::muted: return "muted";
        case Route::pair:
        default: return "pair";
    }
}

// Maps a client's stereo frame to the device's stereo frame:
// out.left = ll * in.left + rl * in.right, out.right = lr * in.left + rr * in.right.
struct RouteMatrix {
    float ll = 1;
    float rl = 0;
    float lr = 0;
    float rr = 1;
};

inline RouteMatrix routeMatrix(Route route) {
    switch (route) {
        case Route::left: return RouteMatrix{0.5f, 0.5f, 0.0f, 0.0f};
        case Route::right: return RouteMatrix{0.0f, 0.0f, 0.5f, 0.5f};
        case Route::muted: return RouteMatrix{0.0f, 0.0f, 0.0f, 0.0f};
        case Route::pair:
        default: return RouteMatrix{1.0f, 0.0f, 0.0f, 1.0f};
    }
}

class RouteTable {
  public:
    static constexpr uint32_t kCapacity = 128;

    // Configuration threads (serialized by the caller).
    bool assign(uint32_t clientID, Route route) noexcept {
        const uint64_t key = keyFor(clientID);
        int free = -1;
        for (uint32_t index = 0; index < kCapacity; ++index) {
            const uint64_t existing = slots[index].key.load(std::memory_order_relaxed);
            if (existing == key) {
                storeRoute(index, route);
                return true;
            }
            if (existing == 0 && free < 0) {
                free = static_cast<int>(index);
            }
        }
        if (free < 0) {
            return false;
        }
        Slot &slot = slots[free];
        slot.route.store(static_cast<uint8_t>(route), std::memory_order_relaxed);
        slot.generation.fetch_add(1, std::memory_order_relaxed);
        // Publishing the key makes the route and generation visible together.
        slot.key.store(key, std::memory_order_release);
        return true;
    }

    void release(uint32_t clientID) noexcept {
        const int index = find(clientID);
        if (index >= 0) {
            slots[index].key.store(0, std::memory_order_release);
        }
    }

    void setRoute(uint32_t clientID, Route route) noexcept {
        const int index = find(clientID);
        if (index >= 0) {
            storeRoute(static_cast<uint32_t>(index), route);
        }
    }

    // Any thread.
    int find(uint32_t clientID) const noexcept {
        const uint64_t key = keyFor(clientID);
        for (uint32_t index = 0; index < kCapacity; ++index) {
            if (slots[index].key.load(std::memory_order_acquire) == key) {
                return static_cast<int>(index);
            }
        }
        return -1;
    }

    Route route(int index) const noexcept {
        return static_cast<Route>(slots[index].route.load(std::memory_order_acquire));
    }

    uint32_t generation(int index) const noexcept {
        return slots[index].generation.load(std::memory_order_acquire);
    }

  private:
    struct Slot {
        std::atomic<uint64_t> key{0};  // client ID + 1; 0 marks a free slot
        std::atomic<uint32_t> generation{0};
        std::atomic<uint8_t> route{0};
    };

    static uint64_t keyFor(uint32_t clientID) noexcept { return static_cast<uint64_t>(clientID) + 1; }

    void storeRoute(uint32_t index, Route route) noexcept {
        slots[index].route.store(static_cast<uint8_t>(route), std::memory_order_release);
    }

    Slot slots[kCapacity];
};

// Owned by the IO thread: crossfades each client from its previous route to
// its current one instead of switching abruptly.
class ClientRouteMixer {
  public:
    void process(const RouteTable &table, uint32_t clientID, float *interleaved, uint32_t frames,
                 uint32_t crossfadeFrames) noexcept {
        const int index = table.find(clientID);
        if (index < 0) {
            return;  // Unknown clients keep their stereo image.
        }
        State &state = states[index];
        const uint32_t generation = table.generation(index);
        const Route route = table.route(index);
        if (state.generation != generation) {
            // A new client starts at its route without a fade.
            state.generation = generation;
            state.route = route;
            state.current = routeMatrix(route);
            state.remaining = 0;
        } else if (state.route != route) {
            state.route = route;
            const RouteMatrix target = routeMatrix(route);
            state.remaining = crossfadeFrames > 0 ? crossfadeFrames : 1;
            const float steps = static_cast<float>(state.remaining);
            state.step = RouteMatrix{(target.ll - state.current.ll) / steps,
                                     (target.rl - state.current.rl) / steps,
                                     (target.lr - state.current.lr) / steps,
                                     (target.rr - state.current.rr) / steps};
            state.target = target;
        }

        if (state.remaining == 0 && isIdentity(state.current)) {
            return;
        }
        for (uint32_t frame = 0; frame < frames; ++frame) {
            if (state.remaining > 0) {
                state.current.ll += state.step.ll;
                state.current.rl += state.step.rl;
                state.current.lr += state.step.lr;
                state.current.rr += state.step.rr;
                if (--state.remaining == 0) {
                    state.current = state.target;
                }
            }
            float *sample = interleaved + (frame * 2);
            const float left = sample[0];
            const float right = sample[1];
            sample[0] = (state.current.ll * left) + (state.current.rl * right);
            sample[1] = (state.current.lr * left) + (state.current.rr * right);
        }
    }

  private:
    struct State {
        uint32_t generation = UINT32_MAX;
        Route route = Route::pair;
        RouteMatrix current;
        RouteMatrix target;
        RouteMatrix step;
        uint32_t remaining = 0;
    };

    static bool isIdentity(const RouteMatrix &matrix) noexcept {
        return matrix.ll == 1.0f && matrix.rl == 0.0f && matrix.lr == 0.0f && matrix.rr == 1.0f;
    }

    State states[RouteTable::kCapacity];
};

} // namespace nearfield

#endif /* NearfieldRouteTable_h */
