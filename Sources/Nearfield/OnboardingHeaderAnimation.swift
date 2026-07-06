import SwiftUI

struct NearfieldHeaderAnimation: View {
    var configuration = NearfieldHeaderAnimationConfiguration.onboarding
    /// When true the per-frame animation stops (used when the window is hidden).
    var paused: Bool = false

    var body: some View {
        // The render effect is applied to the animation only — callers overlay
        // the logo and title on top, so those stay crisp and untouched.
        AnimationEffectsView(effect: configuration.effect, settings: configuration.effectSettings, paused: paused) {
            CoreHeaderAnimation(configuration: configuration, paused: paused)
        }
    }
}

/// Renders the header at an interpolated point between two configurations.
/// `@MainActor Animatable` lets SwiftUI tween `progress` frame-by-frame, so every
/// continuous setting animates between the two states (e.g. normal ↔ hover).
struct InterpolatedHeaderAnimation: View, @MainActor Animatable {
    var progress: Double
    let normal: NearfieldHeaderAnimationConfiguration
    let hover: NearfieldHeaderAnimationConfiguration
    var paused: Bool = false

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        NearfieldHeaderAnimation(
            configuration: .interpolated(from: normal, to: hover, t: progress),
            paused: paused
        )
    }
}

/// Integrates the wave phase over time. Held in `@State` so it persists across
/// re-renders; mutated (not observed) inside the timeline so config changes
/// don't trigger view updates.
private final class WavePhaseClock {
    var phase: Double = 0
    var lastDate: Date?
}

private struct CoreHeaderAnimation: View {
    let configuration: NearfieldHeaderAnimationConfiguration
    var paused: Bool = false
    @State private var startDate = Date()
    @State private var clock = WavePhaseClock()

    /// Integrates the phase: advances by `speed * dt` each frame rather than
    /// computing `elapsed * speed`. Changing the speed (including while it tweens
    /// between hover states) then only changes the rate going forward, instead of
    /// retroactively scrubbing the whole curve.
    private func advancePhase(to now: Date) -> Double {
        let dt = min(max(clock.lastDate.map { now.timeIntervalSince($0) } ?? 0, 0), 0.1)
        clock.lastDate = now
        clock.phase += dt * configuration.animationSpeed * 2 * Double.pi
        return clock.phase
    }

    var body: some View {
        TimelineView(.animation(paused: paused)) { timeline in
            let now = timeline.date
            let phase = advancePhase(to: now)

            // A frozen seed keeps the grain static; otherwise it advances at the
            // configured frame rate so the noise shimmers.
            let elapsed = now.timeIntervalSince(startDate)
            let noiseSeed = configuration.noise.animated
                ? Int(elapsed * Double(configuration.noise.framesPerSecond))
                : 0

            ZStack {
                configuration.baseColor

                // Both crossing sine waves live inside a single progressive-blur
                // group that fades sharp to soft across the width, then blends
                // into the violet base with a soft-light pass. With Metal a
                // continuous variable-radius Gaussian is used; otherwise the
                // segmented SwiftUI approximation is the fallback.
                Group {
                    if MetalEffectLibrary.isAvailable {
                        MetalProgressiveWaveLayer(
                            waves: [configuration.primaryWave, configuration.secondaryWave],
                            phase: phase,
                            maximumBlurRadius: configuration.maximumProgressiveBlurRadius,
                            exponent: configuration.progressiveBlurExponent,
                            blurStrongOnLeft: configuration.blurStrongOnLeft
                        )
                    } else {
                        ProgressiveSineWaveLayer(
                            waves: [configuration.primaryWave, configuration.secondaryWave],
                            phase: phase,
                            segments: configuration.progressiveBlurSegments,
                            maximumBlurRadius: configuration.maximumProgressiveBlurRadius,
                            exponent: configuration.progressiveBlurExponent,
                            blurStrongOnLeft: configuration.blurStrongOnLeft
                        )
                    }
                }
                .compositingGroup()
                .blendMode(configuration.waveBlendMode)

                HeaderNoiseLayer(configuration: configuration.noise, seed: noiseSeed)
                    .compositingGroup()
                    .blendMode(configuration.noise.blendMode)
            }
            .drawingGroup()
        }
    }
}

