#ifndef NearfieldCharacter_h
#define NearfieldCharacter_h

// Nearfield's Character setting. The Studio Displays boost their bass as their
// own volume falls, by up to 16 dB. Measured with a display's microphone
// (1/3-octave sweeps, bass relative to 400 Hz-1 kHz, two rounds within 1 dB
// at 80-250 Hz), the boost is a low shelf at 150 Hz whose depth follows the
// display's volume (fit within 0.7 dB RMS at 50-400 Hz).
//
// Character removes a share of that boost: 0 keeps the displays' own tuning,
// 1 (Neutral) plays at every volume with the balance the displays have at full
// volume. While the displays play at full volume (Nearfield attenuates in
// software), they add no boost and nothing is removed.
//
// Threads: the amount is set from any thread; process() runs on the displays'
// IO thread and never locks, allocates or logs. Changes ramp, so neither the
// setting nor the volume clicks.

#include <atomic>
#include <cmath>
#include <cstdint>
#include <iterator>

namespace nearfield {

constexpr double kCharacterShelfHz = 150.0;
constexpr double kCharacterRampDecibelsPerSecond = 48.0;

// The displays' bass boost at their own volume, in dB.
inline double displayBassBoostDecibels(double displayDecibels) noexcept {
    struct Point {
        double volume;
        double boost;
    };
    static constexpr Point points[] = {{0.0, 0.0},    {-6.0, 1.8},   {-12.0, 5.8},  {-18.5, 9.4},
                                       {-25.0, 12.0}, {-31.5, 14.0}, {-38.0, 15.6}, {-44.0, 15.8}};
    if (!(displayDecibels < 0.0)) {
        return 0.0;
    }
    for (size_t index = 1; index < std::size(points); ++index) {
        if (displayDecibels >= points[index].volume) {
            const Point &louder = points[index - 1];
            const Point &quieter = points[index];
            const double position = (louder.volume - displayDecibels) / (louder.volume - quieter.volume);
            return louder.boost + position * (quieter.boost - louder.boost);
        }
    }
    // Quieter than measured: the boost had stopped growing.
    return points[std::size(points) - 1].boost;
}

struct ShelfCoefficients {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
};

// The RBJ cookbook low shelf (slope 1): |decibels| below the corner, flat above.
inline ShelfCoefficients lowShelf(double decibels, double cornerHz, double sampleRate) noexcept {
    const double a = std::pow(10.0, decibels / 40.0);
    const double w0 = 2.0 * M_PI * cornerHz / sampleRate;
    const double cosine = std::cos(w0);
    const double alpha = std::sin(w0) / 2.0 * std::sqrt(2.0);
    const double twoRootAAlpha = 2.0 * std::sqrt(a) * alpha;
    const double a0 = (a + 1) + (a - 1) * cosine + twoRootAAlpha;
    ShelfCoefficients c;
    c.b0 = a * ((a + 1) - (a - 1) * cosine + twoRootAAlpha) / a0;
    c.b1 = 2 * a * ((a - 1) - (a + 1) * cosine) / a0;
    c.b2 = a * ((a + 1) - (a - 1) * cosine - twoRootAAlpha) / a0;
    c.a1 = -2 * ((a - 1) + (a + 1) * cosine) / a0;
    c.a2 = ((a + 1) + (a - 1) * cosine - twoRootAAlpha) / a0;
    return c;
}

class CharacterFilter {
public:
    static double clampAmount(double amount) noexcept { return std::fmin(1.0, std::fmax(0.0, amount)); }

    void setAmount(double amount) noexcept { target.store(clampAmount(amount), std::memory_order_relaxed); }

    double amount() const noexcept { return target.load(std::memory_order_relaxed); }

    // Filters interleaved stereo in place. |leftDisplayDecibels| and
    // |rightDisplayDecibels| are the volumes of the displays playing each
    // channel, or 0 while they play at full volume.
    void process(float *stereo, uint32_t frames, double sampleRate, double leftDisplayDecibels,
                 double rightDisplayDecibels) noexcept {
        if (frames == 0 || !(sampleRate > 0)) {
            return;
        }
        const double share = target.load(std::memory_order_relaxed);
        const double goals[2] = {-share * displayBassBoostDecibels(leftDisplayDecibels),
                                 -share * displayBassBoostDecibels(rightDisplayDecibels)};
        const double step = kCharacterRampDecibelsPerSecond * frames / sampleRate;
        for (uint32_t index = 0; index < 2; ++index) {
            Channel &channel = channels[index];
            const double goal = goals[index];
            if (channel.current == 0.0 && goal == 0.0) {
                // Flat: the audio passes untouched.
                channel.reset();
                continue;
            }
            if (channel.current != goal || sampleRate != channel.coefficientRate) {
                channel.current =
                    goal > channel.current ? std::fmin(goal, channel.current + step) : std::fmax(goal, channel.current - step);
                channel.coefficients = lowShelf(channel.current, kCharacterShelfHz, sampleRate);
                channel.coefficientRate = sampleRate;
            }
            channel.process(stereo + index, frames);
        }
    }

private:
    struct Channel {
        double current = 0.0;
        double coefficientRate = 0.0;
        ShelfCoefficients coefficients;
        double z1 = 0.0;
        double z2 = 0.0;

        void reset() noexcept { z1 = z2 = 0.0; }

        // Transposed direct form II, in double: at 96 kHz a 150 Hz corner
        // needs more precision than float has.
        void process(float *sample, uint32_t frames) noexcept {
            const ShelfCoefficients c = coefficients;
            for (uint32_t frame = 0; frame < frames; ++frame, sample += 2) {
                const double in = *sample;
                const double out = c.b0 * in + z1;
                z1 = c.b1 * in - c.a1 * out + z2;
                z2 = c.b2 * in - c.a2 * out;
                *sample = static_cast<float>(out);
            }
        }
    };

    std::atomic<double> target{0.0};
    // IO thread only.
    Channel channels[2];
};

} // namespace nearfield

#endif /* NearfieldCharacter_h */