struct NearfieldHeaderAnimationConfiguration {
    var baseColor: Color
    var animationSpeed: Double
    var loopResetInterval: TimeInterval
    var waveBlendMode: BlendMode
    var primaryWave: HeaderSineWaveConfiguration
    var secondaryWave: HeaderSineWaveConfiguration
    var progressiveBlurSegments: Int
    var maximumProgressiveBlurRadius: CGFloat
    var progressiveBlurExponent: Double
    // When true the blur is strongest on the left edge and sharpens toward the
    // right; when false it ramps the other way (sharp left, blurred right).
    var blurStrongOnLeft: Bool
    var noise: HeaderNoiseConfiguration
    // A post-process applied to the animation only (waves + noise + base),
    // never the overlaid logo or title.
    var effect: WaveLabEffect
    var effectSettings: WaveLabEffectSettings

    /// Resting state shown on the welcome screen.
    static let onboarding = NearfieldHeaderAnimationConfiguration(
        baseColor: Color(red: 0.9771, green: 0.6537, blue: 0.2700),
        animationSpeed: 0.055,
        loopResetInterval: 20_000,
        waveBlendMode: .softLight,
        primaryWave: HeaderSineWaveConfiguration(
            color: .white,
            opacity: 0.850,
            lineWidth: 26,
            frequency: 2.085,
            amplitude: 0.335,
            amplitudeFalloff: 0,
            verticalPosition: 0.499,
            phaseOffset: -0.48,
            speedMultiplier: 1,
            horizontalOverscan: 238,
            blurRadius: 0
        ),
        secondaryWave: HeaderSineWaveConfiguration(
            color: .white,
            opacity: 0.329,
            lineWidth: 26,
            frequency: 2.085,
            amplitude: 0.335,
            amplitudeFalloff: 0,
            verticalPosition: 0.499,
            phaseOffset: -3.62,
            speedMultiplier: 1,
            horizontalOverscan: 238,
            blurRadius: 0
        ),
        progressiveBlurSegments: 7,
        maximumProgressiveBlurRadius: 15.25,
        progressiveBlurExponent: 3.99,
        blurStrongOnLeft: true,
        noise: HeaderNoiseConfiguration(
            opacity: 0,
            density: 12000,
            minimumDotSize: 1.80,
            maximumDotSize: 0.92,
            framesPerSecond: 11,
            animated: true,
            monochrome: false,
            monochromeIsWhite: true,
            blendMode: .softLight
        ),
        effect: .none,
        effectSettings: .default
    )

    /// Hover state, used while the pointer is over the Install button.
    static let onboardingHover = NearfieldHeaderAnimationConfiguration(
        baseColor: Color(red: 0.9961, green: 0.4702, blue: 0.1203),
        animationSpeed: 1.093,
        loopResetInterval: 20_000,
        waveBlendMode: .softLight,
        primaryWave: HeaderSineWaveConfiguration(
            color: .white,
            opacity: 0.850,
            lineWidth: 26,
            frequency: 2.085,
            amplitude: 0.335,
            amplitudeFalloff: 0.314,
            verticalPosition: 0.499,
            phaseOffset: -0.48,
            speedMultiplier: 1,
            horizontalOverscan: 83.3,
            blurRadius: 0
        ),
        secondaryWave: HeaderSineWaveConfiguration(
            color: .white,
            opacity: 0.329,
            lineWidth: 17.833,
            frequency: 2.085,
            amplitude: 0.335,
            amplitudeFalloff: 0.314,
            verticalPosition: 0.499,
            phaseOffset: -3.62,
            speedMultiplier: 1,
            horizontalOverscan: 83.3,
            blurRadius: 0
        ),
        progressiveBlurSegments: 7,
        maximumProgressiveBlurRadius: 15.25,
        progressiveBlurExponent: 3.99,
        blurStrongOnLeft: true,
        noise: HeaderNoiseConfiguration(
            opacity: 0,
            density: 12000,
            minimumDotSize: 1.80,
            maximumDotSize: 0.92,
            framesPerSecond: 11,
            animated: true,
            monochrome: false,
            monochromeIsWhite: true,
            blendMode: .softLight
        ),
        effect: .none,
        effectSettings: .default
    )
}

struct HeaderSineWaveConfiguration {
    var color: Color
    var opacity: Double
    var lineWidth: CGFloat
    var frequency: Double
    var amplitude: CGFloat
    // Tapers the amplitude horizontally: 0 keeps it constant, 1 fades it to zero
    // at the right edge of the visible area (full on the left).
    var amplitudeFalloff: CGFloat
    var verticalPosition: CGFloat
    var phaseOffset: Double
    var speedMultiplier: Double
    var horizontalOverscan: CGFloat
    var blurRadius: CGFloat
}

struct HeaderNoiseConfiguration {
    var opacity: Double
    var density: Int
    var minimumDotSize: CGFloat
    var maximumDotSize: CGFloat
    var framesPerSecond: Int
    // When false the grain is frozen on a single frame instead of shimmering.
    var animated: Bool
    // When true every speck is a single base color (varying alpha); otherwise
    // the grain mixes brighter and darker specks.
    var monochrome: Bool
    // The base color used in monochrome mode: white when true, black when false.
    var monochromeIsWhite: Bool
    var blendMode: BlendMode
}

/// GPU progressive blur: renders the crossing waves once and applies a separable
/// variable-radius Gaussian whose radius ramps across the width — a continuous
/// equivalent of `ProgressiveSineWaveLayer`'s segmented approximation. Used when
/// the compiled Metal library is present.
private struct MetalProgressiveWaveLayer: View {
    let waves: [HeaderSineWaveConfiguration]
    let phase: Double
    let maximumBlurRadius: CGFloat
    let exponent: Double
    let blurStrongOnLeft: Bool

    var body: some View {
        GeometryReader { proxy in
            let cap = min(maximumBlurRadius, 30) + 2
            CrossingWaveStrokes(waves: waves, phase: phase)
                .layerEffect(
                    ShaderLibrary.default.wl_progressive_blur_h(
                        .float2(proxy.size),
                        .float(Float(maximumBlurRadius)),
                        .float(Float(exponent)),
                        .float(blurStrongOnLeft ? 1 : 0)
                    ),
                    maxSampleOffset: CGSize(width: cap, height: 0)
                )
                .layerEffect(
                    ShaderLibrary.default.wl_progressive_blur_v(
                        .float2(proxy.size),
                        .float(Float(maximumBlurRadius)),
                        .float(Float(exponent)),
                        .float(blurStrongOnLeft ? 1 : 0)
                    ),
                    maxSampleOffset: CGSize(width: 0, height: cap)
                )
        }
    }
}

private struct ProgressiveSineWaveLayer: View {
    let waves: [HeaderSineWaveConfiguration]
    let phase: Double
    let segments: Int
    let maximumBlurRadius: CGFloat
    let exponent: Double
    let blurStrongOnLeft: Bool

    var body: some View {
        // Each vertical segment redraws the full wave set at a different blur
        // radius and is masked to a soft-edged horizontal band, so the composite
        // ramps the blur across the width. Segments are stacked with the default
        // (source-over) blend; the single soft-light pass happens once at the
        // group level to avoid double-blended seams.
        ZStack {
            ForEach(0..<max(segments, 1), id: \.self) { index in
                let position = CGFloat(index) / CGFloat(max(segments - 1, 1))
                // `position` is 0 on the left, 1 on the right. Flip it when the
                // blur should be strongest on the left edge.
                let blurAmount = blurStrongOnLeft ? (1 - position) : position
                let blurRadius = maximumBlurRadius * CGFloat(pow(Double(blurAmount), exponent))

                CrossingWaveStrokes(waves: waves, phase: phase, extraBlur: blurRadius)
                    .mask {
                        ProgressiveBlurSegmentMask(index: index, total: max(segments, 1))
                    }
            }
        }
    }
}

private struct CrossingWaveStrokes: View {
    let waves: [HeaderSineWaveConfiguration]
    let phase: Double
    var extraBlur: CGFloat = 0

    var body: some View {
        ZStack {
            ForEach(Array(waves.enumerated()), id: \.offset) { _, wave in
                SineWaveShape(wave: wave, phase: phase * wave.speedMultiplier)
                    .stroke(
                        wave.color.opacity(wave.opacity),
                        style: StrokeStyle(lineWidth: wave.lineWidth, lineCap: .round, lineJoin: .round)
                    )
                    .blur(radius: wave.blurRadius + extraBlur)
            }
        }
        .compositingGroup()
    }
}

private struct ProgressiveBlurSegmentMask: View {
    let index: Int
    let total: Int

    var body: some View {
        GeometryReader { proxy in
            let segmentWidth = proxy.size.width / CGFloat(max(total, 1))
            let overlap = segmentWidth * 0.34
            let startX = CGFloat(index) * segmentWidth - overlap

            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(index == 0 ? 1 : 0), location: 0),
                            .init(color: .black, location: 0.26),
                            .init(color: .black, location: 0.74),
                            .init(color: .black.opacity(index == total - 1 ? 1 : 0), location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: segmentWidth + overlap * 2, height: proxy.size.height)
                .offset(x: startX)
        }
    }
}

private struct SineWaveShape: Shape {
    let wave: HeaderSineWaveConfiguration
    let phase: Double

    func path(in rect: CGRect) -> Path {
        let width = max(rect.width, 1)
        let height = max(rect.height, 1)
        let overscan = wave.horizontalOverscan
        let startX = -overscan
        let endX = width + overscan
        let sampleStep: CGFloat = 2
        let amplitude = height * wave.amplitude
        let midY = height * wave.verticalPosition
        let totalWidth = width + overscan * 2
        var path = Path()
        var x = startX
        var didMove = false

        while x <= endX {
            let progress = Double((x + overscan) / totalWidth)
            let angle = progress * wave.frequency * 2 * Double.pi - phase - wave.phaseOffset
            // Taper the amplitude across the visible width (left = full).
            let visible = min(max(x / width, 0), 1)
            let envelope = max(1 - wave.amplitudeFalloff * visible, 0)
            let y = midY + sin(angle) * Double(amplitude * envelope)
            let point = CGPoint(x: x, y: CGFloat(y))

            if didMove {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                didMove = true
            }

            x += sampleStep
        }

        return path
    }
}

private struct HeaderNoiseLayer: View {
    let configuration: HeaderNoiseConfiguration
    let seed: Int

    var body: some View {
        Canvas { context, size in
            guard configuration.opacity > 0,
                  configuration.density > 0,
                  size.width > 0,
                  size.height > 0 else {
                return
            }

            // Specks paint normally onto the transparent canvas; the grain layer
            // as a whole is blended over the animation by the `.blendMode`
            // modifier applied to this view, so the chosen mode actually affects
            // how the noise interacts with the waves and base color beneath it.
            for index in 0..<configuration.density {
                let x = noiseValue(index: index, seed: seed) * size.width
                let y = noiseValue(index: index, seed: seed + 4_097) * size.height
                let tone = noiseValue(index: index, seed: seed + 8_191)
                let dotSize = configuration.minimumDotSize +
                    noiseValue(index: index, seed: seed + 16_381) *
                    (configuration.maximumDotSize - configuration.minimumDotSize)
                let alpha = configuration.opacity * (0.34 + Double(tone) * 0.66)
                let color: Color
                if configuration.monochrome {
                    let base: Color = configuration.monochromeIsWhite ? .white : .black
                    color = base.opacity(alpha)
                } else {
                    color = tone > 0.5 ? Color.white.opacity(alpha) : Color.black.opacity(alpha * 0.7)
                }
                let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)

                context.fill(Path(rect), with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }

    private func noiseValue(index: Int, seed: Int) -> CGFloat {
        var value = UInt64(index + 1)
        value = value &* 1_103_515_245 &+ UInt64(seed + 1)
        value ^= value >> 13
        value = value &* 2_654_435_761
        value ^= value >> 17
        return CGFloat(value & 0xffff) / CGFloat(0xffff)
    }
}

struct NearfieldLogoMark: View {
    var body: some View {
        NearfieldLogoShape()
            .fill(Color.white, style: FillStyle(eoFill: true))
    }
}

private struct NearfieldLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sourceSize = CGSize(width: 59, height: 53.9756)
        let scale = min(rect.width / sourceSize.width, rect.height / sourceSize.height)
        let xOffset = rect.minX + (rect.width - sourceSize.width * scale) / 2
        let yOffset = rect.minY + (rect.height - sourceSize.height * scale) / 2
        let transform = CGAffineTransform(translationX: xOffset, y: yOffset)
            .scaledBy(x: scale, y: scale)
        var path = Path()

        path.move(to: CGPoint(x: 18.9312, y: 6))
        path.addCurve(
            to: CGPoint(x: 39.7163, y: 6),
            control1: CGPoint(x: 23.55, y: -2),
            control2: CGPoint(x: 35.0975, y: -2)
        )
        path.addLine(to: CGPoint(x: 57.022, y: 35.9756))
        path.addCurve(
            to: CGPoint(x: 46.6304, y: 53.9756),
            control1: CGPoint(x: 61.6408, y: 43.9755),
            control2: CGPoint(x: 55.8678, y: 53.9754)
        )
        path.addLine(to: CGPoint(x: 12.0181, y: 53.9756))
        path.addCurve(
            to: CGPoint(x: 1.62552, y: 35.9756),
            control1: CGPoint(x: 2.78052, y: 53.9756),
            control2: CGPoint(x: -2.9932, y: 43.9756)
        )
        path.addLine(to: CGPoint(x: 18.9312, y: 6))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: 11.4468, y: 14.1396, width: 35.7549, height: 35.7559))

        return path.applying(transform)
    }
}
